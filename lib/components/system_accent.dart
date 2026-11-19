import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

typedef _Seeds = ({Color light, Color dark});

/// Shares the current OS accent between the app theme and its settings preview.
class SystemAccent extends StatefulWidget {
  const SystemAccent({super.key, required this.child});

  final Widget child;

  static Color? of(BuildContext context, Brightness brightness) {
    final seeds = context.dependOnInheritedWidgetOfExactType<_Palette>()?.seeds;
    return brightness == Brightness.light ? seeds?.light : seeds?.dark;
  }

  @override
  State<SystemAccent> createState() => _SystemAccentState();
}

class _SystemAccentState extends State<SystemAccent>
    with WidgetsBindingObserver {
  static const _changes = MethodChannel('venera/system_colors');
  _Seeds? _seeds;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _changes.setMethodCallHandler((call) async {
      if (call.method == 'changed') await _refresh();
    });
    _refresh();
  }

  Future<void> _refresh() async {
    // A slower read from before a wallpaper change must not restore its color.
    final request = ++_request;
    _Seeds? next;
    try {
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final palette = await DynamicColorPlugin.getCorePalette();
          if (palette != null) {
            next = (
              light: Color(palette.primary.get(40)),
              dark: Color(palette.primary.get(80)),
            );
          }
        case TargetPlatform.windows ||
            TargetPlatform.macOS ||
            TargetPlatform.linux:
          final accent = (await DynamicColorPlugin.getAccentColor())?.withAlpha(
            255,
          );
          if (accent != null) next = (light: accent, dark: accent);
        default:
          return;
      }
    } on PlatformException {
      return;
    }
    if (mounted && request == _request && next != _seeds) {
      setState(() => _seeds = next);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    _changes.setMethodCallHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _Palette(seeds: _seeds, child: widget.child);
}

class _Palette extends InheritedWidget {
  const _Palette({required this.seeds, required super.child});

  final _Seeds? seeds;

  @override
  bool updateShouldNotify(_Palette oldWidget) => seeds != oldWidget.seeds;
}
