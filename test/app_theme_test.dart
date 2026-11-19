import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/color.dart' as prism;
import 'package:prism_ui/popup.dart' as prism;
import 'package:prism_ui/shape.dart' as prism;
import 'package:prism_ui/surface.dart' as prism;
import 'package:prism_ui/switch.dart' as prism;
import 'package:prism_ui/theme_data.dart' as prism;
import 'package:prism_ui/typography.dart' as prism;
import 'package:venera_edge/components/app_theme.dart';
import 'package:venera_edge/components/settings_choice_row.dart';
import 'package:venera_edge/components/system_accent.dart';
import 'package:venera_edge/components/components.dart'
    show AnimatedTapRegion, Button, ContentDialog;
import 'package:venera_edge/pages/settings/settings_page.dart';
import 'package:venera_edge/src/rust/frb_generated.dart';
import 'package:venera_edge/utils/translations.dart';
import 'package:venera_edge/utils/prism_localizations.dart';

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

  testWidgets('system accent preview follows desktop changes and resume', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    const changes = MethodChannel('venera/system_colors');
    Future<Object?> notify() => messenger.handlePlatformMessage(
      changes.name,
      changes.codec.encodeMethodCall(const MethodCall('changed')),
      null,
    );
    final firstRead = Completer<int?>();
    Future<int?> reply = firstRead.future;
    messenger.setMockMethodCallHandler(DynamicColorPlugin.channel, (call) {
      expect(call.method, 'getAccentColor');
      return reply;
    });
    await tester.pumpWidget(
      const SystemAccent(
        child: MaterialApp(home: Scaffold(body: AppearanceSettings())),
      ),
    );
    final row = find.widgetWithText(ListTile, 'System accent color');
    final swatch = find.descendant(
      of: row,
      matching: find.byType(CircleAvatar),
    );
    Color? preview() => tester.widget<CircleAvatar>(swatch).backgroundColor;
    expect(preview(), AppTheme.blue);

    reply = Future.value(0xffae40c8);
    await notify();
    await tester.pump();
    expect(preview(), const Color(0xffae40c8));
    firstRead.complete(0xff123456);
    await tester.pump();
    expect(preview(), const Color(0xffae40c8));

    reply = Future.value(0xff047abc);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(preview(), const Color(0xff047abc));
    expect(
      AppTheme.seedOf(tester.element(row), 'blue', Brightness.light),
      AppTheme.blue,
    );

    reply = Future.value(null);
    await notify();
    await tester.pump();
    expect(preview(), AppTheme.blue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Android wallpaper provides separate light and dark seeds', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    // Android returns 13 tones for each of five palettes. Primary tones 40
    // and 80 occupy indices 4 and 8 respectively.
    final palette = Int32List.fromList(List.filled(65, 0xff888888))
      ..[4] = 0xff326337
      ..[8] = 0xff8bd695;
    messenger.setMockMethodCallHandler(DynamicColorPlugin.channel, (
      call,
    ) async {
      expect(call.method, 'getCorePalette');
      return palette;
    });
    await tester.pumpWidget(
      SystemAccent(
        child: Builder(
          builder: (context) {
            return ColoredBox(
              color: AppTheme.seedOf(context, 'system', Brightness.light),
              child: ColoredBox(
                color: AppTheme.seedOf(context, 'system', Brightness.dark),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<ColoredBox>(find.byType(ColoredBox))
          .map((box) => box.color),
      [const Color(0xff326337), const Color(0xff8bd695)],
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

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
          localizationsDelegates: const [PrismLocalizations.delegate],
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
    for (final color in ['Blue', 'Gray']) {
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Tooltip && widget.message == color,
        ),
        findsOneWidget,
      );
    }
    expect(find.byType(prism.Switch), findsOneWidget);
    await tester.tap(find.text('Color Style'));
    await tester.pumpAndSettle();
    final items = tester
        .widget<prism.PopupMenu>(find.byType(prism.PopupMenu))
        .items;
    expect(items.where((item) => item.checked == true).single.label, 'Vivid');
    expect(items.map((item) => item.label), [
      'Vivid',
      'Tinted',
      'Soft',
      'Monochrome',
    ]);
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

  testWidgets('settings choices keep their keys and dismiss at both widths', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final width in [320.0, 800.0]) {
      tester.view.physicalSize = Size(width, 680);
      String? selected;
      final changes = <String>[];
      var resets = 0;
      const options = {'a': 'Same name', 'b': 'Same name', 'c': 'Other'};
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [PrismLocalizations.delegate],
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, rebuild) => SettingsChoiceRow<String>(
                title: const Text('Choice'),
                options: options,
                value: selected,
                fallbackLabel: 'None',
                trailingAction: IconButton(
                  icon: const Icon(Icons.restart_alt),
                  onPressed: () => resets++,
                ),
                onChanged: (key) => rebuild(() {
                  selected = key;
                  changes.add(key);
                }),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final menu = find.byType(prism.PopupMenu);
      await tester.tap(find.byIcon(Icons.restart_alt));
      await tester.pumpAndSettle();
      expect(resets, 1);
      expect(menu, findsNothing);
      expect(find.text('None'), findsOneWidget);
      await tester.tap(find.text('Choice'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<prism.PopupMenu>(menu)
            .items
            .every((e) => e.checked == false),
        isTrue,
      );
      await tester.tap(
        find.descendant(of: menu, matching: find.text('Same name')).last,
      );
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
      expect(changes, ['b']);
      await tester.tap(find.text('Same name'));
      await tester.pumpAndSettle();
      expect(tester.widget<prism.PopupMenu>(menu).items.map((e) => e.checked), [
        false,
        true,
        false,
      ]);
      await tester.tapAt(Offset(20, 630));
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
      expect(changes, ['b']);
    }
  });
}
