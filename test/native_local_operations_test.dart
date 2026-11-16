import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/script_bridge.dart';
import 'package:venera/foundation/local.dart' as models;
import 'package:venera/foundation/image_provider/local_comic_image.dart';
import 'package:venera/src/rust/api/favorites.dart';
import 'package:venera/src/rust/api/local.dart';
import 'package:venera/src/rust/api/script.dart';
import 'package:venera/src/rust/frb_generated.dart';

class Fixture {
  final Directory directory;
  final ScriptRuntime runtime;
  final bool saf;
  late final Future<void> events;
  Completer<void>? copying;
  Completer<void>? release;
  bool failCopy = false;
  bool failRename = false;
  bool failRemove = false;

  Fixture(this.directory, this.runtime, this.saf) {
    events = pump();
  }

  String get root => saf ? 'android://library' : '${directory.path}/library';
  String get options => jsonEncode({
    'data_path': '${directory.path}/data',
    'cache_path': '${directory.path}/cache',
    'local_path': root,
    'traditional': false,
    'at_end': true,
  });

  static Future<Fixture> open({bool saf = false}) async {
    final directory = await Directory.systemTemp.createTemp('venera_local_');
    for (final child in ['data', 'cache', 'library', 'source']) {
      await Directory('${directory.path}/$child').create();
    }
    final runtime = await ScriptRuntime.open(
      optionsJson: jsonEncode({
        'data_path': '${directory.path}/data',
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
          'receive_timeout_ms': 1000,
          'max_redirects': 5,
        },
      }),
    );
    return Fixture(directory, runtime, saf);
  }

  String native(String path) => path.startsWith('android://')
      ? '${directory.path}/${path.substring('android://'.length)}'
      : path;

  Future<void> book(String name) async {
    final book = Directory('${directory.path}/source/$name');
    await book.create();
    await File('${book.path}/1.jpg').writeAsBytes([1]);
    await File('${book.path}/2.jpg').writeAsBytes([2]);
  }

  Future<void> pump() async {
    final session = ScriptSession(runtime);
    while (true) {
      final encoded = await runtime.nextEvent();
      if (encoded == null) return;
      final event = jsonDecode(encoded);
      if (event['event'] != 'platform') continue;
      final data = session.decode(event['data']) as Map;
      if (data['text'] == '__local_test_stop') return;
      dynamic result;
      String? error;
      try {
        final path = data['path'] as String;
        final mapped = native(path);
        final to = data['to'] as String?;
        switch (data['operation']) {
          case 'list':
            result = await Directory(mapped)
                .list()
                .map(
                  (entry) => {
                    'path': '$path/${entry.path.split(RegExp(r'[/\\]')).last}',
                    'is_dir': entry is Directory,
                  },
                )
                .toList();
          case 'exists':
            result =
                await Directory(mapped).exists() || await File(mapped).exists();
          case 'modified':
            result = (await Directory(
              mapped,
            ).stat()).modified.millisecondsSinceEpoch;
          case 'mkdir':
            await Directory(mapped).create();
          case 'copy':
            if (path.contains('/B/') &&
                copying != null &&
                !copying!.isCompleted) {
              copying!.complete();
              await release!.future;
            }
            if (failCopy && path.endsWith('/2.jpg')) {
              throw StateError('Provider copy failed');
            }
            await File(
              native(to!),
            ).writeAsBytes(await File(mapped).readAsBytes());
          case 'rename':
            if (failRename) throw StateError('Provider rename failed');
            await Directory(mapped).rename(native(to!));
          case 'remove':
            if (failRemove) {
              final files = await Directory(
                mapped,
              ).list().where((entry) => entry is File).toList();
              if (files.isNotEmpty) await files.first.delete();
              throw StateError('Provider deletion partially failed');
            }
            await Directory(mapped).delete(recursive: true);
          default:
            throw StateError('Unexpected platform operation');
        }
      } catch (exception) {
        error = exception.toString();
      }
      runtime.resolveEvent(
        id: event['ticket'],
        valueJson: jsonEncode(encodeScriptValue(result)),
        error: error,
      );
    }
  }

  Future<LocalOperation> start(Map<String, dynamic> request) =>
      LocalOperation.start(
        runtime: runtime,
        optionsJson: options,
        requestJson: jsonEncode(request),
      );

  Future<Map<String, dynamic>> finish(LocalOperation operation) async {
    try {
      while (true) {
        final event = jsonDecode(
          (await operation.next().timeout(const Duration(seconds: 10)))!,
        );
        if (event['kind'] == 'result') {
          return Map<String, dynamic>.from(event['result']);
        }
      }
    } finally {
      operation.dispose();
    }
  }

  Future<Map<String, dynamic>> run(Map<String, dynamic> request) async =>
      finish(await start(request));

  Future<void> close() async {
    runtime.evaluate(
      source:
          "sendMessage({method:'UI',function:'showMessage',text:'__local_test_stop'})",
    );
    await events.timeout(const Duration(seconds: 5));
    runtime.close();
    runtime.dispose();
    await directory.delete(recursive: true);
  }
}

void main() {
  final library = Platform.environment['VENERA_BACKEND_LIBRARY'];
  if (library == null) {
    test(
      'local operation native integration',
      () {},
      skip: 'Set VENERA_BACKEND_LIBRARY',
    );
    return;
  }
  setUpAll(() => RustLib.init(externalLibrary: ExternalLibrary.open(library)));
  tearDownAll(RustLib.dispose);

  test(
    'changing a deleted chapter cover changes the Flutter image cache identity',
    () {
      final row = {
        'id': '1',
        'title': 'Book',
        'subtitle': '',
        'tags': <String>[],
        'directory': '/book',
        'chapters': null,
        'comic_type': 0,
        'downloaded_chapters': <String>[],
        'created_at': 0,
      };
      final old = LocalComicImageProvider(
        models.LocalComic.fromBackend({...row, 'cover': 'One/1.jpg'}),
      );
      final updated = LocalComicImageProvider(
        models.LocalComic.fromBackend({...row, 'cover': 'Two/1.jpg'}),
      );
      expect(old.key, isNot(updated.key));
    },
  );

  test(
    'SAF cancellation waits for receipts, preserves completed imports and reports recoverable failures',
    () async {
      final f = await Fixture.open(saf: true);
      final store = await LocalStore.open(
        path: '${f.directory.path}/data/local.db',
      );
      try {
        await f.book('A');
        await f.book('B');
        f.copying = Completer<void>();
        f.release = Completer<void>();
        final operation = await f.start({
          'mode': 'directories',
          'path': 'android://source',
          'copy': true,
          'folder': 'Favorites',
        });
        var finished = false;
        final result = f.finish(operation).then((value) {
          finished = true;
          return value;
        });
        await f.copying!.future.timeout(const Duration(seconds: 5));
        operation.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(finished, false);
        f.release!.complete();
        final cancelled = await result;
        expect(cancelled['cancelled'], true);
        expect((cancelled['imported'] as List).length, 1);
        expect(cancelled['errors'], isEmpty);
        expect(store.count(), 1);
        expect(Directory('${f.directory.path}/source/B').existsSync(), true);
        expect(Directory('${f.directory.path}/library').listSync().length, 1);
        f.failCopy = true;
        final failed = await f.run({
          'mode': 'directory',
          'path': 'android://source/B',
          'copy': true,
        });
        expect(
          (failed['errors'] as List).single['error'],
          contains('Provider copy failed'),
        );
        expect(store.count(), 1);
        expect(Directory('${f.directory.path}/library').listSync().length, 1);
        f.failCopy = false;
        final imported = await f.run({
          'mode': 'directory',
          'path': 'android://source/B',
          'copy': true,
        });
        expect(imported['errors'], isEmpty);
        expect(store.count(), 2);
        final comic = (cancelled['imported'] as List).single as Map;
        final keys = [
          {'id': comic['id'], 'type': 0},
        ];
        f.failRename = true;
        final refused = await f.run({'mode': 'delete', 'keys': keys});
        expect(
          (refused['errors'] as List).single['error'],
          contains('Provider rename failed'),
        );
        expect(store.count(), 2);
        f.failRename = false;
        f.failRemove = true;
        final deleted = await f.run({'mode': 'delete', 'keys': keys});
        expect((deleted['removed'] as List).length, 1);
        expect(deleted['recovery_pending'], true);
        expect(store.count(), 1);
        expect(
          Directory('${f.directory.path}/data/local_operations').listSync(),
          isNotEmpty,
        );
        f.failRemove = false;
        final recovered = await f.run({'mode': 'recover'});
        expect(recovered['errors'], isEmpty);
        expect(recovered['recovered'], 1);
        expect(
          Directory('${f.directory.path}/data/local_operations').listSync(),
          isEmpty,
        );
        expect(Directory('${f.directory.path}/library').listSync().length, 1);
      } finally {
        store.close();
        store.dispose();
        await f.close();
      }
    },
  );

  test(
    'archive batches register atomically and retained associations never reuse a removed local ID',
    () async {
      final f = await Fixture.open();
      final store = await LocalStore.open(
        path: '${f.directory.path}/data/local.db',
      );
      final favorites = await FavoriteStore.open(
        path: '${f.directory.path}/data/local_favorite.db',
        traditional: false,
      );
      try {
        final archive = Archive()
          ..addFile(ArchiveFile('1.jpg', 1, [1]))
          ..addFile(ArchiveFile('2.jpg', 1, [2]));
        final metadata = utf8.encode(
          jsonEncode({
            'title': 'Archive Book',
            'author': 'Author',
            'tags': ['Tag'],
            'chapters': [
              {'title': 'One', 'start': 1, 'end': 1},
              {'title': 'Two', 'start': 2, 'end': 2},
            ],
          }),
        );
        archive.addFile(
          ArchiveFile('metadata.json', metadata.length, metadata),
        );
        final input = '${f.directory.path}/source/book.cbz';
        await File(input).writeAsBytes(ZipEncoder().encode(archive));
        await File(
          '${f.directory.path}/source/broken.cbz',
        ).writeAsBytes([0, 1]);
        final batch = await f.run({
          'mode': 'archives',
          'path': '${f.directory.path}/source',
          'folder': 'Favorites',
        });
        expect((batch['imported'] as List).length, 1);
        expect((batch['errors'] as List).length, 1);
        final comic = (batch['imported'] as List).single as Map;
        final id = comic['id'] as String;
        expect(comic['subtitle'], 'Author');
        expect(comic['downloaded_chapters'], ['0', '1']);
        expect(Directory('${f.root}/${comic['directory']}').existsSync(), true);
        final images = await f.run({
          'mode': 'images',
          'id': id,
          'type': 0,
          'episode': '1',
        });
        expect(images['errors'], isEmpty);
        expect((images['images'] as List).length, 1);
        final duplicate = await f.run({'mode': 'archive', 'path': input});
        expect((duplicate['skipped'] as List).length, 1);
        final deleted = await f.run({
          'mode': 'delete',
          'keys': [
            {'id': id, 'type': 0},
          ],
          'remove_files': false,
          'clear_associations': false,
        });
        expect(deleted['errors'], isEmpty);
        expect(store.count(), 0);
        expect(favorites.find(id: id, comicType: 0), ['Favorites']);
        expect(Directory('${f.root}/${comic['directory']}').existsSync(), true);
        final again = await f.run({'mode': 'archive', 'path': input});
        expect(again['errors'], isEmpty);
        final next = (again['imported'] as List).single as Map;
        expect(int.parse(next['id']), greaterThan(int.parse(id)));
        expect(favorites.find(id: next['id'], comicType: 0), isEmpty);
        final removed = await f.run({
          'mode': 'delete',
          'keys': [
            {'id': next['id'], 'type': 0},
          ],
        });
        expect(removed['errors'], isEmpty);
        expect(Directory('${f.root}/${next['directory']}').existsSync(), false);
      } finally {
        favorites.close();
        favorites.dispose();
        store.close();
        store.dispose();
        await f.close();
      }
    },
  );
}
