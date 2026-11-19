import 'dart:async';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:prism_ui/color.dart' as prism;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/auth_page.dart';
import 'package:venera/pages/main_page.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:window_manager/window_manager.dart';
import 'components/app_theme.dart';
import 'components/components.dart';
import 'components/window_frame.dart';
import 'foundation/app.dart';
import 'foundation/appdata.dart';
import 'headless.dart';
import 'init.dart';

void main(List<String> args) {
  if (args.contains('--headless')) {
    runHeadlessMode(args);
    return;
  }
  if (runWebViewTitleBarWidget(args)) return;
  overrideIO(() {
    runZonedGuarded(
      () async {
        WidgetsFlutterBinding.ensureInitialized();
        await init();
        runApp(const MyApp());
        DataSync().start();
        if (App.isDesktop) {
          await windowManager.ensureInitialized();
          await windowManager.setPreventClose(true);
          windowManager.waitUntilReadyToShow().then((_) async {
            await windowManager.setTitleBarStyle(
              TitleBarStyle.hidden,
              windowButtonVisibility: App.isMacOS,
            );
            if (App.isLinux) {
              await windowManager.setBackgroundColor(Colors.transparent);
            }
            await windowManager.setMinimumSize(const Size(500, 600));
            var placement = await WindowPlacement.loadFromFile();
            if (App.isLinux) {
              await windowManager.show();
              await placement.applyToWindow();
            } else {
              await placement.applyToWindow();
              await windowManager.show();
            }

            WindowPlacement.loop();
          });
        }
      },
      (error, stack) {
        Log.error("Unhandled Exception", error, stack);
      },
    );
  });
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  (String, String, String, bool) get _themeSettings => (
    appdata.settings['color'],
    appdata.settings['colorStyle'],
    appdata.settings['theme_mode'],
    appdata.settings['pureBlack'],
  );
  late (String, String, String, bool) _lastThemeSettings;

  void _updateTheme() {
    final current = _themeSettings;
    if (current != _lastThemeSettings) {
      setState(() => _lastThemeSettings = current);
    }
  }

  @override
  void initState() {
    _lastThemeSettings = _themeSettings;
    appdata.settings.addListener(_updateTheme);
    App.registerForceRebuild(forceRebuild);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WidgetsBinding.instance.addObserver(this);
    checkUpdates();
    super.initState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    appdata.settings.removeListener(_updateTheme);
    super.dispose();
  }

  bool isAuthPageActive = false;

  OverlayEntry? hideContentOverlay;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!App.isMobile || !appdata.settings['authorizationRequired']) {
      return;
    }
    if (state == AppLifecycleState.inactive && hideContentOverlay == null) {
      hideContentOverlay = OverlayEntry(
        builder: (context) {
          return Positioned.fill(
            child: Container(
              width: double.infinity,
              height: double.infinity,
              color: Theme.of(context).scaffoldBackgroundColor,
            ),
          );
        },
      );
      Overlay.of(App.rootContext).insert(hideContentOverlay!);
    } else if (hideContentOverlay != null &&
        state == AppLifecycleState.resumed) {
      hideContentOverlay!.remove();
      hideContentOverlay = null;
    }
    if (state == AppLifecycleState.hidden &&
        !isAuthPageActive &&
        !IO.isSelectingFiles) {
      isAuthPageActive = true;
      App.rootContext.to(
        () => AuthPage(
          onSuccessfulAuth: () {
            App.rootContext.pop();
            isAuthPageActive = false;
          },
        ),
      );
    }
    super.didChangeAppLifecycleState(state);
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    setState(() {});
  }

  void forceRebuild() {
    void rebuild(Element el) {
      el.markNeedsBuild();
      el.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    Widget home;
    if (appdata.settings['authorizationRequired']) {
      home = AuthPage(
        onSuccessfulAuth: () {
          App.rootContext.toReplacement(() => const MainPage());
        },
      );
    } else {
      home = const MainPage();
    }
    final locale = switch (appdata.settings['language']) {
      'zh-CN' => const Locale('zh', 'CN'),
      'zh-TW' => const Locale('zh', 'TW'),
      'en-US' => const Locale('en'),
      _ => null,
    };
    final (color, style, mode, pureBlack) = _lastThemeSettings;
    return FutureBuilder(
      future: color == 'system' ? AppTheme.systemSeeds : null,
      builder: (context, snapshot) {
        AppTheme theme(Brightness brightness) {
          final system = snapshot.data;
          final seed = color == 'system'
              ? (brightness == Brightness.light ? system?.light : system?.dark)
              : AppTheme.accents[color];
          return AppTheme.resolve(
            seed: seed ?? AppTheme.blue,
            brightness: brightness,
            locales: [
              if (locale != null) locale,
              ...WidgetsBinding.instance.platformDispatcher.locales,
            ],
            style: prism.ColorStyle.values.byName(style),
            pureBlack: pureBlack,
          );
        }

        final light = theme(Brightness.light);
        final dark = theme(Brightness.dark);
        return MaterialApp(
          title: "Venera Edge",
          home: home,
          debugShowCheckedModeBanner: false,
          theme: light.material,
          themeAnimationDuration: Duration.zero,
          navigatorKey: App.rootNavigatorKey,
          darkTheme: dark.material,
          themeMode: switch (mode) {
            'light' => ThemeMode.light,
            'dark' => ThemeMode.dark,
            _ => ThemeMode.system,
          },
          color: Colors.transparent,
          localizationsDelegates: [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          locale: locale,
          supportedLocales: const [
            Locale('zh', 'CN'),
            Locale('zh', 'TW'),
            Locale('en'),
          ],
          builder: (context, widget) {
            ErrorWidget.builder = (details) {
              Log.error(
                "Unhandled Exception",
                "${details.exception}\n${details.stack}",
              );
              return Material(
                child: Center(child: Text(details.exception.toString())),
              );
            };
            if (widget != null) {
              /// 如果无法检测到状态栏高度设定指定高度
              /// https://github.com/flutter/flutter/issues/161086
              var isPaddingCheckError =
                  MediaQuery.of(context).viewPadding.top <= 0 ||
                  MediaQuery.of(context).viewPadding.top > 200;

              if (isPaddingCheckError && Platform.isAndroid) {
                widget = MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    viewPadding: const EdgeInsets.only(top: 15, bottom: 15),
                    padding: const EdgeInsets.only(top: 15, bottom: 15),
                  ),
                  child: widget,
                );
              }

              widget = OverlayWidget(widget);
              if (App.isDesktop) {
                widget = Shortcuts(
                  shortcuts: {
                    LogicalKeySet(LogicalKeyboardKey.escape):
                        VoidCallbackIntent(App.pop),
                  },
                  child: MouseBackDetector(
                    onTapDown: App.pop,
                    child: WindowFrame(widget),
                  ),
                );
              }
              final active = Theme.brightnessOf(context) == Brightness.dark
                  ? dark
                  : light;
              return active.wrap(
                _SystemUiProvider(
                  Material(
                    color: App.isLinux ? Colors.transparent : null,
                    child: widget,
                  ),
                ),
              );
            }
            throw ('widget is null');
          },
        );
      },
    );
  }
}

class _SystemUiProvider extends StatelessWidget {
  const _SystemUiProvider(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) {
    var brightness = Theme.of(context).brightness;
    SystemUiOverlayStyle systemUiStyle;
    if (brightness == Brightness.light) {
      systemUiStyle = SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
      );
    } else {
      systemUiStyle = SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      );
    }
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemUiStyle,
      child: child,
    );
  }
}
