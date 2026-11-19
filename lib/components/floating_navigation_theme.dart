import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart' show Theme;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/color.dart' as prism;
import 'package:prism_ui/font.dart' as prism;
import 'package:prism_ui/theme_data.dart' as prism;

class FloatingNavigationTheme extends StatelessWidget {
  const FloatingNavigationTheme({
    super.key,
    required this.colorSetting,
    required this.child,
  });

  final String colorSetting;
  final Widget child;

  // FlClash's vivid palette and default accent when the OS supplies no color.
  static const _blue = Color(0xFF007AFF);
  static const _accents = {
    'blue': _blue,
    'purple': Color(0xFFCB30E0),
    'pink': Color(0xFFFF2D55),
    'red': Color(0xFFFF383C),
    'orange': Color(0xFFFF8D28),
    'yellow': Color(0xFFFFCC00),
    'green': Color(0xFF34C759),
    'cyan': Color(0xFF00BCD4),
  };
  static final _systemSeeds = _loadSystemSeeds();
  static final _schemes = <(Color, Brightness), prism.ColorScheme>{};

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
        _blue;
    return (light: accent, dark: accent);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget themed(Color seed) => prism.Theme(
      data: prism.ThemeData(
        platform: theme.platform,
        colorScheme: _schemes.putIfAbsent(
          (seed, theme.brightness),
          () => prism.seededColorScheme(
            seedColor: seed,
            brightness: theme.brightness,
            style: prism.ColorStyle.vivid,
          ),
        ),
        fontFamilyFallback: prism.appFontFamilyFallback(
          platform: theme.platform,
          locales: [
            Localizations.localeOf(context),
            ...WidgetsBinding.instance.platformDispatcher.locales,
          ],
        ),
      ),
      child: child,
    );

    if (colorSetting != 'system') {
      return themed(_accents[colorSetting] ?? _blue);
    }
    return FutureBuilder(
      future: _systemSeeds,
      builder: (_, snapshot) {
        final seeds = snapshot.data;
        return themed(
          (theme.brightness == Brightness.light ? seeds?.light : seeds?.dark) ??
              _blue,
        );
      },
    );
  }
}
