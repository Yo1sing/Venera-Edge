import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:venera/foundation/script_bridge.dart';
import 'package:venera/src/rust/frb_generated.dart';
import 'package:venera/src/rust/api/script.dart' as scripts;
import 'package:venera/src/rust/api/media.dart' as media;
import 'package:venera/src/rust/api/archive.dart' as archives;
import 'package:venera/src/rust/api/comic_queue.dart' as downloads;
import 'package:venera/src/rust/api/local.dart' as local;
import 'package:venera/src/rust/api/backup.dart' as backup;
import 'package:venera/src/rust/api/settings.dart' as settings;

const httpOptions = {
  'proxy': null,
  'dns_overrides': <String, String>{},
  'tls_sni': true,
  'verify_certificates': true,
  'connect_timeout_ms': 3000,
  'receive_timeout_ms': 3000,
  'max_redirects': 5,
};
String runtimeOptions(String directory) => jsonEncode({
  'data_path': directory,
  'version': '1.6.3',
  'locale': 'zh_CN',
  'platform': 'windows',
  'user_agent': 'test',
  'http': httpOptions,
});

Future<Map<String, dynamic>> readSettings(Directory directory) async =>
    jsonDecode(await settings.loadAppData(directory: directory.path));

Future<Map<String, dynamic>> configureWebDav(
  Directory directory,
  HttpServer server,
) async {
  final data = await readSettings(directory);
  data['settings']['webdav'] = [
    'http://127.0.0.1:${server.port}',
    'user',
    'password',
  ];
  await settings.saveAppData(
    directory: directory.path,
    dataJson: jsonEncode(data),
  );
  return data;
}

String davFiles(List<String> names) =>
    '<d:multistatus xmlns:d="DAV:">'
    '${names.map((name) => '<d:response><d:href>/$name</d:href></d:response>').join()}'
    '</d:multistatus>';

Future<void> submitSync(backup.SyncController sync, String action) =>
    sync.submit(action: action, httpJson: jsonEncode(httpOptions));

Future<Map<String, dynamic>> syncState(
  backup.SyncController controller,
  bool Function(Map<String, dynamic>) matches,
) async {
  var state = jsonDecode(controller.snapshot()) as Map<String, dynamic>;
  while (!matches(state)) {
    state = jsonDecode(
      await controller.nextSnapshot().timeout(const Duration(seconds: 5)),
    );
  }
  return state;
}

Matcher containsError(String text) =>
    predicate<Object>((error) => error.toString().contains(text));

void main() {
  final library = Platform.environment['VENERA_BACKEND_LIBRARY'];
  if (library == null) {
    test(
      'Rust migration integration',
      () {},
      skip: 'Set VENERA_BACKEND_LIBRARY',
    );
    return;
  }
  setUpAll(() => RustLib.init(externalLibrary: ExternalLibrary.open(library)));
  tearDownAll(RustLib.dispose);

  test(
    'WebDAV keeps backups on failed upload and chooses numeric revisions',
    () async {
      final directory = await Directory.systemTemp.createTemp('venera_sync_');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var rejectUpload = true;
      final requests = <String>[];
      server.listen((request) async {
        requests.add('${request.method} ${request.uri.path}');
        await request.drain<void>();
        switch (request.method) {
          case 'PROPFIND':
            request.response.statusCode = 207;
            request.response.write(
              davFiles(['20000-9.venera', '20000-10.venera']),
            );
          case 'PUT':
            request.response.statusCode = rejectUpload ? 500 : 201;
          case 'GET':
            request.response.add([1, 2, 3]);
          default:
            request.response.statusCode = 204;
        }
        await request.response.close();
      });
      backup.SyncController? controller;
      try {
        final data = await configureWebDav(directory, server);
        final originalRevision = data['settings']['dataVersion'];
        final sync = controller = await backup.SyncController.open(
          directory: directory.path,
          cache: directory.path,
        );
        await expectLater(submitSync(sync, 'upload'), throwsA(anything));
        expect(requests.where((v) => v.startsWith('DELETE')), isEmpty);
        expect(
          (await readSettings(directory))['settings']['dataVersion'],
          originalRevision,
        );

        await expectLater(submitSync(sync, 'download'), throwsA(anything));
        expect(requests.last, 'GET /20000-10.venera');
        expect(
          directory.listSync().where((f) => f.path.endsWith('.venera')),
          isEmpty,
        );

        rejectUpload = false;
        await submitSync(sync, 'upload');
        expect((await readSettings(directory))['settings']['dataVersion'], 11);
        expect(
          requests.any((r) => r.startsWith('PUT ') && r.endsWith('-11.venera')),
          isTrue,
        );
      } finally {
        controller?.dispose();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'WebDAV queues downloads and coalesces edits behind an active upload',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'venera_sync_queue_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final firstPut = Completer<void>();
      final releasePut = Completer<void>();
      final uploaded = <Map<String, dynamic>>[];
      final files = <String>[];
      final requests = <String>[];
      server.listen((request) async {
        requests.add(request.method);
        if (request.method == 'PUT') {
          final bytes = await request.fold(
            <int>[],
            (all, chunk) => all..addAll(chunk),
          );
          final archive = ZipDecoder().decodeBytes(bytes);
          uploaded.add(
            jsonDecode(utf8.decode(archive.findFile('appdata.json')!.content)),
          );
          if (uploaded.length == 1) {
            firstPut.complete();
            await releasePut.future;
          }
          files.add(request.uri.pathSegments.last);
          request.response.statusCode = 201;
        } else if (request.method == 'PROPFIND') {
          request.response.statusCode = 207;
          request.response.write(davFiles(files));
        } else if (request.method == 'DELETE') {
          files.remove(request.uri.pathSegments.last);
          request.response.statusCode = 204;
        } else {
          request.response.statusCode = 500;
        }
        await request.response.close();
      });
      backup.SyncController? controller;
      try {
        final saved = await configureWebDav(directory, server);
        await settings.saveImplicitData(
          directory: directory.path,
          dataJson: '{"webdavAutoSync":true}',
        );
        final sync = controller = await backup.SyncController.open(
          directory: directory.path,
          cache: directory.path,
        );
        final first = submitSync(sync, 'upload');
        await firstPut.future.timeout(const Duration(seconds: 5));

        final base = jsonEncode(saved);
        for (final theme in ['dark', 'light', 'dark']) {
          saved['settings']['theme_mode'] = theme;
          await settings.saveAppDataChanges(
            directory: directory.path,
            baseJson: base,
            dataJson: jsonEncode(saved),
          );
          await submitSync(sync, 'changed');
        }
        final download = submitSync(sync, 'download');
        final queued = await syncState(sync, (state) => state['pending'] == 2);
        expect(queued['phase'], 'uploading');
        expect(requests, ['PROPFIND', 'PUT']);

        releasePut.complete();
        await first;
        await download;
        await syncState(sync, (state) => state['phase'] == 'idle');
        expect(uploaded, hasLength(2));
        expect(uploaded.last['settings']['theme_mode'], 'dark');
        expect(
          (await readSettings(directory))['settings']['theme_mode'],
          'dark',
        );
        expect(requests.where((method) => method == 'GET'), isEmpty);
      } finally {
        if (!releasePut.isCompleted) releasePut.complete();
        controller?.dispose();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'WebDAV restore rejects local changes before applying a downloaded backup',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'venera_sync_restore_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final archive = Archive()
        ..addFile(
          ArchiveFile.string(
            'appdata.json',
            '{"settings":{"dataVersion":10,"theme_mode":"light"},"searchHistory":["remote"]}',
          ),
        );
      final bytes = ZipEncoder().encode(archive);
      server.listen((request) async {
        await request.drain<void>();
        if (request.method == 'PROPFIND') {
          request.response.statusCode = 207;
          request.response.write(davFiles(['20000-10.venera']));
        } else if (request.method == 'GET') {
          request.response.add(bytes);
        } else {
          request.response.statusCode = 500;
        }
        await request.response.close();
      });
      backup.SyncController? controller;
      try {
        final before = await configureWebDav(directory, server);
        final sync = controller = await backup.SyncController.open(
          directory: directory.path,
          cache: directory.path,
        );
        final rejected = expectLater(
          submitSync(sync, 'download'),
          throwsA(anything),
        );
        final restoring = await syncState(
          sync,
          (state) => state['restore'] != null,
        );
        final id = restoring['restore'] as int;
        before['searchHistory'] = ['local-during-download'];
        await settings.saveAppData(
          directory: directory.path,
          dataJson: jsonEncode(before),
        );
        await expectLater(
          sync.applyRestore(id: id),
          throwsA(containsError('Local data changed')),
        );
        sync.finishRestore(id: id, error: 'Local data changed');
        await rejected;
        expect((await readSettings(directory))['searchHistory'], [
          'local-during-download',
        ]);

        final retry = submitSync(sync, 'download');
        final next = await syncState(sync, (state) => state['restore'] != null);
        final nextId = next['restore'] as int;
        final restored = jsonDecode(await sync.applyRestore(id: nextId));
        expect(restored['data']['searchHistory'], ['remote']);
        sync.finishRestore(id: nextId);
        await retry;
        expect((await readSettings(directory))['searchHistory'], ['remote']);
      } finally {
        controller?.dispose();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'QuickJS source registration, functions, promises, bytes and persistent data',
    () async {
      final directory = await Directory.systemTemp.createTemp('venera_script_');
      final runtime = await scripts.ScriptRuntime.open(
        optionsJson: runtimeOptions(directory.path),
      );
      final session = ScriptSession(runtime);
      try {
        final source = session.decodeJson(
          await runtime.parseSource(
            code: '''
        class Fixture extends ComicSource {
          name='测试源'; key='fixture'; version='1.0.0'; minAppVersion='1.0.0';
          account={login:async function(a,p){ if(p!=='password') throw Error('bad password'); }};
        }
      ''',
          ),
        );
        expect(source['key'], 'fixture');
        await session.evaluate(
          "ComicSource.sources.fixture.account.login('user','password')",
        );
        expect(
          jsonDecode(
            scripts.loadSourceData(directory: directory.path, key: 'fixture'),
          )['account'],
          ['user', 'password'],
        );
        final fn =
            session.evaluate('(bytes) => new Uint8Array(bytes).slice().buffer')
                as JSInvokable;
        expect(
          fn([
            Uint8List.fromList([0, 127, 255]),
          ]),
          [0, 127, 255],
        );
        fn.free();
        expect(() => fn([]), throwsA(anything));
        expect(
          await session.evaluate(
            "(async()=>{await new Promise(r=>setTimeout(r,5)); return '异步';})()",
          ),
          '异步',
        );
        expect(
          session.evaluate(
            "new HtmlDocument('<div class=\"test\">漫画</div>').querySelector('.test').text",
          ),
          '漫画',
        );
        final event = runtime.nextEvent();
        final clipboard = session.evaluate('getClipboard()');
        // Login emits sourceChanged before the clipboard platform event.
        var message = jsonDecode((await event)!);
        while (message['event'] != 'platform') {
          message = jsonDecode((await runtime.nextEvent())!);
        }
        runtime.resolveEvent(
          id: message['ticket'],
          valueJson: jsonEncode(encodeScriptValue('clipboard')),
        );
        expect(await clipboard, 'clipboard');
        await expectLater(
          runtime.parseSource(
            code:
                'class Bad extends ComicSource {name="Bad";key="fixture";version="1.0.0";}',
          ),
          throwsA(anything),
        );
      } finally {
        session.close();
        runtime.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'Rust image transfer, cancellation and cache use actual FRB handles',
    () async {
      final directory = await Directory.systemTemp.createTemp('venera_images_');
      final runtime = await scripts.ScriptRuntime.open(
        optionsJson: runtimeOptions(directory.path),
      );
      final bytes = await File('assets/app_icon.png').readAsBytes();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      final subscription = server.listen((request) async {
        requests++;
        if (request.uri.path == '/slow') {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        request.response.add(bytes);
        await request.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}';
      Future<media.ImageTransfer> transfer(String path) =>
          media.ImageTransfer.start(
            runtime: runtime,
            dataPath: directory.path,
            cachePath: directory.path,
            image: '$url/$path',
            comic: 'comic',
            chapter: 'chapter',
            thumbnail: false,
          );
      Future<List<int>> read(media.ImageTransfer task) async {
        try {
          while (true) {
            final event = await task.next();
            expect(event, isNotNull);
            expect(event!.error, isNull);
            if (event.bytes != null) return event.bytes!;
          }
        } finally {
          task.cancel();
          task.dispose();
        }
      }

      try {
        expect(await read(await transfer('image')), bytes);
        expect(await read(await transfer('image')), bytes);
        expect(requests, 1);
        final slow = await transfer('slow');
        slow.cancel();
        final event = await slow.next().timeout(const Duration(seconds: 2));
        expect(event!.error, contains('cancelled'));
        slow.dispose();
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
    'comic queue pauses, restores legacy checkpoints and completes in Rust',
    () async {
      final directory = await Directory.systemTemp.createTemp('venera_queue_');
      final runtime = await scripts.ScriptRuntime.open(
        optionsJson: runtimeOptions(directory.path),
      );
      final bytes = await File('assets/app_icon.png').readAsBytes();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        request.response.add(bytes);
        await request.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}';
      await runtime.parseSource(
        code:
            '''class Fixture extends ComicSource {
      name='Queue fixture';key='fixture';version='1.0.0';
      infoAttempts=0;pageAttempts=0;
      comic={loadInfo:async(id)=>{if(++this.infoAttempts===1) throw Error('temporary info failure');return {title:'漫画 '+id,cover:'$url/cover',tags:{作者:['测试']},chapters:{a:'第一章',b:'第二章'}};},
        loadEp:async(id,ep)=>{if(++this.pageAttempts===1) throw Error('temporary page failure');return {images:['$url/'+ep+'/0','$url/'+ep+'/1']};}};
    }''',
      );
      final options = jsonEncode({
        'data_path': directory.path,
        'cache_path': directory.path,
        'local_path': '${directory.path}/local',
        'saf': false,
        'threads': 2,
        'http': httpOptions,
      });
      await File('${directory.path}/downloading_tasks.json').writeAsString(
        jsonEncode([
          {
            'type': 'ImagesDownloadTask',
            'source': 'fixture',
            'comicId': 'legacy',
            'comic': null,
            'chapters': ['a'],
          },
        ]),
      );
      final queue = await downloads.ComicDownloadQueue.open(
        runtime: runtime,
        optionsJson: options,
        sourceTypesJson: '{"fixture":42}',
      );
      try {
        expect((jsonDecode(queue.snapshot()) as List).single['comicType'], 42);
        await queue.command(key: 'fixture@legacy', action: 'resume');
        await queue.command(key: 'fixture@legacy', action: 'pause');
        expect(
          (jsonDecode(queue.snapshot()) as List).single['_running'],
          false,
        );
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect((jsonDecode(queue.snapshot()) as List).length, 1);
        await queue.command(key: 'fixture@legacy', action: 'resume');
        await (() async {
          while (true) {
            final rows = jsonDecode(queue.snapshot()) as List;
            if (rows.isEmpty) break;
            if (rows.single['_error'] == true) fail(rows.single['message']);
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
        })().timeout(const Duration(seconds: 20));
        final store = await local.LocalStore.open(
          path: '${directory.path}/local.db',
        );
        final record = jsonDecode(store.find(id: 'legacy', comicType: 42)!);
        expect(
          jsonDecode(
            runtime.evaluate(
              source: 'ComicSource.sources.fixture.infoAttempts',
            ),
          )[1],
          2,
        );
        expect(
          jsonDecode(
            runtime.evaluate(
              source: 'ComicSource.sources.fixture.pageAttempts',
            ),
          )[1],
          2,
        );
        expect(record['downloaded_chapters'], ['a']);
        expect(
          await Directory(
            '${directory.path}/local/${record['directory']}/a',
          ).list().length,
          2,
        );
        expect(
          jsonDecode(
            await File(
              '${directory.path}/downloading_tasks.json',
            ).readAsString(),
          ),
          isEmpty,
        );
        store.close();
        store.dispose();
      } finally {
        queue.dispose();
        runtime.close();
        runtime.dispose();
        await subscription.cancel();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'image processing and PDF/EPUB/CBZ exports preserve chapter boundaries',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'venera_exports_',
      );
      final image = File('assets/app_icon.png').absolute.path;
      final book = {
        'title': '漫画 <&>',
        'author': '作者',
        'cover': image,
        'tags': ['测试'],
        'has_chapters': true,
        'chapters': [
          {
            'title': '第一章',
            'images': [image, image],
          },
          {
            'title': '第二章',
            'images': [image],
          },
        ],
      };
      try {
        final processed = await media.modifyImage(
          data: await File(image).readAsBytes(),
          script:
              'function modifyImage(i){return i.copyRange(0,0,2,3).copyAndRotate90();}',
        );
        final dimensions = ByteData.sublistView(processed);
        expect(dimensions.getUint32(16), 3);
        expect(dimensions.getUint32(20), 2);
        for (final format in ['pdf', 'epub', 'cbz']) {
          await media.exportBook(
            bookJson: jsonEncode(book),
            output: '${directory.path}/book.$format',
            format: format,
          );
        }
        final epub = ZipDecoder().decodeBytes(
          await File('${directory.path}/book.epub').readAsBytes(),
        );
        expect(epub.first.name, 'mimetype');
        expect(
          utf8.decode(epub.findFile('content.opf')!.content),
          contains('漫画 &lt;&amp;&gt;'),
        );
        final cbz = ZipDecoder().decodeBytes(
          await File('${directory.path}/book.cbz').readAsBytes(),
        );
        final metadata = jsonDecode(
          utf8.decode(cbz.findFile('metadata.json')!.content),
        );
        expect(metadata['chapters'][1]['start'], 3);
        final imported = jsonDecode(
          await archives.importComicArchive(
            input: '${directory.path}/book.cbz',
            cache: directory.path,
            local: '${directory.path}/local',
            database: '${directory.path}/local.db',
          ),
        );
        expect(imported['chapters'], {'0': '第一章', '1': '第二章'});
        expect(
          await Directory(
            '${directory.path}/local/${imported['directory']}/1',
          ).list().length,
          1,
        );
        final pdf = await File('${directory.path}/book.pdf').readAsBytes();
        expect(ascii.decode(pdf.take(8).toList()), '%PDF-1.7');
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
