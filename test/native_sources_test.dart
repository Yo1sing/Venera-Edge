import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_edge/foundation/app.dart';
import 'package:venera_edge/foundation/appdata.dart';
import 'package:venera_edge/foundation/js_engine.dart';
import 'package:venera_edge/pages/comic_source_page.dart';
import 'package:venera_edge/src/rust/api/http.dart';
import 'package:venera_edge/src/rust/api/media.dart';
import 'package:venera_edge/src/rust/api/script.dart';
import 'package:venera_edge/src/rust/api/sources.dart';
import 'package:venera_edge/src/rust/frb_generated.dart';
import 'package:venera_edge/foundation/comic_source/comic_source.dart'
    as models;
import 'package:venera_edge/foundation/script_bridge.dart';
import 'package:venera_edge/utils/prism_localizations.dart';
import 'package:venera_edge/utils/translations.dart';

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
    'connect_timeout_ms': 2000,
    'receive_timeout_ms': 10000,
    'max_redirects': 5,
  },
});

String source(String base, String version) =>
    '''
class NativeSource extends ComicSource {
  name='Native';key='native';version='$version';url='$base/native.js';
  comic={loadInfo:()=>({title:'Usable',cover:'cover',tags:{}}),
    onThumbnailLoad:()=>({url:'$base/image'})};
}
''';

void main() {
  final library = Platform.environment['VENERA_BACKEND_LIBRARY'];
  if (library == null) {
    test(
      'source management native integration',
      () {},
      skip: 'Set VENERA_BACKEND_LIBRARY',
    );
    return;
  }
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => RustLib.init(externalLibrary: ExternalLibrary.open(library)));
  tearDownAll(RustLib.dispose);

  testWidgets(
    'subscription batch keeps failures selected and skips duplicate keys',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 800);
      addTearDown(tester.view.reset);
      final directory = Directory.systemTemp.createTempSync('venera_catalog_');
      final downloads = <String>[];
      var failBeta = true;
      HttpServer? server;

      Map<String, String> entry(String key, String name, String fileName) => {
        'key': key,
        'name': name,
        'version': '1.0.0',
        'fileName': fileName,
      };

      Future<void> waitFor(Finder finder) async {
        for (var attempt = 0; attempt < 100; attempt++) {
          await tester.pump(const Duration(milliseconds: 50));
          if (finder.evaluate().isNotEmpty) return;
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
        }
        expect(finder, findsWidgets);
      }

      try {
        await tester.runAsync(() async {
          final listener = server = await HttpServer.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final base = 'http://127.0.0.1:${listener.port}';
          listener.listen((request) async {
            final path = request.uri.path;
            if (path == '/primary.json') {
              request.response.write(
                jsonEncode([
                  entry('alpha', 'Alpha', 'alpha.js'),
                  entry('beta', 'Beta', 'beta.js'),
                ]),
              );
            } else if (path == '/mirror.json') {
              request.response.write(
                jsonEncode([entry('alpha', 'Alpha mirror', 'mirror.js')]),
              );
            } else {
              downloads.add(path);
              if (path == '/beta.js' && failBeta) {
                request.response.statusCode = HttpStatus.notFound;
              } else {
                final key = path == '/beta.js' ? 'beta' : 'alpha';
                request.response.write(
                  "class Fixture extends ComicSource { name='$key'; key='$key'; version='1.0.0'; }",
                );
              }
            }
            await request.response.close();
          });
          App.dataPath = App.cachePath = directory.path;
          await File('${directory.path}/appdata.json').writeAsString(
            jsonEncode({
              'settings': {
                'language': 'en-US',
                'proxy': 'direct',
                'comicSourceListUrls': [
                  '$base/primary.json',
                  '$base/mirror.json',
                ],
              },
            }),
          );
          await AppTranslation.init();
          await appdata.init();
          await JsEngine().init();
          await models.ComicSourceManager().init();
        });

        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: App.rootNavigatorKey,
            localizationsDelegates: const [PrismLocalizations.delegate],
            home: const ComicSourcePage(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.add_circle_outline));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Link'));
        await waitFor(find.text('Beta'));
        await waitFor(find.byIcon(Icons.refresh).at(1));
        await tester.pumpAndSettle();
        final primary = find.textContaining('/primary.json');
        final mirror = find.textContaining('/mirror.json');
        expect(find.text('Alpha mirror'), findsNothing);

        await tester.tap(find.text('Beta'));
        await tester.tap(primary);
        await tester.pump();
        expect(find.text('Beta'), findsNothing);
        expect(find.text('Add selected (1)'), findsOneWidget);
        await tester.tap(find.text('Select All'));
        await tester.pump();
        expect(find.text('Add selected (2)'), findsOneWidget);

        await tester.tap(primary);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<CheckboxListTile>(
                find.widgetWithText(CheckboxListTile, 'Beta'),
              )
              .value,
          isTrue,
        );
        await tester.tap(mirror);
        await waitFor(find.text('Alpha mirror'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Alpha mirror'));
        await tester.pump();
        await tester.tap(find.text('Add selected (2)'));
        await waitFor(find.text('Unable to add comic sources'));
        await tester.pumpAndSettle();
        expect(downloads, ['/beta.js', '/mirror.js']);
        expect(models.ComicSource.all().map((source) => source.key), ['alpha']);

        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Added'), findsNWidgets(2));
        failBeta = false;
        await tester.tap(find.text('Add selected (1)'));
        await waitFor(find.text('Add selected (0)'));
        expect(downloads, ['/beta.js', '/mirror.js', '/beta.js']);
        expect(models.ComicSource.all().map((source) => source.key), [
          'alpha',
          'beta',
        ]);
        await tester.pump(const Duration(seconds: 2));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          JsEngine().dispose();
          await server?.close(force: true);
          await directory.delete(recursive: true);
        });
      }
    },
  );

  test(
    'source URL operations preserve old files on download failure, invalid scripts and cancellation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'venera_sources_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = 'http://127.0.0.1:${server.port}';
      var code = source(base, '1.0.0');
      var status = 200;
      var advertised = '2.0.0';
      var otherAdvertised = '2.5.0';
      var block = false;
      final arrived = Completer<void>();
      final disconnected = Completer<void>();
      final subscription = server.listen((request) async {
        if (request.uri.path == '/index.json' ||
            request.uri.path == '/other.json') {
          request.response.write(
            jsonEncode([
              {
                'key': 'native',
                'name': 'Native',
                'version': request.uri.path == '/index.json'
                    ? advertised
                    : otherAdvertised,
                'fileName': 'native.js',
              },
            ]),
          );
        } else if (block) {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.listen(
            (_) {},
            onDone: () {
              disconnected.complete();
              socket.destroy();
            },
          );
          arrived.complete();
          return;
        } else {
          request.response.statusCode = status;
          request.response.write(code);
        }
        await request.response.close();
      });
      final runtime = await ScriptRuntime.open(
        optionsJson: options(directory.path),
      );
      final manager = await SourceManager.open(runtime: runtime);
      final cancellation = HttpCancellation();
      final cancelUpdate = HttpCancellation();
      try {
        final installed = jsonDecode(
          await manager.installUrl(
            url: '$base/native.js',
            cancellation: cancellation,
          ),
        );
        final path = installed['file_path'] as String;
        final configuration = Map<String, dynamic>.from(
          ScriptSession(runtime).decodeJson(
            runtime.evaluate(source: '__sources.describe("native")'),
          ),
        );
        final model = await models.ComicSourceParser().fromMetadata(
          Map<String, dynamic>.from(installed),
          configuration: configuration,
        );
        expect(model.name, 'Native');
        expect(model.filePath, path);
        expect(model.enableTagsSuggestions, false);
        final original = await File(path).readAsString();
        final catalog = jsonDecode(
          await manager.catalog(
            url: '$base/index.json',
            cancellation: cancellation,
          ),
        );
        expect(catalog.single['url'], '$base/native.js');
        expect(
          jsonDecode(
            await manager.checkUpdates(
              urls: ['$base/index.json', '$base/other.json'],
              cancellation: cancellation,
            ),
          ),
          {'native': '2.5.0'},
        );
        advertised = '1.0.0';
        otherAdvertised = '1.0.0';
        expect(
          jsonDecode(
            await manager.checkUpdates(
              urls: ['$base/index.json', '$base/other.json'],
              cancellation: cancellation,
            ),
          ),
          isEmpty,
        );
        status = 500;
        await expectLater(
          manager.update(key: 'native', cancellation: cancellation),
          throwsA(anything),
        );
        status = 200;
        code = 'invalid';
        await expectLater(
          manager.update(key: 'native', cancellation: cancellation),
          throwsA(anything),
        );
        expect(await File(path).readAsString(), original);
        expect(
          jsonDecode(
            runtime.evaluate(
              source: 'ComicSource.sources.native.comic.loadInfo().title',
            ),
          )[1],
          'Usable',
        );
        block = true;
        final expectation = expectLater(
          manager.update(key: 'native', cancellation: cancelUpdate),
          throwsA(anything),
        );
        await arrived.future.timeout(const Duration(seconds: 5));
        cancelUpdate.cancel();
        await expectation.timeout(const Duration(seconds: 5));
        await disconnected.future.timeout(const Duration(seconds: 5));
        expect(await File(path).readAsString(), original);
        expect(
          jsonDecode(
            runtime.evaluate(source: 'ComicSource.sources.native.version'),
          )[1],
          '1.0.0',
        );
        block = false;
        code = source(base, '2.0.0');
        await manager.update(key: 'native', cancellation: cancellation);
        expect(
          jsonDecode(
            runtime.evaluate(source: 'ComicSource.sources.native.version'),
          )[1],
          '2.0.0',
        );
        expect(await File(path).readAsString(), code);
        await manager.remove(key: 'native', cancellation: cancellation);
        expect(await File(path).exists(), false);
        expect(jsonDecode(manager.snapshot())['sources'], isEmpty);
      } finally {
        cancellation.dispose();
        cancelUpdate.dispose();
        manager.dispose();
        runtime.close();
        runtime.dispose();
        await subscription.cancel();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'source edits wait for an active native image request and cancellation leaves that request usable',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'venera_source_image_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final request = Completer<HttpRequest>();
      final subscription = server.listen(request.complete);
      final base = 'http://127.0.0.1:${server.port}';
      final runtime = await ScriptRuntime.open(
        optionsJson: options(directory.path),
      );
      final manager = await SourceManager.open(runtime: runtime);
      final cancellation = HttpCancellation();
      final cancelUpdate = HttpCancellation();
      ImageTransfer? image;
      try {
        await manager.install(
          code: utf8.encode(source(base, '1.0.0')),
          name: 'legacy-file.js',
          cancellation: cancellation,
        );
        image = await ImageTransfer.start(
          runtime: runtime,
          dataPath: directory.path,
          cachePath: directory.path,
          image: 'image-key',
          source: 'native',
          comic: 'id',
          chapter: '',
          thumbnail: true,
        );
        final pending = await request.future.timeout(
          const Duration(seconds: 5),
        );
        final expectation = expectLater(
          manager.save(
            key: 'native',
            code: source(base, '2.0.0'),
            cancellation: cancelUpdate,
          ),
          throwsA(anything),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          jsonDecode(
            runtime.evaluate(source: 'ComicSource.sources.native.version'),
          )[1],
          '1.0.0',
        );
        cancelUpdate.cancel();
        await expectation.timeout(const Duration(seconds: 5));
        pending.response.add([1, 2, 3]);
        await pending.response.close();
        ImageProgress? progress;
        do {
          progress = await image.next().timeout(const Duration(seconds: 5));
        } while (progress != null &&
            progress.bytes == null &&
            progress.error == null);
        expect(progress?.error, null);
        expect(progress?.bytes, [1, 2, 3]);
        await manager.save(
          key: 'native',
          code: source(base, '2.0.0'),
          cancellation: cancellation,
        );
        expect(
          jsonDecode(
            runtime.evaluate(source: 'ComicSource.sources.native.version'),
          )[1],
          '2.0.0',
        );
      } finally {
        image?.cancel();
        image?.dispose();
        cancellation.dispose();
        cancelUpdate.dispose();
        manager.dispose();
        runtime.close();
        runtime.dispose();
        await subscription.cancel();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );
}
