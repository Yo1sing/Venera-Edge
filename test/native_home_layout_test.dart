import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:venera_edge/components/app_theme.dart';
import 'package:venera_edge/foundation/app.dart';
import 'package:venera_edge/foundation/appdata.dart';
import 'package:venera_edge/foundation/favorites.dart';
import 'package:venera_edge/foundation/home_layout.dart';
import 'package:venera_edge/pages/favorites/favorites_page.dart';
import 'package:venera_edge/pages/home_page.dart';
import 'package:venera_edge/pages/main_page.dart';
import 'package:venera_edge/pages/settings/home_layout_page.dart';
import 'package:venera_edge/pages/settings/settings_page.dart';
import 'package:venera_edge/src/rust/frb_generated.dart';
import 'package:venera_edge/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['VENERA_BACKEND_LIBRARY'];
  if (library == null) {
    test(
      'home favorite shortcuts',
      () {},
      skip: 'Set VENERA_BACKEND_LIBRARY to run native tests',
    );
    return;
  }

  const folder = 'Pinned shelf';
  const previous = {'name': 'Original shelf', 'isNetwork': false};
  final favorites = LocalFavoritesManager();
  late Directory directory;

  setUpAll(() async {
    await RustLib.init(externalLibrary: ExternalLibrary.open(library));
    directory = await Directory.systemTemp.createTemp('venera-home-shortcuts');
    App.dataPath = App.cachePath = directory.path;
    await appdata.init();
    appdata.settings['language'] = 'en-US';
    appdata.settings['proxy'] = 'direct';
    await appdata.saveData(false);
    await AppTranslation.init();
    await favorites.init();
    favorites.createFolder(previous['name'] as String);
    appdata.setImplicitData('favoriteFolder', previous);
    await appdata.saveImplicitData();
  });
  tearDownAll(() async {
    await appdata.flushSaves();
    favorites.close();
    RustLib.dispose();
    await directory.delete(recursive: true);
  });
  setUp(() async {
    if (!favorites.existsFolder(folder)) favorites.createFolder(folder);
    final layout = HomeLayout.fromJson(null)..addFolder(folder);
    layout.hidden.addAll(HomeLayout.titles.keys);
    appdata.settings['homeLayout'] = layout.toJson();
    await appdata.saveData(false);
  });

  testWidgets('open the editor from Home and Appearance', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 850);
    addTearDown(tester.view.reset);
    final theme = AppTheme.resolve(
      seed: Colors.blue,
      brightness: Brightness.light,
      locales: const [Locale('en')],
    );
    for (final page in [const MainPage(), const AppearanceSettings()]) {
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey(page.runtimeType),
          navigatorKey: App.rootNavigatorKey,
          theme: theme.material,
          builder: (context, child) => theme.wrap(child!),
          home: Scaffold(body: page),
        ),
      );
      await tester.pumpAndSettle();
      final entry = page is MainPage
          ? find.byTooltip('Customize home')
          : find.text('Customize home');
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.byType(HomeLayoutPage), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(HomeLayoutPage), findsNothing);
      await tester.pumpWidget(const SizedBox());
    }
  });

  for (final width in [360.0, 1000.0]) {
    testWidgets('home folder shortcut at width $width', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 850);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: const Scaffold(body: HomePage()),
        ),
      );
      await tester.pumpAndSettle();

      final header = find.widgetWithText(ListTile, folder);
      expect(find.text('No comics'), findsOneWidget);
      final regularHeight = tester.getSize(header).height;
      final layout = HomeLayout.fromJson(appdata.settings['homeLayout'])
        ..compact = true;
      appdata.settings['homeLayout'] = layout.toJson();
      await tester.pumpAndSettle();
      expect(tester.getSize(header).height, lessThan(regularHeight));

      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(find.byType(FavoritesPage), findsOneWidget);
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(FavoritesPage), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(header, findsOneWidget);

      await tester.tap(header);
      await tester.pumpAndSettle();
      favorites.deleteFolder(folder);
      await tester.pumpAndSettle();
      expect(find.text('Favorite folder unavailable'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(FavoritesPage), findsNothing);
      expect(tester.widget<ListTile>(header).onTap, isNull);
      expect(appdata.implicitData['favoriteFolder'], previous);
    });
  }
}
