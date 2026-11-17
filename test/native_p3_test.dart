import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/script_bridge.dart';
import 'package:venera/src/rust/api/comic_queue.dart';
import 'package:venera/src/rust/api/favorites.dart';
import 'package:venera/src/rust/api/follow_updates.dart';
import 'package:venera/src/rust/api/history.dart';
import 'package:venera/src/rust/api/local.dart';
import 'package:venera/src/rust/api/media.dart';
import 'package:venera/src/rust/api/script.dart';
import 'package:venera/src/rust/frb_generated.dart';

import 'native_follow_updates_test.dart' show finish;
import 'native_local_operations_test.dart' show Fixture;
import 'native_migration_test.dart' show httpOptions, runtimeOptions;

const _timeout = Duration(seconds: 10);

Future<Map<String, dynamic>> finishImport(FavoriteImportTask task) async {
  while (true) {
    final event = jsonDecode((await task.nextSnapshot().timeout(_timeout))!);
    if (event['status'] != 'running') return Map<String, dynamic>.from(event);
  }
}

Future<ImageProgress> finishImage(ImageTransfer task) async {
  while (true) {
    final event = (await task.next().timeout(_timeout))!;
    if (event.bytes != null || event.error != null) return event;
  }
}

Map<String, dynamic> favorite(String id) => {
  'id': id,
  'name': 'Old title',
  'author': 'Old author',
  'type': 42,
  'tags': <String>[],
  'coverPath': 'old-cover',
};

Map<String, dynamic> localComic(
  String id,
  String directory, {
  String cover = 'missing.jpg',
}) => {
  'id': id,
  'title': 'Local',
  'subtitle': '',
  'tags': <String>[],
  'directory': directory,
  'chapters': null,
  'cover': cover,
  'comic_type': 0,
  'downloaded_chapters': <String>[],
  'created_at': 1,
};

void main() {
  final library = Platform.environment['VENERA_BACKEND_LIBRARY'];
  if (library == null) {
    test('P3 native integration', () {}, skip: 'Set VENERA_BACKEND_LIBRARY');
    return;
  }
  setUpAll(() => RustLib.init(externalLibrary: ExternalLibrary.open(library)));
  tearDownAll(RustLib.dispose);

  late Directory root;
  late ScriptRuntime runtime;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera_p3_');
    runtime = await ScriptRuntime.open(optionsJson: runtimeOptions(root.path));
  });
  tearDown(() async {
    runtime.close();
    runtime.dispose();
    await root.delete(recursive: true);
  });

  test('manual favorite refresh preserves follow-state fields', () async {
    final store = await FavoriteStore.open(
      path: '${root.path}/local_favorite.db',
      traditional: false,
    );
    final service = await FollowUpdateService.open(
      runtime: runtime,
      favorites: store,
    );
    try {
      await runtime.parseSource(
        code: r"""
class Fixture extends ComicSource {
  name='Fixture'; key='fixture'; version='1.0.0';
  comic={loadInfo: async () => ({title:'Refreshed',cover:'cover-new',tags:{author:['Original'],genre:['Mystery']},updateTime:'2025-01-30'})};
}
""",
      );
      store.create(name: 'Follow', renameInvalid: false);
      store.add(
        folder: 'Follow',
        comicJson: jsonEncode(favorite('42')),
        atEnd: true,
        traditional: false,
      );
      store.updateCheck(
        folder: 'Follow',
        id: '42',
        comicType: 42,
        updateTime: '2024-12-01',
      );
      final before = jsonDecode(
        store.get_(folder: 'Follow', id: '42', comicType: 42)!,
      );
      await service.configure(
        paused: false,
        traditional: false,
        sourceTypesJson: '{"42":"fixture"}',
      );
      final task = await service.refreshMetadata(folder: 'Follow');
      try {
        expect((await finish(task))['updated'], 1);
        final after = jsonDecode(
          store.get_(folder: 'Follow', id: '42', comicType: 42)!,
        );
        expect(
          [after['name'], after['author'], after['tags']],
          [
            'Refreshed',
            'Original',
            ['genre:Mystery'],
          ],
        );
        for (final key in [
          'has_new_update',
          'last_check_time',
          'last_update_time',
          'time',
        ]) {
          expect(after[key], before[key], reason: key);
        }
      } finally {
        task.dispose();
      }
    } finally {
      await service.close();
      service.dispose();
      store.close();
      store.dispose();
    }
  });

  test(
    'network imports clamp page ranges, deduplicate and keep partial cursor results',
    () async {
      final store = await FavoriteStore.open(
        path: '${root.path}/local_favorite.db',
        traditional: false,
      );
      Future<Map<String, dynamic>> run(
        String source,
        int pageLimit, {
        String? folder,
      }) async {
        final task = await store.importNetwork(
          runtime: runtime,
          requestJson: jsonEncode({
            'source': source,
            'comic_type': 42,
            'page_limit': pageLimit,
            'folder': folder,
            'remote_folder': 'remote-id',
            'at_end': false,
            'traditional': false,
          }),
        );
        try {
          return await finishImport(task);
        } finally {
          task.dispose();
        }
      }

      try {
        await runtime.parseSource(
          code: r"""
class Paged extends ComicSource {
  name='Paged'; key='paged'; version='1.0.0';
  init() { this.saveData('account',['fixture-user','fixture-password']); }
  favorites={isOldToNewSort:true, loadComics: async (page, folder) => {
    if (page < 1 || folder !== 'remote-id') throw Error('Wrong page or folder');
    const book = id => ({id,title:id,cover:'cover',tags:[]});
    return {comics: page===1 ? [book('a')] : [book('a'),book('b')], maxPage:2};
  }};
}
""",
        );
        await runtime.parseSource(
          code: r"""
class Cursor extends ComicSource {
  name='Cursor'; key='cursor'; version='1.0.0';
  init() { this.saveData('account',['fixture-user','fixture-password']); }
  favorites={loadNext: async (next) => {
    if (next) throw Error('Cannot load the next page');
    return {comics:[{id:'partial',title:'Partial',cover:'cover'}],next:'next-token'};
  }};
}
""",
        );
        var result = await run('paged', 100);
        expect(
          [
            result['status'],
            result['pages'],
            result['received'],
            result['added'],
          ],
          ['completed', 2, 3, 2],
          reason: result['error'] as String?,
        );
        expect(store.linked(folder: 'Paged'), ['paged', 'remote-id']);
        final ordered =
            (jsonDecode(store.list(folder: 'Paged', onlyUpdates: false))
                    as List)
                .map((row) => row['id']);
        expect(ordered, ['b', 'a']);
        result = await run('paged', 1);
        expect([result['pages'], result['added']], [1, 0]);
        result = await run('cursor', 5);
        expect(
          [result['status'], result['pages'], result['added']],
          ['failed', 1, 1],
        );
        expect(
          store.get_(folder: 'Cursor', id: 'partial', comicType: 42),
          isNotNull,
        );
        expect(
          (await run('cursor', 1, folder: 'Paged'))['error'],
          'Folder already exists',
        );
      } finally {
        store.close();
        store.dispose();
      }
    },
  );

  test(
    'storage switch uses verified files, rebases legacy rows and survives stale options',
    () async {
      final old = await Directory('${root.path}/old').create();
      final target = await Directory('${root.path}/target').create();
      final last = await Directory('${root.path}/last').create();
      final book = await Directory(
        '${old.path}/legacy/book',
      ).create(recursive: true);
      final content = [0, 1, 2, 3];
      await File('${book.path}/cover.jpg').writeAsBytes(content);
      await File('${old.path}/loose.jpg').writeAsBytes(content);
      await File('${root.path}/local_path').writeAsString(old.path);
      final start = await initializeStorage(
        runtime: runtime,
        dataPath: root.path,
        defaultPath: target.path,
        android: true,
        preferExistingInData: false,
      );
      expect(start, old.path);
      expect(File('${old.path}/.nomedia').existsSync(), isTrue);
      final store = await LocalStore.open(path: '${root.path}/local.db');
      store.save(
        comicJson: jsonEncode(
          localComic('book', book.path, cover: 'cover.jpg'),
        ),
      );
      final options = jsonEncode({
        'data_path': root.path,
        'cache_path': root.path,
        'local_path': old.path,
        'saf': false,
        'threads': 2,
        'http': httpOptions,
      });
      final queue = await ComicDownloadQueue.open(
        runtime: runtime,
        optionsJson: options,
        sourceTypesJson: '{}',
      );
      try {
        await expectLater(
          queue.moveStorage(destination: book.path, android: false),
          throwsA(anything),
        );
        final result = jsonDecode(
          await queue.moveStorage(destination: target.path, android: true),
        );
        expect(result['warnings'], isEmpty);
        expect(result['path'], target.path);
        expect(
          jsonDecode(store.find(id: 'book', comicType: 0)!)['directory'],
          'legacy/book',
        );
        expect(old.listSync(), isEmpty);
        expect(
          File('${target.path}/legacy/book/cover.jpg').readAsBytesSync(),
          content,
        );
        expect(File('${target.path}/loose.jpg').readAsBytesSync(), content);
        await queue.configure(optionsJson: options);
        await queue.moveStorage(destination: last.path, android: false);
        expect(
          File('${last.path}/legacy/book/cover.jpg').readAsBytesSync(),
          content,
        );
        expect(await File('${root.path}/local_path').readAsString(), last.path);
        expect(File('${root.path}/storage_move.json').existsSync(), isFalse);
      } finally {
        queue.dispose();
        store.close();
        store.dispose();
      }
    },
  );

  test(
    'SAF root switch copies descendants and keeps the source on a failed receipt',
    () async {
      final f = await Fixture.open(saf: true);
      try {
        await Directory('${f.native(f.root)}/A/B').create(recursive: true);
        await File('${f.native(f.root)}/A/B/2.jpg').writeAsBytes([2]);
        await Directory('${f.directory.path}/target').create();
        final queue = await ComicDownloadQueue.open(
          runtime: f.runtime,
          sourceTypesJson: '{}',
          optionsJson: jsonEncode({
            ...jsonDecode(f.options),
            'saf': true,
            'threads': 2,
            'http': httpOptions,
          }),
        );
        try {
          f.failCopy = true;
          await expectLater(
            queue.moveStorage(destination: 'android://target', android: false),
            throwsA(anything),
          );
          expect(File('${f.native(f.root)}/A/B/2.jpg').existsSync(), isTrue);
          expect(Directory('${f.directory.path}/target').listSync(), isEmpty);
          f.failCopy = false;
          expect(
            jsonDecode(
              await queue.moveStorage(
                destination: 'android://target',
                android: false,
              ),
            )['warnings'],
            isEmpty,
          );
          expect(
            await File('${f.directory.path}/target/A/B/2.jpg').readAsBytes(),
            [2],
          );
          expect(Directory(f.native(f.root)).listSync(), isEmpty);
        } finally {
          queue.dispose();
        }
      } finally {
        await f.close();
      }
    },
  );

  test(
    'local cover fallback, history cover repair and reader processing run in Rust',
    () async {
      final store = await LocalStore.open(path: '${root.path}/local.db');
      final history = await HistoryStore.open(path: '${root.path}/history.db');
      final images = await Directory(
        '${root.path}/library/Book',
      ).create(recursive: true);
      await File('${images.path}/10.jpg').writeAsBytes([10]);
      final image = await File('${images.path}/2.jpg').writeAsBytes([2]);
      store.save(comicJson: jsonEncode(localComic('local', 'Book')));
      final historyRecord = HistoryEntry(
        id: 'history',
        title: 'Saved',
        subtitle: '',
        cover: 'cover.old',
        timeMs: 42,
        comicType: 42,
        episode: 3,
        page: 9,
        readEpisodes: ['1', '2'],
      );
      await history.save(entry: historyRecord);
      await runtime.parseSource(
        code:
            """
class Covers extends ComicSource {
  name='Covers'; key='covers'; version='1.0.0';
  comic={loadInfo: async () => ({cover:${jsonEncode('file://${image.path}')}, title:'Remote', tags:{}})};
}
""",
      );
      Future<List<int>> load(Map<String, dynamic> request) async {
        final task = await ImageTransfer.startView(
          runtime: runtime,
          dataPath: root.path,
          cachePath: root.path,
          localPath: '${root.path}/library',
          requestJson: jsonEncode(request),
        );
        try {
          final event = await finishImage(task);
          expect(event.error, isNull);
          return event.bytes!;
        } finally {
          task.dispose();
        }
      }

      try {
        expect(
          await load({
            'kind': 'local_cover',
            'comic_type': 0,
            'comic': 'local',
          }),
          [2],
        );
        expect(
          await load({
            'kind': 'history_cover',
            'comic_type': 42,
            'comic': 'history',
            'source': 'covers',
            'image': 'cover.old',
          }),
          [2],
        );
        final repaired = history.find(id: 'history', comicType: 42)!;
        expect(repaired.cover, 'file://${image.path}');
        expect(
          [repaired.title, repaired.episode, repaired.page],
          ['Saved', 3, 9],
        );
        expect(
          await load({
            'kind': 'reader',
            'image': 'file://${image.path}',
            'comic': 'book',
            'chapter': 'chapter',
            'page': 7,
            'processor':
                'async function processImage(bytes,cid,eid,page) {return {image: Promise.resolve(new Uint8Array([page, ...new Uint8Array(bytes)]))};}',
          }),
          [7, 2],
        );
      } finally {
        history.close();
        history.dispose();
        store.close();
        store.dispose();
      }
    },
  );

  test(
    'cancel invokes the reader processor hook and releases a pending script',
    () async {
      final image = await File('${root.path}/page.jpg').writeAsBytes([12]);
      final task = await ImageTransfer.startView(
        runtime: runtime,
        dataPath: root.path,
        cachePath: root.path,
        localPath: root.path,
        requestJson: jsonEncode({
          'kind': 'reader',
          'image': 'file://${image.path}',
          'comic': 'book',
          'chapter': 'chapter',
          'page': 1,
          'processor': r"""
function processImage(bytes) {
  return {image:getClipboard().then(() => bytes),onCancel:() => setClipboard('stopped')};
}
""",
        }),
      );
      final session = ScriptSession(runtime);
      try {
        final pending = jsonDecode(
          (await runtime.nextEvent().timeout(_timeout))!,
        );
        expect(
          (session.decode(pending['data']) as Map)['method'],
          'getClipboard',
        );
        task.cancel();
        final cancel = jsonDecode(
          (await runtime.nextEvent().timeout(_timeout))!,
        );
        expect((session.decode(cancel['data']) as Map)['text'], 'stopped');
        runtime.resolveEvent(
          id: cancel['ticket'],
          valueJson: jsonEncode(encodeScriptValue(null)),
        );
        final result = await finishImage(task);
        expect(result.error, contains('cancelled'));
        expect(result.bytes, isNull);
      } finally {
        session.close();
        task.dispose();
      }
    },
  );
}
