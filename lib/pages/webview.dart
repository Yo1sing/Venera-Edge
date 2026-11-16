import 'dart:async';
import 'dart:convert';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/proxy.dart';
import 'package:venera/utils/translations.dart';
import 'dart:io' as io;

export 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show WebUri, URLRequest;

extension WebviewExtension on InAppWebViewController {
  Future<List<io.Cookie>> getCookies(String url) async {
    final uri = Uri.parse(url);
    CookieManager cookieManager = CookieManager.instance(
      webViewEnvironment: AppWebview.webViewEnvironment,
    );
    final cookies = await cookieManager.getCookies(
      url: WebUri(url),
      webViewController: this,
    );
    var res = <io.Cookie>[];
    for (var cookie in cookies) {
      final expires = cookie.expiresDate;
      res.add(io.Cookie(cookie.name, cookie.value.toString())
        ..domain = cookie.domain
        ..path = cookie.path
        ..expires = expires == null || cookie.isSessionOnly == true
            ? null
            : DateTime.fromMillisecondsSinceEpoch(expires)
        ..secure = cookie.isSecure ?? (uri.scheme == 'https')
        ..httpOnly = cookie.isHttpOnly ?? false);
    }
    return res;
  }

  Future<String?> getUA() async {
    var res = await evaluateJavascript(source: "navigator.userAgent");
    if (res is String && res.length >= 2) {
      if (res[0] == "'" || res[0] == "\"") {
        res = res.substring(1, res.length - 1);
      }
    }
    return res is String ? res : null;
  }
}

class AppWebview extends StatefulWidget {
  const AppWebview(
      {required this.initialUrl,
      this.onTitleChange,
      this.onNavigation,
      this.singlePage = false,
      this.onStarted,
      this.onLoadStop,
      super.key});

  final String initialUrl;

  final void Function(String title, InAppWebViewController controller)?
      onTitleChange;

  final bool Function(String url, InAppWebViewController controller)?
      onNavigation;

  final void Function(InAppWebViewController controller)? onStarted;

  final void Function(InAppWebViewController controller)? onLoadStop;

  final bool singlePage;

  static WebViewEnvironment? webViewEnvironment;

  @override
  State<AppWebview> createState() => _AppWebviewState();
}

class _AppWebviewState extends State<AppWebview> {
  InAppWebViewController? controller;

  String title = "Webview";

  double _progress = 0;

  late var future = _createWebviewEnvironment();

  Future<bool> _createWebviewEnvironment() async {
    var proxy = appdata.settings['proxy'].toString();
    if (App.isAndroid) {
      final proxyAvailable = await WebViewFeature.isFeatureSupported(
        WebViewFeature.PROXY_OVERRIDE,
      );
      if (proxyAvailable) {
        final proxyController = ProxyController.instance();
        await proxyController.clearProxyOverride();
        if (proxy != "system" && proxy != "direct") {
          if (!proxy.contains("://")) {
            proxy = "http://$proxy";
          }
          await proxyController.setProxyOverride(
            settings: ProxySettings(proxyRules: [ProxyRule(url: proxy)]),
          );
        }
      }
    }
    if (!App.isWindows) {
      return true;
    }
    AppWebview.webViewEnvironment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: "${App.dataPath}\\webview",
      ),
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final actions = [
      Tooltip(
        message: "More",
        child: IconButton(
          icon: const Icon(Icons.more_horiz),
          onPressed: () {
            showMenuX(
              context,
              Offset(context.width, context.padding.top),
              [
                MenuEntry(
                  icon: Icons.open_in_browser,
                  text: "Open in browser".tl,
                  onClick: () async =>
                      launchUrlString((await controller?.getUrl())!.toString()),
                ),
                MenuEntry(
                  icon: Icons.copy,
                  text: "Copy link".tl,
                  onClick: () async => Clipboard.setData(ClipboardData(
                      text: (await controller?.getUrl())!.toString())),
                ),
                MenuEntry(
                  icon: Icons.refresh,
                  text: "Reload".tl,
                  onClick: () => controller?.reload(),
                ),
              ],
            );
          },
        ),
      )
    ];

    Widget body = FutureBuilder(
      future: future,
      builder: (context, e) {
        if (e.error != null) {
          return Center(child: Text("Error: ${e.error}"));
        }
        if (!e.hasData) {
          return const SizedBox();
        }
        return createWebviewWithEnvironment(
          AppWebview.webViewEnvironment,
        );
      },
    );

    body = Stack(
      children: [
        Positioned.fill(child: body),
        if (_progress < 1.0)
          const Positioned.fill(
              child: Center(child: CircularProgressIndicator()))
      ],
    );

    return Scaffold(
        appBar: Appbar(
          title: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: actions,
        ),
        body: body);
  }

  Widget createWebviewWithEnvironment(WebViewEnvironment? e) {
    return InAppWebView(
      webViewEnvironment: e,
      initialSettings: InAppWebViewSettings(
        isInspectable: true,
      ),
      initialUrlRequest: URLRequest(url: WebUri(widget.initialUrl)),
      onTitleChanged: (c, t) {
        if (mounted) {
          setState(() {
            title = t ?? "Webview";
          });
        }
        widget.onTitleChange?.call(title, controller!);
      },
      shouldOverrideUrlLoading: (c, r) async {
        var res =
            widget.onNavigation?.call(r.request.url?.toString() ?? "", c) ??
                false;
        if (res) {
          return NavigationActionPolicy.CANCEL;
        } else {
          return NavigationActionPolicy.ALLOW;
        }
      },
      onWebViewCreated: (c) {
        controller = c;
        widget.onStarted?.call(c);
      },
      onLoadStop: (c, r) {
        widget.onLoadStop?.call(c);
      },
      onProgressChanged: (c, p) {
        if (mounted) {
          setState(() {
            _progress = p / 100;
          });
        }
      },
    );
  }
}

class DesktopWebview {
  static Future<bool> isAvailable() => WebviewWindow.isWebviewAvailable();

  final String initialUrl;

  final void Function(String title, DesktopWebview controller)? onTitleChange;

  final void Function(String url, DesktopWebview webview)? onNavigation;

  final void Function(DesktopWebview controller)? onStarted;

  final void Function()? onClose;

  DesktopWebview(
      {required this.initialUrl,
      this.onTitleChange,
      this.onNavigation,
      this.onStarted,
      this.onClose});

  Webview? _webview;

  String? _ua;

  String? title;

  void onMessage(String message) {
    var json = jsonDecode(message);
    if (json is Map) {
      if (json["id"] == "document_created") {
        title = json["data"]["title"];
        _ua = json["data"]["ua"];
        onTitleChange?.call(title!, this);
      }
    }
  }

  String? get userAgent => _ua;

  Timer? timer;

  void _runTimer() {
    timer ??= Timer.periodic(const Duration(seconds: 2), (t) async {
      const js = '''
        function collect() {
          if(document.readyState === 'loading') {
            return '';
          }
          let data = {
            id: "document_created",
            data: {
              title: document.title,
              url: location.href,
              ua: navigator.userAgent
            }
          };
          return data;
        }
        collect();
      ''';
      if (_webview != null) {
        onMessage(await evaluateJavascript(js) ?? '');
      }
    });
  }

  Future<void> open() async {
    _webview = await WebviewWindow.create(
        configuration: CreateConfiguration(
      useWindowPositionAndSize: true,
      userDataFolderWindows: "${App.dataPath}\\webview",
      title: "webview",
      proxy: await getProxy(),
    ));
    _webview!.addOnWebMessageReceivedCallback(onMessage);
    _webview!.setOnNavigation((s) {
      s = s.substring(1, s.length - 1);
      return onNavigation?.call(s, this);
    });
    _webview!.launch(initialUrl, triggerOnUrlRequestEvent: false);
    _runTimer();
    _webview!.onClose.then((value) {
      _webview = null;
      timer?.cancel();
      timer = null;
      onClose?.call();
    });
    Future.delayed(const Duration(milliseconds: 200), () {
      onStarted?.call(this);
    });
  }

  Future<String?> evaluateJavascript(String source) {
    return _webview!.evaluateJavaScript(source);
  }

  Future<List<io.Cookie>> readCookies() async {
    final cookies = await _webview!.getAllCookies();
    return [
      for (final cookie in cookies)
        io.Cookie(_removeCode0(cookie.name), _removeCode0(cookie.value))
          ..domain = _removeCode0(cookie.domain)
          ..path = _removeCode0(cookie.path)
          // The Linux plugin reports Unix epoch for unset GDateTime expiry.
          ..expires = cookie.sessionOnly ||
                  (App.isLinux && cookie.expires?.millisecondsSinceEpoch == 0)
              ? null
              : cookie.expires
          ..secure = cookie.secure
          ..httpOnly = cookie.httpOnly,
    ];
  }

  String _removeCode0(String s) {
    var codeUints = List<int>.from(s.codeUnits);
    codeUints.removeWhere((e) => e == 0);
    return String.fromCharCodes(codeUints);
  }

  void close() {
    _webview?.close();
    _webview = null;
  }
}
