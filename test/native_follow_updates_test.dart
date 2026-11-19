import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_edge/src/rust/api/favorites.dart';
import 'package:venera_edge/src/rust/api/follow_updates.dart';
import 'package:venera_edge/src/rust/api/script.dart';
import 'package:venera_edge/src/rust/frb_generated.dart';

Future<Map<String, dynamic>> finish(FollowUpdateTask task) async {
  while (true) {
    final encoded = await task.nextSnapshot().timeout(
      const Duration(seconds: 10),
    );
    if (encoded == null) throw StateError('Missing terminal snapshot');
    final snapshot = jsonDecode(encoded) as Map<String, dynamic>;
    if (snapshot['status'] != 'running') return snapshot;
  }
}

void main() {
  final library = Platform.environment['VENERA_BACKEND_LIBRARY'];
  if (library == null) {
    test(
      'follow updates native integration',
      () {},
      skip: 'Set VENERA_BACKEND_LIBRARY',
    );
    return;
  }
  setUpAll(() => RustLib.init(externalLibrary: ExternalLibrary.open(library)));
  tearDownAll(RustLib.dispose);

  test(
    'FRB folder checks persist metadata, skip recent checks and cancel pending HTTP',
    () async {
      final directory = await Directory.systemTemp.createTemp('venera_follow_');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final arrived = Completer<void>();
      final disconnected = Completer<void>();
      var requests = 0;
      final subscription = server.listen((request) async {
        requests++;
        if (request.uri.path == '/slow') {
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
          if (!arrived.isCompleted) arrived.complete();
          return;
        }
        request.response.write('ok');
        await request.response.close();
      });
      final runtime = await ScriptRuntime.open(
        optionsJson: jsonEncode({
          'data_path': directory.path,
          'version': '1.6.3',
          'locale': 'zh_CN',
          'platform': 'windows',
          'user_agent': 'test',
          'http': {
            'proxy': null,
            'dns_overrides': <String, String>{},
            'tls_sni': true,
            'verify_certificates': true,
            'connect_timeout_ms': 3000,
            'receive_timeout_ms': 30000,
            'max_redirects': 5,
          },
        }),
      );
      final store = await FavoriteStore.open(
        path: '${directory.path}/favorite.db',
        traditional: false,
      );
      final service = await FollowUpdateService.open(
        runtime: runtime,
        favorites: store,
      );
      final tasks = <FollowUpdateTask>[];
      try {
        await runtime.parseSource(
          code:
              '''
class FollowTest extends ComicSource {
  name='Follow'; key='follow'; version='1.0.0';
  comic={loadInfo:async(id)=>{
    await Network.get('http://127.0.0.1:${server.port}/'+id);
    if(id==='slow') await Network.get('http://127.0.0.1:${server.port}/late');
    return {title:'New',cover:'new-cover',subtitle:'New author',tags:{genre:['action']},updateTime:'2026-11-16'};
  }};
}
''',
        );
        store.create(name: 'Follow', renameInvalid: false);
        for (final id in ['ok', 'slow']) {
          store.add(
            folder: 'Follow',
            comicJson: jsonEncode({
              'id': id,
              'name': 'Old',
              'author': 'Old',
              'type': 42,
              'tags': <String>[],
              'coverPath': 'old-cover',
            }),
            atEnd: true,
            traditional: false,
          );
        }
        await service.configure(
          paused: false,
          traditional: false,
          sourceTypesJson: '{"42":"follow"}',
        );
        Future<FollowUpdateTask> start(String id, bool force) async {
          final task = await service.start(
            folder: 'Follow',
            force: force,
            keysJson: jsonEncode([
              {'id': id, 'type': 42},
            ]),
          );
          tasks.add(task);
          return task;
        }

        var result = await finish(await start('ok', true));
        expect(result['updated'], 1);
        final row = jsonDecode(
          store.get_(folder: 'Follow', id: 'ok', comicType: 42)!,
        );
        expect(row['name'], 'New');
        expect(row['tags'], ['genre:action']);
        expect(row['has_new_update'], true);
        result = await finish(await start('ok', false));
        expect(result['skipped'], 1);
        expect(requests, 1);

        final slow = await start('slow', true);
        final waiting = finish(slow);
        await arrived.future.timeout(const Duration(seconds: 10));
        await expectLater(
          service.start(folder: 'Follow', force: true),
          throwsA(anything),
        );
        slow.cancel();
        expect((await waiting)['status'], 'cancelled');
        await slow.wait();
        await disconnected.future.timeout(const Duration(seconds: 5));
        expect(requests, 2);
        expect(
          jsonDecode(
            store.get_(folder: 'Follow', id: 'slow', comicType: 42)!,
          )['last_check_time'],
          null,
        );
        expect((await finish(await start('ok', true)))['updated'], 0);
        expect(runtime.evaluate(source: '1+1'), '["number",2]');
        expect(
          findUpdateTime(infoJson: '{"tags":{"最后更新":["2026-01-02"]}}'),
          '2026-1-2',
        );
      } finally {
        for (final task in tasks) {
          task.cancel();
          await task.wait();
          task.dispose();
        }
        await service.close();
        service.dispose();
        store.close();
        store.dispose();
        runtime.close();
        runtime.dispose();
        await subscription.cancel();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'forked source platform replies reach the correct QuickJS worker',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'venera_follow_ui_',
      );
      final runtime = await ScriptRuntime.open(
        optionsJson: jsonEncode({
          'data_path': directory.path,
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
      final store = await FavoriteStore.open(
        path: '${directory.path}/favorite.db',
        traditional: false,
      );
      final service = await FollowUpdateService.open(
        runtime: runtime,
        favorites: store,
      );
      FollowUpdateTask? task;
      try {
        await runtime.parseSource(
          code: '''
class FollowUi extends ComicSource {
  name='UI'; key='ui'; version='1.0.0';
  comic={loadInfo:async()=>({title:await getClipboard(),cover:'cover',tags:{}})};
}
''',
        );
        store.create(name: 'Follow', renameInvalid: false);
        store.add(
          folder: 'Follow',
          comicJson:
              '{"id":"id","name":"Old","author":"Author","type":42,"tags":[],"coverPath":"cover"}',
          atEnd: true,
          traditional: false,
        );
        await service.configure(
          paused: false,
          traditional: false,
          sourceTypesJson: '{"42":"ui"}',
        );
        task = await service.start(folder: 'Follow', force: true);
        final event = jsonDecode(
          (await runtime.nextEvent().timeout(const Duration(seconds: 5)))!,
        );
        runtime.resolveEvent(
          id: event['ticket'],
          valueJson: '["string","Clipboard title"]',
        );
        expect((await finish(task))['errors'], 0);
        expect(
          jsonDecode(
            store.get_(folder: 'Follow', id: 'id', comicType: 42)!,
          )['name'],
          'Clipboard title',
        );
      } finally {
        task?.cancel();
        if (task != null) {
          await task.wait();
          task.dispose();
        }
        await service.close();
        service.dispose();
        store.close();
        store.dispose();
        runtime.close();
        runtime.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
