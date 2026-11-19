import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/color.dart' as prism;
import 'package:prism_ui/shape.dart' as prism;
import 'package:prism_ui/surface.dart' as prism;
import 'package:prism_ui/switch.dart' as prism;
import 'package:prism_ui/theme_data.dart' as prism;
import 'package:prism_ui/typography.dart' as prism;
import 'package:venera/components/app_theme.dart';
import 'package:venera/components/components.dart'
    show AnimatedTapRegion, Button, ContentDialog;
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/src/rust/frb_generated.dart';
import 'package:venera/utils/translations.dart';

class _SettingsApi extends Fake implements RustLibApi {
  @override
  String crateApiSettingsDefaultSettingsJson() =>
      '{"dataVersion":0,"language":"en-US","color":"blue","colorStyle":"vivid",'
      '"theme_mode":"system","pureBlack":false,"bottomNavigationStyle":"floating"}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    RustLib.initMock(api: _SettingsApi());
    await AppTranslation.init();
  });
  const locales = [Locale('en')];

  testWidgets('page and comic card paint the default FlClash colors', (
    tester,
  ) async {
    const frame = ValueKey('page');
    for (final (brightness, pageRgb, cardRgb) in const [
      (Brightness.light, 0xEFEDF0, 0xFCF8F9),
      (Brightness.dark, 0x131315, 0x252628),
    ]) {
      final theme = AppTheme.resolve(
        seed: AppTheme.blue,
        brightness: brightness,
        locales: locales,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.material,
          themeAnimationDuration: Duration.zero,
          builder: (context, child) => theme.wrap(child!),
          home: RepaintBoundary(
            key: frame,
            child: Scaffold(
              body: Center(
                child: AnimatedTapRegion(
                  onTap: () {},
                  child: const SizedBox.square(dimension: 64),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final image = await captureImage(tester.element(find.byKey(frame)));
        try {
          final pixels = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          int rgbAt(int x, int y) =>
              pixels.getUint32((y * image.width + x) * 4) >> 8;
          expect(rgbAt(4, 4), pageRgb);
          expect(rgbAt(image.width ~/ 2, image.height ~/ 2), cardRgb);
        } finally {
          image.dispose();
        }
      });
    }
  });

  for (final style in prism.ColorStyle.values) {
    test('Material surfaces and text match Prism in ${style.name}', () {
      for (final brightness in Brightness.values) {
        for (final pureBlack in [false, true]) {
          final theme = AppTheme.resolve(
            seed: AppTheme.blue,
            brightness: brightness,
            locales: locales,
            style: style,
            pureBlack: pureBlack,
          ).material;
          final reference = prism
              .seededColorScheme(
                seedColor: AppTheme.blue,
                brightness: brightness,
                style: style,
              )
              .toPureBlack(pureBlack);
          expect(theme.brightness, brightness);
          expect(theme.colorScheme.primary, reference.primary);
          expect(theme.colorScheme.onSurface, reference.onSurface);
          expect(
            theme.scaffoldBackgroundColor,
            prism.SurfaceLevel.page.colorOf(reference),
          );
          expect(theme.cardColor, prism.SurfaceLevel.card.colorOf(reference));
          expect(theme.cardTheme.shape, prism.AppShape.md);
          expect(
            theme.inputDecorationTheme.fillColor,
            prism.SurfaceLevel.block.colorOf(reference),
          );
          expect(
            theme.dialogTheme.backgroundColor,
            prism.SurfaceLevel.floatingOf(reference).colorOf(reference),
          );
          expect(
            theme.textTheme.headlineSmall!.fontSize,
            prism.AppTextStyle.pageTitle.size,
          );
          expect(
            theme.textTheme.headlineSmall!.fontWeight,
            prism.AppTextStyle.pageTitle.weight,
          );
        }
      }
    });
  }

  testWidgets('a themed dialog can size and activate its Prism action', (
    tester,
  ) async {
    final theme = AppTheme.resolve(
      seed: AppTheme.blue,
      brightness: Brightness.dark,
      locales: locales,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.material,
        builder: (context, child) => theme.wrap(child!),
        home: Builder(
          builder: (context) => TextButton(
            child: const Text('Open'),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => ContentDialog(
                title: 'Theme',
                content: const Text('Preview'),
                actions: [
                  Button.filled(
                    child: const Text('Done'),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Preview'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byType(ContentDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('appearance settings and an open menu follow a theme change', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);

    Future<void> pump(AppTheme theme) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.material,
          themeAnimationDuration: Duration.zero,
          builder: (context, child) => theme.wrap(child!),
          home: const Scaffold(body: AppearanceSettings()),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pump(
      AppTheme.resolve(
        seed: AppTheme.blue,
        brightness: Brightness.light,
        locales: locales,
      ),
    );
    expect(find.byTooltip('Blue'), findsOneWidget);
    expect(find.byTooltip('Gray'), findsOneWidget);
    expect(find.byType(prism.Switch), findsOneWidget);
    await tester.tap(find.text('Color Style'));
    await tester.pumpAndSettle();
    final option = find.text('Monochrome');
    expect(option, findsOneWidget);

    final dark = AppTheme.resolve(
      seed: AppTheme.accents['green']!,
      brightness: Brightness.dark,
      locales: locales,
      pureBlack: true,
    );
    await pump(dark);
    final menuContext = tester.element(option);
    expect(
      prism.Theme.of(menuContext).colorScheme.primary,
      dark.prismTheme.colorScheme.primary,
    );
    expect(
      Theme.of(menuContext).popupMenuTheme.color,
      dark.material.popupMenuTheme.color,
    );
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).scaffoldBackgroundColor,
      Colors.black,
    );
    expect(tester.takeException(), isNull);
  });
}
