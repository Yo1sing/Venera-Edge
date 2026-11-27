import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:venera_edge/foundation/app.dart';
import 'package:venera_edge/foundation/appdata.dart';
import 'package:venera_edge/foundation/favorites.dart';
import 'package:venera_edge/foundation/home_layout.dart';
import 'package:venera_edge/pages/settings/home_layout_page.dart';
import 'package:venera_edge/src/rust/api/settings.dart' as backend;
import 'package:venera_edge/src/rust/frb_generated.dart';
import 'package:venera_edge/utils/translations.dart';

void main() {
  final library = Platform.environment['VENERA_BACKEND_LIBRARY'];
  if (library == null) {
    test('native home editor', () {}, skip: 'Set VENERA_BACKEND_LIBRARY');
    return;
  }

  // Dropping a card writes through Rust when the reorder animation completes.
  // Keep both the animation and native completions on the real event loop.
  LiveTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  late Directory directory;
  const folder = 'Home shortcut';
  final favorites = LocalFavoritesManager();

  setUpAll(() async {
    await RustLib.init(externalLibrary: ExternalLibrary.open(library));
    directory = await Directory.systemTemp.createTemp('venera-home-editor-');
    App.dataPath = directory.path;
    App.cachePath = directory.path;
    await appdata.init();
    appdata.settings['language'] = 'en-US';
    appdata.settings['proxy'] = 'direct';
    await appdata.saveData(false);
    await AppTranslation.init();
    await favorites.init();
    favorites.createFolder(folder);
  });
  tearDownAll(() async {
    favorites.close();
    RustLib.dispose();
    await directory.delete(recursive: true);
  });

  testWidgets('editing, reopening and resetting home persists through Rust', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 900);
    addTearDown(tester.view.reset);

    const editor = MaterialApp(home: HomeLayoutPage());
    await tester.pumpWidget(editor);

    Future<void> tapAndSave(Finder target) async {
      await tester.tap(target);
      await tester.pumpAndSettle();
      await appdata.flushSaves();
    }

    Future<HomeLayout> readFromDisk() async {
      await appdata.flushSaves();
      final data = jsonDecode(
        await backend.loadAppData(directory: directory.path),
      );
      return HomeLayout.fromJson(data['settings']['homeLayout']);
    }

    await tapAndSave(find.byKey(const ValueKey('toggle-search')));
    await tapAndSave(find.text('Compact home'));
    final handle = find.descendant(
      of: find.byKey(const ValueKey('search')),
      matching: find.byType(ReorderableDragStartListener),
    );
    final start = tester.getCenter(handle);
    final target = tester.getCenter(find.byKey(const ValueKey('local')));
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(0, 18));
    await tester.pump();
    await gesture.moveTo(Offset(start.dx, target.dy));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
    await tapAndSave(find.byTooltip('Add favorite folder'));
    await tapAndSave(find.text(folder));

    final saved = await readFromDisk();
    expect(saved.hidden, {'search'});
    expect(saved.compact, isTrue);
    expect(saved.order.take(3), ['sync', 'history', 'search']);
    expect(saved.order.last, 'folder:$folder');
    expect(saved.folders, {'folder:$folder': folder});
    final synced = jsonDecode(
      File('${directory.path}/syncdata.json').readAsStringSync(),
    );
    expect(
      HomeLayout.fromJson(synced['settings']['homeLayout']).toJson(),
      saved.toJson(),
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(editor);
    expect(
      tester.widget<Switch>(find.byKey(const ValueKey('toggle-search'))).value,
      isFalse,
    );
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    await tapAndSave(
      find.descendant(
        of: find.byKey(const ValueKey('folder:$folder')),
        matching: find.byTooltip('Delete'),
      ),
    );
    expect((await readFromDisk()).folders, isEmpty);
    expect(favorites.existsFolder(folder), isTrue);

    await tapAndSave(find.byTooltip('Restore defaults'));
    expect((await readFromDisk()).toJson(), HomeLayout.fromJson(null).toJson());
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
