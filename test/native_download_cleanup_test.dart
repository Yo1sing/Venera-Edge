import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_edge/src/rust/api/comic_queue.dart';
import 'package:venera_edge/src/rust/api/local.dart';
import 'package:venera_edge/src/rust/api/script.dart';
import 'package:venera_edge/src/rust/frb_generated.dart';
import 'package:venera_edge/network/download.dart' show DownloadQueueView;
import 'package:venera_edge/utils/io.dart' show copyDirectoryIsolate;
import 'native_migration_test.dart' show runtimeOptions, httpOptions;

Future<void> until(bool Function() check) async {
  await (() async {
    while (!check()) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  })().timeout(const Duration(seconds: 15));
}

Map<String, dynamic> item(String base, String root, {bool archive = false}) => {
  'type': archive ? 'ArchiveDownloadTask' : 'ImagesDownloadTask',
  'source': 'fixture',
  'comicId': 'comic',
  'comicType': 42,
  'path': '$root/local/book',
  'comic': {
    'comicId': 'comic',
    'sourceKey': 'fixture',
    'title': 'Test',
    'cover': '$base/cover',
    'tags': {},
    'chapters': archive ? null : {'a': 'Complete', 'b': 'New'},
  },
  'chapters': archive ? null : ['b'],
  if (archive) 'archiveUrl': '$base/archive',
};

Future<ComicDownloadQueue> queue(
  ScriptRuntime runtime,
  Directory root, {
  bool saf = false,
}) => ComicDownloadQueue.open(
  runtime: runtime,
  optionsJson: jsonEncode({
    'data_path': root.path,
    'cache_path': root.path,
    'local_path': '${root.path}/local',
    'saf': saf,
    'threads': 1,
    'http': httpOptions,
  }),
  sourceTypesJson: '{"fixture":42}',
);

Future<void> existing(Directory root) async {
  await Directory('${root.path}/local/book/a').create(recursive: true);
  await File('${root.path}/local/book/a/0.png').writeAsBytes([1, 2, 3]);
  await File('${root.path}/local/book/cover.png').writeAsBytes([1, 2, 3]);
  await File('${root.path}/local/book/notes.txt').writeAsString('user file');
  final store = await LocalStore.open(path: '${root.path}/local.db');
  store.save(
    comicJson: jsonEncode({
      'id': 'comic',
      'title': 'Existing',
      'subtitle': '',
      'tags': <String>[],
      'directory': 'book',
      'chapters': {'a': 'Complete', 'b': 'New'},
      'cover': 'cover.png',
      'comic_type': 42,
      'downloaded_chapters': ['a'],
      'created_at': 1,
    }),
  );
  store.close();
  store.dispose();
}

Future<void> copyTree(String from, String to) async {
  await Directory(to).create(recursive: true);
  await for (final entry in Directory(from).list()) {
    final name = entry.path.split(Platform.pathSeparator).last;
    if (entry is Directory) {
      await copyTree(entry.path, '$to/$name');
    } else if (entry is File) {
      await entry.copy('$to/$name');
    }
  }
}

void main() {
  final library = Platform.environment['VENERA_BACKEND_LIBRARY'];
  if (library == null) {
    test(
      'download cleanup native integration',
      () {},
      skip: 'Set VENERA_BACKEND_LIBRARY',
    );
    return;
  }
  setUpAll(() => RustLib.init(externalLibrary: ExternalLibrary.open(library)));
  tearDownAll(RustLib.dispose);

  test(
    'directory copy awaits nested write errors before the platform receipt',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'venera_copy_receipt_',
      );
      try {
        await Directory('${root.path}/source/chapter').create(recursive: true);
        await File('${root.path}/source/chapter/0.png').writeAsBytes([1, 2, 3]);
        await Directory('${root.path}/destination').create();
        await File(
          '${root.path}/destination/chapter',
        ).writeAsString('existing file');
        await expectLater(
          copyDirectoryIsolate(
            Directory('${root.path}/source'),
            Directory('${root.path}/destination'),
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(
          await File('${root.path}/destination/chapter').readAsString(),
          'existing file',
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'cancel then immediately download again preserves existing chapters and user files',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'venera_cancel_restart_',
      );
      await existing(root);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = 'http://127.0.0.1:${server.port}';
      final blocked = Completer<void>();
      final disconnected = Completer<void>();
      var hold = true;
      final bytes = await File('assets/app_icon.png').readAsBytes();
      final subscription = server.listen((request) async {
        if (hold && request.uri.path == '/blocked') {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.listen(
            (_) {},
            onDone: () {
              if (!disconnected.isCompleted) disconnected.complete();
              socket.destroy();
            },
          );
          blocked.complete();
          return;
        }
        request.response.headers.set('cache-control', 'no-store');
        request.response.add(bytes);
        await request.response.close();
      });
      final runtime = await ScriptRuntime.open(
        optionsJson: runtimeOptions(root.path),
      );
      await runtime.parseSource(
        code:
            "class Fixture extends ComicSource {name='Fixture';key='fixture';version='1.0.0';comic={loadEp:()=>({images:['$base/first','$base/blocked']})};}",
      );
      final download = await queue(runtime, root);
      try {
        await download.add(taskJson: jsonEncode(item(base, root.path)));
        await blocked.future.timeout(const Duration(seconds: 5));
        final oldToken =
            (jsonDecode(download.snapshot()) as List).single['_work'];
        final cancelled = download.command(
          key: 'fixture@comic',
          action: 'cancel',
        );
        hold = false;
        await download.add(taskJson: jsonEncode(item(base, root.path)));
        await cancelled;
        await disconnected.future.timeout(const Duration(seconds: 5));
        await until(() {
          final rows = jsonDecode(download.snapshot()) as List;
          if (rows.any((row) => row['_error'] == true)) fail(jsonEncode(rows));
          return rows.isEmpty;
        });
        final store = await LocalStore.open(path: '${root.path}/local.db');
        expect(
          jsonDecode(
            store.find(id: 'comic', comicType: 42)!,
          )['downloaded_chapters'],
          containsAll(['a', 'b']),
        );
        store.close();
        store.dispose();
        expect(await File('${root.path}/local/book/a/0.png').readAsBytes(), [
          1,
          2,
          3,
        ]);
        expect(
          await File('${root.path}/local/book/notes.txt').readAsString(),
          'user file',
        );
        expect(
          await File('${root.path}/local/book/b/0.png').readAsBytes(),
          bytes,
        );
        expect(
          await File('${root.path}/local/book/b/1.png').readAsBytes(),
          bytes,
        );
        expect(
          Directory('${root.path}/download_work/jobs/$oldToken').existsSync(),
          false,
        );
        expect(
          jsonDecode(
            await File('${root.path}/download_cleanup.json').readAsString(),
          ),
          isEmpty,
        );
        expect(
          Directory('${root.path}/download_work/owners').listSync(),
          isEmpty,
        );
      } finally {
        runtime.close();
        runtime.dispose();
        download.dispose();
        await subscription.cancel();
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'archive cancellation waits for range writes and removes archive plus resume metadata',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'venera_cancel_archive_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = 'http://127.0.0.1:${server.port}';
      final arrived = Completer<void>();
      final disconnected = Completer<void>();
      const size = 1024 * 1024;
      final subscription = server.listen((request) async {
        if (request.headers.value('range') == 'bytes=0-0') {
          request.response.statusCode = 206;
          request.response.headers.set('content-range', 'bytes 0-0/$size');
          request.response.headers.set('etag', '"fixture"');
          request.response.add([1]);
          await request.response.close();
          return;
        }
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.write(
          'HTTP/1.1 206 Partial Content\r\nContent-Length: $size\r\nContent-Range: bytes 0-${size - 1}/$size\r\nETag: "fixture"\r\nConnection: close\r\n\r\n',
        );
        socket.add(List.filled(8192, 7));
        await socket.flush();
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
        optionsJson: runtimeOptions(root.path),
      );
      final download = await queue(runtime, root);
      try {
        await download.add(
          taskJson: jsonEncode(item(base, root.path, archive: true)),
        );
        await arrived.future.timeout(const Duration(seconds: 5));
        final owner = (jsonDecode(download.snapshot()) as List).single['_work'];
        final stage = '${root.path}/download_work/jobs/$owner';
        await until(
          () => File('$stage/archive.zip.download.meta').existsSync(),
        );
        await download.command(key: 'fixture@comic', action: 'cancel');
        await disconnected.future.timeout(const Duration(seconds: 5));
        expect((jsonDecode(download.snapshot()) as List), isEmpty);
        expect(Directory(stage).existsSync(), false);
        final store = await LocalStore.open(path: '${root.path}/local.db');
        expect(store.find(id: 'comic', comicType: 42), isNull);
        store.close();
        store.dispose();
      } finally {
        runtime.close();
        runtime.dispose();
        download.dispose();
        await subscription.cancel();
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'SAF cancellation waits for copy receipt and failed cleanup can be retried',
    () async {
      final root = await Directory.systemTemp.createTemp('venera_cancel_saf_');
      await existing(root);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bytes = await File('assets/app_icon.png').readAsBytes();
      final subscription = server.listen((request) async {
        request.response.add(bytes);
        await request.response.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      final runtime = await ScriptRuntime.open(
        optionsJson: runtimeOptions(root.path),
      );
      await runtime.parseSource(
        code:
            "class Fixture extends ComicSource {name='Fixture';key='fixture';version='1.0.0';comic={loadEp:()=>({images:['$base/image']})};}",
      );
      final download = await queue(runtime, root, saf: true);
      final copying = Completer<void>();
      final release = Completer<void>();
      var failCleanup = true;
      String? mirror;
      var finished = false;
      final platform = () async {
        while (true) {
          final encoded = await download.nextPlatformEvent();
          if (encoded == null) return;
          final event = jsonDecode(encoded);
          final from = event['from'] as String;
          final to = event['to'] as String?;
          String? error;
          dynamic value;
          var stop = false;
          try {
            switch (event['operation']) {
              case 'exists':
                value =
                    await File(from).exists() || await Directory(from).exists();
              case 'listFiles':
                value = await Directory(from)
                    .list()
                    .where((entry) => entry is File)
                    .map(
                      (entry) => entry.path.split(Platform.pathSeparator).last,
                    )
                    .toList();
              case 'copyDirectory':
                mirror = to;
                copying.complete();
                await release.future;
                await copyTree(from, to!);
              case 'removeDirectory':
                if (failCleanup) throw StateError('provider denied deletion');
                await Directory(from).delete(recursive: true);
                stop = true;
              default:
                throw StateError(
                  'Unexpected platform operation ${event['operation']}',
                );
            }
          } catch (e) {
            error = e.toString();
          }
          await download.resolvePlatform(
            id: event['id'],
            error: error,
            valueJson: jsonEncode(value),
          );
          if (stop) return;
        }
      }();
      try {
        await download.add(taskJson: jsonEncode(item(base, root.path)));
        await copying.future.timeout(const Duration(seconds: 5));
        final owner = (jsonDecode(download.snapshot()) as List).single['_work'];
        final cancelling = download
            .command(key: 'fixture@comic', action: 'cancel')
            .then<Object?>(
              (_) {
                finished = true;
                return null;
              },
              onError: (Object error) {
                finished = true;
                return error;
              },
            );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(finished, false);
        release.complete();
        expect(await cancelling, isNotNull);
        final pending = (jsonDecode(download.snapshot()) as List).single;
        expect(pending['_cleanupOnly'], true);
        expect(pending['_error'], true);
        expect(pending['message'], contains('Cleanup pending'));
        expect(Directory(mirror!).existsSync(), true);
        final store = await LocalStore.open(path: '${root.path}/local.db');
        expect(
          jsonDecode(
            store.find(id: 'comic', comicType: 42)!,
          )['downloaded_chapters'],
          ['a'],
        );
        store.close();
        store.dispose();
        failCleanup = false;
        await download.command(key: 'fixture@comic', action: 'resume');
        await platform;
        await until(() {
          final rows = jsonDecode(download.snapshot()) as List;
          if (rows.any((row) => row['_error'] == true)) fail(jsonEncode(rows));
          return rows.isEmpty;
        });
        expect(Directory(mirror!).existsSync(), false);
        expect(
          Directory('${root.path}/download_work/jobs/$owner').existsSync(),
          false,
        );
        expect(await File('${root.path}/local/book/a/0.png').readAsBytes(), [
          1,
          2,
          3,
        ]);
        expect(
          await File('${root.path}/local/book/notes.txt').readAsString(),
          'user file',
        );
        expect(Directory('${root.path}/local/book/b').existsSync(), false);
      } finally {
        if (!release.isCompleted) release.complete();
        runtime.close();
        runtime.dispose();
        download.dispose();
        await subscription.cancel();
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'successful SAF promotion uses the application adapter and preserves previous content',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'venera_saf_promotion_',
      );
      await existing(root);
      final bytes = await File('assets/app_icon.png').readAsBytes();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        request.response.add(bytes);
        await request.response.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      final runtime = await ScriptRuntime.open(
        optionsJson: runtimeOptions(root.path),
      );
      await runtime.parseSource(
        code:
            "class Fixture extends ComicSource {name='Fixture';key='fixture';version='1.0.0';comic={loadEp:()=>({images:['$base/image']})};}",
      );
      final download = await queue(runtime, root, saf: true);
      String? mirror;
      final platform = () async {
        while (true) {
          final encoded = await download.nextPlatformEvent();
          if (encoded == null) return;
          final event = Map<String, dynamic>.from(jsonDecode(encoded));
          if (event['operation'] == 'copyDirectory') mirror = event['to'];
          String? error;
          dynamic result;
          try {
            result = await DownloadQueueView.handlePlatformOperation(event);
          } catch (e) {
            error = e.toString();
          }
          await download.resolvePlatform(
            id: event['id'],
            error: error,
            valueJson: jsonEncode(result),
          );
          if (event['operation'] == 'removeDirectory' && error == null) return;
        }
      }();
      try {
        await download.add(taskJson: jsonEncode(item(base, root.path)));
        await platform.timeout(const Duration(seconds: 10));
        await until(() {
          final rows = jsonDecode(download.snapshot()) as List;
          if (rows.any((row) => row['_error'] == true)) fail(jsonEncode(rows));
          return rows.isEmpty;
        });
        final store = await LocalStore.open(path: '${root.path}/local.db');
        expect(
          jsonDecode(
            store.find(id: 'comic', comicType: 42)!,
          )['downloaded_chapters'],
          containsAll(['a', 'b']),
        );
        store.close();
        store.dispose();
        expect(
          await File('${root.path}/local/book/b/0.png').readAsBytes(),
          bytes,
        );
        expect(await File('${root.path}/local/book/a/0.png').readAsBytes(), [
          1,
          2,
          3,
        ]);
        expect(
          await File('${root.path}/local/book/notes.txt').readAsString(),
          'user file',
        );
        expect(Directory(mirror!).existsSync(), false);
        expect(
          Directory('${root.path}/download_work/owners').listSync(),
          isEmpty,
        );
      } finally {
        runtime.close();
        runtime.dispose();
        download.dispose();
        await subscription.cancel();
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );
}
