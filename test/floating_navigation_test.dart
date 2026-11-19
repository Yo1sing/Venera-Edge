import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/color.dart' as prism;
import 'package:prism_ui/navigation_dock.dart' as prism;
import 'package:prism_ui/theme_data.dart' as prism;
import 'package:venera_edge/components/app_theme.dart';
import 'package:venera_edge/components/components.dart';
import 'package:venera_edge/pages/main_navigation_glyphs.dart';
import 'package:venera_edge/src/rust/frb_generated.dart';

class _SettingsApi extends Fake implements RustLibApi {
  @override
  String crateApiSettingsDefaultSettingsJson() =>
      '{"dataVersion":0,"bottomNavigationStyle":"floating"}';
}

final _items = [
  for (final (label, glyph) in const [
    ('Home', MainNavigationGlyphs.dashboard),
    ('Favorites', MainNavigationGlyphs.proxies),
    ('Explore', MainNavigationGlyphs.profiles),
    ('Categories', MainNavigationGlyphs.tools),
  ])
    PaneItemEntry(label: label, glyph: glyph),
];

void main() {
  setUpAll(() => RustLib.initMock(api: _SettingsApi()));

  for (final brightness in Brightness.values) {
    testWidgets(
      'FlClash dock rendering and gestures in ${brightness.name} mode',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        final wide = brightness == Brightness.dark;
        tester.view.physicalSize = Size(wide ? 420 : 360, 800);
        tester.view.padding = FakeViewPadding(bottom: wide ? 34 : 0);
        addTearDown(tester.view.reset);

        const seed = Color(0xFF007AFF);
        final bar = find.byType(prism.FloatingNavigationBar);
        Finder label(int index) =>
            find.descendant(of: bar, matching: find.text(_items[index].label));
        Future<void> pump(Widget child) async {
          final theme = AppTheme.resolve(
            seed: seed,
            brightness: brightness,
            locales: const [Locale('en')],
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.material,
              builder: (context, child) => theme.wrap(child!),
              home: child,
            ),
          );
          await tester.pumpAndSettle();
        }

        await pump(
          Align(
            alignment: Alignment.bottomCenter,
            child: prism.Theme(
              data: prism.ThemeData(
                platform: TargetPlatform.android,
                colorScheme: prism.seededColorScheme(
                  seedColor: seed,
                  brightness: brightness,
                  style: prism.ColorStyle.vivid,
                ),
              ),
              child: prism.NavigationDock(
                destinations: [
                  for (final item in _items)
                    prism.NavigationDockDestination(
                      glyph: item.glyph,
                      label: item.label,
                    ),
                ],
                selectedIndex: 0,
                onSelected: (_) {},
              ),
            ),
          ),
        );
        final rect = tester.getRect(bar);
        final resting = await captureImage(tester.element(bar));
        addTearDown(resting.dispose);
        final press = await tester.startGesture(tester.getCenter(label(0)));
        await tester.pumpAndSettle();
        final held = await captureImage(tester.element(bar));
        addTearDown(held.dispose);
        Future<void> moveAcross(TestGesture gesture) async {
          await gesture.moveTo(tester.getCenter(label(2)));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 48));
        }

        await moveAcross(press);
        final moving = await captureImage(tester.element(bar));
        addTearDown(moving.dispose);
        await press.cancel();
        await tester.pumpAndSettle();

        final pane = GlobalKey<NaviPaneState>();
        final changes = <int>[];
        final taps = <int>[];
        await pump(
          NaviPane(
            key: pane,
            paneItems: _items,
            paneActions: const [],
            navigatorKey: GlobalKey(),
            observer: NaviObserver(),
            onPageChanged: changes.add,
            pageBuilder: (index) => Text('Page $index', key: ValueKey(index)),
          ),
        );
        pane.currentState!.addNaviItemTapListener(taps.add);
        expect(tester.getRect(bar), rect);
        expect(rect.bottom, 800 - (wide ? 34 : 21));
        expect(rect.center.dx, tester.view.physicalSize.width / 2);
        expect(
          NaviPane.floatingBottomInsetOf(tester.element(find.text('Page 0'))),
          800 - rect.top,
        );
        await expectLater(bar, matchesReferenceImage(resting));
        final drag = await tester.startGesture(tester.getCenter(label(0)));
        await tester.pumpAndSettle();
        await expectLater(bar, matchesReferenceImage(held));
        await moveAcross(drag);
        await expectLater(bar, matchesReferenceImage(moving));
        await tester.pumpAndSettle();
        expect(changes, isEmpty);
        await drag.up();
        await tester.pumpAndSettle();
        expect(changes, [2]);
        expect(find.text('Page 2'), findsOneWidget);

        await tester.tap(label(2));
        await tester.pumpAndSettle();
        expect(taps, [2, 2]);
        final cancelled = await tester.startGesture(tester.getCenter(label(2)));
        await cancelled.moveTo(tester.getCenter(label(0)));
        await cancelled.cancel();
        await tester.pumpAndSettle();
        expect(changes, [2]);

        await tester.tapAt(
          Offset(tester.getCenter(label(3)).dx, rect.bottom + 6),
        );
        await tester.pumpAndSettle();
        expect(changes, [2, 3]);
        expect(taps, [2, 2, 3]);

        final start = tester.getCenter(label(3));
        final pitch = start.dx - tester.getCenter(label(2)).dx;
        Future<void> pull(Duration duration) async {
          await tester.timedDragFrom(start, Offset(-pitch * 0.35, 0), duration);
          await tester.pumpAndSettle();
        }

        await pull(const Duration(seconds: 1));
        expect(changes, [2, 3]);
        await pull(const Duration(milliseconds: 50));
        expect(changes, [2, 3, 2]);

        final phoneSize = tester.view.physicalSize;
        tester.view.physicalSize = const Size(900, 800);
        await tester.pumpAndSettle();
        expect(bar, findsNothing);
        tester.view.physicalSize = phoneSize;
        await tester.pumpAndSettle();
        expect(
          tester.widget<prism.FloatingNavigationBar>(bar).selectedIndex,
          2,
        );
      },
    );
  }
}
