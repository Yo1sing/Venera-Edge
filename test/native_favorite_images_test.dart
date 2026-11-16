import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/script_bridge.dart';
import 'package:venera/src/rust/api/local.dart';
import 'package:venera/src/rust/api/media.dart';
import 'package:venera/src/rust/api/script.dart';
import 'package:venera/src/rust/frb_generated.dart';

String options(String directory) => jsonEncode({
  'data_path': directory,
  'version': '1.6.3',
  'locale': 'zh_CN',
  'platform': 'windows',
  'user_agent': 'test',
  'http': {
    'proxy': null,
    'dns_overrides': <String, String>{},
    'tls_sni': true,
    'verify_certificates': true,
    'connect_timeout_ms': 1000,
    'receive_timeout_ms': 10000,
    'max_redirects': 5,
  },
});

String favorite(String image, int page) => jsonEncode({
  'id': 'comic-id',
  'sourceKey': 'sample',
  'eid': 'chapter/one',
  'page': page,
  'imageKey': image,
});

Future<ImageTransfer> start(
  ScriptRuntime runtime,
  Directory directory,
  String image,
  int page,
) => ImageTransfer.startFavorite(
  runtime: runtime,
  dataPath: directory.path,
  cachePath: directory.path,
  localPath: 'android://books',
  comicType: 42,
  favoriteJson: favorite(image, page),
);

Future<List<int>> result(ImageTransfer transfer) async {
  try {
    while (true) {
      final event = await transfer.next().timeout(const Duration(seconds: 10));
      if (event == null) throw StateError('Missing image result');
      if (event.error != null) throw StateError(event.error!);
      if (event.bytes != null) return event.bytes!;
    }
  } finally {
    transfer.cancel();
    transfer.dispose();
  }
}

void main() {
  final library = Platform.environment['VENERA_BACKEND_LIBRARY'];
  if (library == null) {
    test(
      'favorite image native integration',
      () {},
      skip: 'Set VENERA_BACKEND_LIBRARY',
    );
    return;
  }
  setUpAll(() => RustLib.init(externalLibrary: ExternalLibrary.open(library)));
  tearDownAll(RustLib.dispose);

  test(
    'expired URLs recover by comic/chapter/page, cache hits skip HTTP, deletion clears the page',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'venera_favorite_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = 'http://127.0.0.1:${server.port}';
      final requests = <String>[];
      final subscription = server.listen((request) async {
        requests.add(request.uri.path);
        request.response.headers.set('cache-control', 'no-store');
        if (request.uri.path == '/old') {
          request.response.statusCode = 404;
        } else {
          request.response.add(
            request.uri.path == '/first' ? [1, 2, 3] : [4, 5, 6],
          );
        }
        await request.response.close();
      });
      final runtime = await ScriptRuntime.open(
        optionsJson: options(directory.path),
      );
      final session = ScriptSession(runtime);
      try {
        await runtime.parseSource(
          code:
              '''
class Sample extends ComicSource {
  name='Sample';key='sample';version='1.0.0';
  comic={loadEp:(cid,eid)=>{globalThis.pageCalls=(globalThis.pageCalls??0)+1;
    if(cid!=='comic-id'||eid!=='chapter/one')throw Error('Wrong comic mapping');
    return {images:['$base/first','$base/last']};},
    onImageLoad:(image,cid,eid)=>{if(cid!=='comic-id'||eid!=='chapter/one')throw Error('Wrong image mapping');return {};}};
}
''',
        );
        expect(await result(await start(runtime, directory, '$base/old', 1)), [
          1,
          2,
          3,
        ]);
        expect(requests, ['/old', '/first']);
        expect(session.evaluate('pageCalls'), 1);
        expect(await result(await start(runtime, directory, '', 2)), [4, 5, 6]);
        final count = requests.length;
        // Changed or empty saved URLs retain the stable identity for each page.
        expect(await result(await start(runtime, directory, '', 1)), [1, 2, 3]);
        expect(
          await result(await start(runtime, directory, '$base/changed', 2)),
          [4, 5, 6],
        );
        expect(requests.length, count);
        await deleteFavoriteImageCache(
          cachePath: directory.path,
          favoriteJson: favorite('', 1),
        );
        expect(await result(await start(runtime, directory, '', 1)), [1, 2, 3]);
        expect(requests.length, count + 1);
        expect(session.evaluate('pageCalls'), 3);
        await expectLater(
          result(await start(runtime, directory, '', 3)),
          throwsA(predicate((e) => '$e'.contains('out of range'))),
        );
        expect(requests.length, count + 1);
        await expectLater(start(runtime, directory, '', 0), throwsA(anything));
      } finally {
        runtime.close();
        runtime.dispose();
        await subscription.cancel();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'cancelling an active favorite HTTP transfer disconnects without refreshing or caching',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'venera_favorite_cancel_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final arrived = Completer<void>();
      final disconnected = Completer<void>();
      final subscription = server.listen((request) async {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.listen(
          (_) {},
          onDone: () {
            if (!disconnected.isCompleted) disconnected.complete();
            socket.destroy();
          },
        );
        arrived.complete();
      });
      final runtime = await ScriptRuntime.open(
        optionsJson: options(directory.path),
      );
      try {
        await runtime.parseSource(
          code:
              "class Sample extends ComicSource {name='Sample';key='sample';version='1.0.0';comic={loadEp:()=>{globalThis.refreshed=true;return {images:[]};}};}",
        );
        final transfer = await start(
          runtime,
          directory,
          'http://127.0.0.1:${server.port}/hold',
          1,
        );
        await arrived.future.timeout(const Duration(seconds: 5));
        transfer.cancel();
        await expectLater(
          result(transfer),
          throwsA(predicate((e) => '$e'.contains('cancelled'))),
        );
        await disconnected.future.timeout(const Duration(seconds: 5));
        expect(
          ScriptSession(runtime).evaluate('globalThis.refreshed??false'),
          false,
        );
        expect(
          Directory('${directory.path}/image_favorites').existsSync(),
          false,
        );
      } finally {
        runtime.close();
        runtime.dispose();
        await subscription.cancel();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'transient failures retry in Rust and cancelling backoff prevents another request',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'venera_favorite_retry_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = 'http://127.0.0.1:${server.port}';
      final requests = <String, int>{};
      final waiting = Completer<void>();
      final subscription = server.listen((request) async {
        final path = request.uri.path;
        requests[path] = (requests[path] ?? 0) + 1;
        request.response.headers.set('cache-control', 'no-store');
        if (path == '/missing') {
          request.response.statusCode = 404;
        } else if (path == '/wait' || requests[path] == 1) {
          request.response.statusCode = 503;
        } else {
          request.response.add([7, 8, 9]);
        }
        await request.response.close();
        if (path == '/wait' && !waiting.isCompleted) waiting.complete();
      });
      final runtime = await ScriptRuntime.open(
        optionsJson: options(directory.path),
      );
      try {
        await runtime.parseSource(
          code:
              "class Sample extends ComicSource {name='Sample';key='sample';version='1.0.0';comic={loadEp:()=>({images:[globalThis.imageUrl]})};}",
        );
        runtime.evaluate(
          source: 'globalThis.imageUrl=${jsonEncode('$base/flaky')}',
        );
        expect(await result(await start(runtime, directory, '', 1)), [7, 8, 9]);
        expect(requests['/flaky'], 2);
        await deleteFavoriteImageCache(
          cachePath: directory.path,
          favoriteJson: favorite('', 1),
        );
        runtime.evaluate(
          source: 'globalThis.imageUrl=${jsonEncode('$base/missing')}',
        );
        await expectLater(
          result(await start(runtime, directory, '', 1)),
          throwsA(predicate((e) => '$e'.contains('HTTP 404'))),
        );
        expect(requests['/missing'], 1);
        runtime.evaluate(
          source: 'globalThis.imageUrl=${jsonEncode('$base/wait')}',
        );
        final transfer = await start(runtime, directory, '', 1);
        await waiting.future.timeout(const Duration(seconds: 5));
        // Allow the failed response to enter the backend retry delay.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        transfer.cancel();
        await expectLater(
          result(transfer),
          throwsA(predicate((e) => '$e'.contains('cancelled'))),
        );
        await Future<void>.delayed(const Duration(milliseconds: 2100));
        expect(requests['/wait'], 1);
        expect(
          Directory('${directory.path}/image_favorites').listSync(),
          isEmpty,
        );
      } finally {
        runtime.close();
        runtime.dispose();
        await subscription.cancel();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'SAF platform replies leave chapter selection, sorting and page lookup in Rust',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'venera_favorite_saf_',
      );
      final runtime = await ScriptRuntime.open(
        optionsJson: options(directory.path),
      );
      final store = await LocalStore.open(path: '${directory.path}/local.db');
      store.save(
        comicJson: jsonEncode({
          'id': 'comic-id',
          'title': 'Sample',
          'subtitle': '',
          'tags': <String>[],
          'directory': 'book',
          'chapters': {
            'group': {'chapter/one': 'One'},
          },
          'cover': '',
          'comic_type': 42,
          'downloaded_chapters': ['chapter/one'],
          'created_at': 0,
        }),
      );
      final paths = <String>[];
      final session = ScriptSession(runtime);
      final events = () async {
        while (paths.length < 4) {
          final encoded = await runtime.nextEvent();
          if (encoded == null) break;
          final event = jsonDecode(encoded);
          if (event['event'] != 'platform') continue;
          final data = session.decode(event['data']) as Map;
          paths.add(data['path']);
          final dynamic value = data['operation'] == 'list'
              ? [
                  'android://books/book/chapter_one/10.jpg',
                  'android://books/book/chapter_one/cover.jpg',
                  'android://books/book/chapter_one/2.jpg',
                ]
              : Uint8List.fromList(
                  data['path'].endsWith('/2.jpg') ? [2] : [10],
                );
          runtime.resolveEvent(
            id: event['ticket'],
            valueJson: jsonEncode(encodeScriptValue(value)),
          );
        }
      }();
      try {
        expect(await result(await start(runtime, directory, '', 1)), [2]);
        expect(await result(await start(runtime, directory, '', 2)), [10]);
        expect(paths, [
          'android://books/book/chapter_one',
          'android://books/book/chapter_one/2.jpg',
          'android://books/book/chapter_one',
          'android://books/book/chapter_one/10.jpg',
        ]);
      } finally {
        store.close();
        store.dispose();
        runtime.close();
        await events.timeout(const Duration(seconds: 5));
        runtime.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
