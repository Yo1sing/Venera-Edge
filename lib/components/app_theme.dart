import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:prism_ui/color.dart' as prism;
import 'package:prism_ui/font.dart' as prism;
import 'package:prism_ui/shape.dart' as prism;
import 'package:prism_ui/surface.dart' as prism;
import 'package:prism_ui/theme_cross_fade.dart' as prism;
import 'package:prism_ui/theme_data.dart' as prism;
import 'package:prism_ui/typography.dart' as prism;

/// One Prism palette drives both the reference widgets and Material pages.
class AppTheme {
  AppTheme._(this.prismTheme);

  final prism.ThemeData prismTheme;
  late final ThemeData material = _materialTheme();
  static const blue = Color(0xFF007AFF);
  static const accents = {
    'blue': blue,
    'purple': Color(0xFFCB30E0),
    'pink': Color(0xFFFF2D55),
    'red': Color(0xFFFF383C),
    'orange': Color(0xFFFF8D28),
    'yellow': Color(0xFFFFCC00),
    'green': Color(0xFF34C759),
    'gray': Color(0xFF8E8E93),
  };
  static final systemSeeds = _loadSystemSeeds();
  static final _cache = <Brightness, ({Object inputs, AppTheme theme})>{};

  static Future<({Color light, Color dark})> _loadSystemSeeds() async {
    final palette = await DynamicColorPlugin.getCorePalette()
        .onError<PlatformException>((_, _) => null);
    if (palette != null) {
      return (
        light: Color(palette.primary.get(40)),
        dark: Color(palette.primary.get(80)),
      );
    }
    final accent =
        await DynamicColorPlugin.getAccentColor().onError<PlatformException>(
          (_, _) => null,
        ) ??
        blue;
    return (light: accent, dark: accent);
  }

  static AppTheme resolve({
    required Color seed,
    required Brightness brightness,
    required Iterable<Locale> locales,
    prism.ColorStyle style = prism.ColorStyle.vivid,
    bool pureBlack = false,
  }) {
    final platform = defaultTargetPlatform;
    final inputs = (seed, style, pureBlack, platform, locales.join(','));
    final cached = _cache[brightness];
    if (cached != null && cached.inputs == inputs) return cached.theme;
    final colors = prism
        .seededColorScheme(
          seedColor: seed,
          brightness: brightness,
          style: style,
        )
        .toPureBlack(pureBlack);
    final theme = AppTheme._(
      prism.ThemeData(
        platform: platform,
        colorScheme: colors,
        elevatedColorScheme: brightness == Brightness.dark
            ? colors.elevated
            : null,
        fontFamilyFallback: prism.appFontFamilyFallback(
          platform: platform,
          locales: locales,
        ),
      ),
    );
    _cache[brightness] = (inputs: inputs, theme: theme);
    return theme;
  }

  Widget wrap(Widget child) => prism.Theme(
    data: prismTheme,
    child: prism.ThemeCrossFade(child: child),
  );

  ThemeData _materialTheme() {
    final c = prismTheme.colorScheme;
    final colors = ColorScheme(
      brightness: c.brightness,
      primary: c.primary,
      onPrimary: c.onPrimary,
      primaryContainer: c.primaryContainer,
      onPrimaryContainer: c.onPrimaryContainer,
      primaryFixed: c.primaryFixed,
      primaryFixedDim: c.primaryFixedDim,
      onPrimaryFixed: c.onPrimaryFixed,
      onPrimaryFixedVariant: c.onPrimaryFixedVariant,
      secondary: c.secondary,
      onSecondary: c.onSecondary,
      secondaryContainer: c.secondaryContainer,
      onSecondaryContainer: c.onSecondaryContainer,
      secondaryFixed: c.secondaryFixed,
      secondaryFixedDim: c.secondaryFixedDim,
      onSecondaryFixed: c.onSecondaryFixed,
      onSecondaryFixedVariant: c.onSecondaryFixedVariant,
      tertiary: c.tertiary,
      onTertiary: c.onTertiary,
      tertiaryContainer: c.tertiaryContainer,
      onTertiaryContainer: c.onTertiaryContainer,
      tertiaryFixed: c.tertiaryFixed,
      tertiaryFixedDim: c.tertiaryFixedDim,
      onTertiaryFixed: c.onTertiaryFixed,
      onTertiaryFixedVariant: c.onTertiaryFixedVariant,
      error: c.error,
      onError: c.onError,
      errorContainer: c.errorContainer,
      onErrorContainer: c.onErrorContainer,
      surface: c.surface,
      onSurface: c.onSurface,
      surfaceDim: c.surfaceDim,
      surfaceBright: c.surfaceBright,
      surfaceContainerLowest: c.surfaceContainerLowest,
      surfaceContainerLow: c.surfaceContainerLow,
      surfaceContainer: c.surfaceContainer,
      surfaceContainerHigh: c.surfaceContainerHigh,
      surfaceContainerHighest: c.surfaceContainerHighest,
      onSurfaceVariant: c.onSurfaceVariant,
      outline: c.outline,
      outlineVariant: c.outlineVariant,
      inverseSurface: c.inverseSurface,
      onInverseSurface: c.onInverseSurface,
      inversePrimary: c.inversePrimary,
      surfaceTint: c.surfaceTint,
      shadow: c.shadow,
      scrim: c.scrim,
    );
    final page = prism.SurfaceLevel.page.colorOf(c);
    final card = prism.SurfaceLevel.card.colorOf(c);
    final block = prism.SurfaceLevel.block.colorOf(c);
    final floating = prism.SurfaceLevel.floatingOf(c).colorOf(c);

    TextStyle type(prism.AppTextStyle role, {bool emphasized = false}) {
      final base = role.size >= prism.AppTextStyle.title3.size
          ? prismTheme.displayTextStyle
          : prismTheme.bodyTextStyle;
      return base.copyWith(
        fontSize: role.size,
        height: role.leading / role.size,
        fontWeight: emphasized ? role.emphasizedWeight : role.weight,
        letterSpacing: 0,
      );
    }

    final text = TextTheme(
      displayLarge: type(prism.AppTextStyle.display, emphasized: true),
      displayMedium: type(prism.AppTextStyle.largeTitle, emphasized: true),
      displaySmall: type(prism.AppTextStyle.title1, emphasized: true),
      headlineLarge: type(prism.AppTextStyle.largeTitle, emphasized: true),
      headlineMedium: type(prism.AppTextStyle.title1, emphasized: true),
      headlineSmall: type(prism.AppTextStyle.pageTitle),
      titleLarge: type(prism.AppTextStyle.title2, emphasized: true),
      titleMedium: type(prism.AppTextStyle.headline),
      titleSmall: type(prism.AppTextStyle.subheadline, emphasized: true),
      bodyLarge: type(prism.AppTextStyle.body),
      bodyMedium: type(prism.AppTextStyle.callout),
      bodySmall: type(prism.AppTextStyle.footnote),
      labelLarge: type(prism.AppTextStyle.subheadline, emphasized: true),
      labelMedium: type(prism.AppTextStyle.caption1),
      labelSmall: type(prism.AppTextStyle.caption2),
    );
    const field = OutlineInputBorder(
      borderRadius: prism.AppRadius.md,
      borderSide: BorderSide.none,
    );
    return ThemeData(
      colorScheme: colors,
      platform: prismTheme.platform,
      fontFamily: prismTheme.bodyTextStyle.fontFamily,
      fontFamilyFallback: prismTheme.fontFamilyFallback,
      textTheme: text,
      canvasColor: page,
      scaffoldBackgroundColor: page,
      cardColor: card,
      dividerColor: c.outlineVariant,
      dividerTheme: DividerThemeData(color: c.outlineVariant, thickness: 0.5),
      appBarTheme: AppBarThemeData(
        backgroundColor: page,
        foregroundColor: c.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: text.headlineSmall,
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        shape: prism.AppShape.md,
        clipBehavior: Clip.antiAlias,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: c.onSurfaceVariant,
        textColor: c.onSurface,
        titleTextStyle: text.bodyLarge,
        subtitleTextStyle: text.bodySmall!.copyWith(color: c.onSurfaceVariant),
        selectedColor: c.primary,
        selectedTileColor: c.onSurface.withValues(alpha: 0.08),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: block,
        border: field,
        enabledBorder: field,
        focusedBorder: field.copyWith(
          borderSide: BorderSide(color: c.primary, width: 2),
        ),
        errorBorder: field.copyWith(borderSide: BorderSide(color: c.error)),
        focusedErrorBorder: field.copyWith(
          borderSide: BorderSide(color: c.error, width: 2),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: floating,
        shape: prism.AppShape.md,
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: floating,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: prism.AppShape.all(prism.AppCorner.alert),
        titleTextStyle: text.titleMedium,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: floating,
        modalBackgroundColor: floating,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedSuperellipseBorder(
          borderRadius: prism.AppRadius.top(prism.AppCorner.xl),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: block,
        selectedColor: c.primaryContainer,
        shape: prism.AppShape.full,
        side: BorderSide.none,
        labelStyle: text.labelMedium,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(shape: prism.AppShape.full),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(shape: prism.AppShape.full),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: prism.AppShape.full),
      ),
      switchTheme: SwitchThemeData(
        trackOutlineWidth: const WidgetStatePropertyAll(0),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: floating,
        foregroundColor: c.primary,
        shape: prism.AppShape.full,
      ),
    );
  }
}
