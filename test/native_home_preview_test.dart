import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:venera_edge/components/components.dart';
import 'package:venera_edge/foundation/app.dart';
import 'package:venera_edge/foundation/appdata.dart';
import 'package:venera_edge/foundation/comic_source/comic_source.dart';
import 'package:venera_edge/foundation/comic_type.dart';
import 'package:venera_edge/foundation/favorites.dart';
import 'package:venera_edge/foundation/home_layout.dart';
import 'package:venera_edge/foundation/js_engine.dart';
import 'package:venera_edge/foundation/local.dart';
import 'package:venera_edge/pages/home_page.dart';
import 'package:venera_edge/src/rust/api/local.dart';
import 'package:venera_edge/src/rust/frb_generated.dart';
import 'package:venera_edge/utils/translations.dart';

void main() {
  final library = Platform.environment['VENERA_BACKEND_LIBRARY'];
  if (library == null) {
    test('home folder preview', () {}, skip: 'Set VENERA_BACKEND_LIBRARY');
    return;
  }

  TestWidgetsFlutterBinding.ensureInitialized();
  const folder = 'Pinned comics';
  final favorites = LocalFavoritesManager();
  final local = LocalManager();
  late Directory directory;
  final layout = HomeLayout.fromJson(null)..addFolder(folder);
  layout.hidden.addAll(HomeLayout.titles.keys);

  setUpAll(() async {
    await RustLib.init(externalLibrary: ExternalLibrary.open(library));
    directory = await Directory.systemTemp.createTemp('venera-home-preview-');
    App.dataPath = App.cachePath = directory.path;
    await appdata.init();
    appdata.settings['language'] = 'en-US';
    appdata.settings['proxy'] = 'direct';
    appdata.settings['homeLayout'] = layout.toJson();
    await appdata.saveData(false);
    await AppTranslation.init();
    await JsEngine().init();
    await ComicSourceManager().init();
    await local.init();
    await favorites.init();
    favorites.createFolder(folder);

    File('${directory.path}/cover.png').writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
      ),
    );
    final store = await LocalStore.open(path: '${directory.path}/local.db');
    for (var i = 0; i < 8; i++) {
      store.save(
        comicJson: jsonEncode({
          'id': 'book-$i',
          'title': 'Book $i',
          'subtitle': '',
          'tags': <String>[],
          'directory': directory.path,
          'chapters': null,
          'cover': 'cover.png',
          'comic_type': ComicType.local.value,
          'downloaded_chapters': <String>[],
          'created_at': i,
        }),
      );
      favorites.addComic(
        folder,
        FavoriteItem(
          id: 'book-$i',
          name: 'Book $i',
          coverPath: 'cover.png',
          author: '',
          type: ComicType.local,
          tags: [],
        ),
      );
    }
    store.close();
    store.dispose();
  });
  tearDownAll(() async {
    favorites.close();
    local.dispose();
    JsEngine().dispose();
    RustLib.dispose();
    await directory.delete(recursive: true);
  });

  testWidgets('pinned covers scroll, resize and refresh after removal', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);

    Future<void> pumpUntil(bool Function() ready) async {
      for (var attempt = 0; attempt < 100; attempt++) {
        await tester.pump(const Duration(milliseconds: 20));
        if (ready()) return;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(ready(), isTrue, reason: 'Timed out waiting for the preview');
    }

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: const Scaffold(body: HomePage()),
      ),
    );
    final tiles = find.byType(SimpleComicTile);
    final row = find.byType(ListView);
    final image = find.byWidgetPredicate(
      (widget) => widget is RawImage && widget.image != null,
    );
    await pumpUntil(() => image.evaluate().isNotEmpty);
    expect(tester.widget<ListView>(row).scrollDirection, Axis.horizontal);
    expect(tester.widget<SimpleComicTile>(tiles.first).comic.id, 'book-0');
    final regular = tester.getSize(tiles.first);

    layout.compact = true;
    appdata.settings['homeLayout'] = layout.toJson();
    await tester.pump();
    final compact = tester.getSize(tiles.first);
    expect(compact.width, lessThan(regular.width));
    expect(compact.height, lessThan(regular.height));

    final scrollable = find.descendant(
      of: row,
      matching: find.byType(Scrollable),
    );
    final offset = tester.state<ScrollableState>(scrollable).position;
    await tester.drag(row, const Offset(-640, 0));
    await tester.pumpAndSettle();
    expect(offset.pixels, greaterThan(0));
    Finder cover(String id) => find.byWidgetPredicate(
      (widget) => widget is SimpleComicTile && widget.comic.id == id,
    );
    expect(cover('book-7').hitTestable(), findsOneWidget);

    favorites.deleteComicWithId(folder, 'book-7', ComicType.local);
    await pumpUntil(() => cover('book-7').evaluate().isEmpty);
    expect(cover('book-6').hitTestable(), findsOneWidget);
  });
}
