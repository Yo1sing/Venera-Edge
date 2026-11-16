import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:venera/components/js_ui.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/script_bridge.dart';
import 'package:venera/network/proxy.dart';
import 'package:venera/src/rust/api/http.dart' as http_backend;
import 'package:venera/src/rust/api/script.dart' as backend;
import 'package:venera/utils/init.dart';
import 'package:venera/utils/io.dart' show FileExtension;

export 'script_bridge.dart' show JSInvokable;

class JavaScriptRuntimeException implements Exception {
  final String message;
  JavaScriptRuntimeException(this.message);
  @override
  String toString() => 'JSException: $message';
}

/// UI events and value conversion only; QuickJS and all source host APIs run in Rust.
class JsEngine with JsUiApi, Init {
  static JsEngine? _cache;
  factory JsEngine() => _cache ??= JsEngine._create();
  JsEngine._create();
  ScriptSession? _session;
  String? _options;
  Timer? _systemProxyRefresh;
  int _networkRevision = 0;

  backend.ScriptRuntime get runtime => _session!.runtime;

  static void reset() {
    _cache?.dispose();
    _cache = null;
    unawaited(JsEngine().init());
  }

  static Future<String> runtimeOptions() async =>
      _encodeOptions(await readHttpOptions());

  static String _encodeOptions(http_backend.HttpOptions http) => jsonEncode({
    'data_path': App.dataPath,
    'version': App.version,
    'locale': '${App.locale.languageCode}_${App.locale.countryCode}',
    'platform': Platform.operatingSystem,
    'user_agent': webUA,
    'cloudflare_user_agent': appdata.implicitData['ua'] ?? webUA,
    'http': {
      'proxy': http.proxy,
      'dns_overrides': http.dnsOverrides,
      'tls_sni': http.tlsSni,
      'verify_certificates': http.verifyCertificates,
      'connect_timeout_ms': http.connectTimeoutMs,
      'receive_timeout_ms': http.receiveTimeoutMs,
      'max_redirects': http.maxRedirects,
    },
  });

  void resetDio() {
    if (appdata.settings['proxy'] == 'system' && !App.isLinux) {
      _systemProxyRefresh ??= Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(_refreshOptions()),
      );
    } else {
      _systemProxyRefresh?.cancel();
      _systemProxyRefresh = null;
    }
    unawaited(_refreshOptions());
  }

  Future<void> _refreshOptions() async {
    final session = _session;
    if (session == null || session.closed) return;
    final revision = ++_networkRevision;
    try {
      final http = await readHttpOptions();
      if (revision != _networkRevision || session.closed) return;
      final options = _encodeOptions(http);
      if (options == _options) return;
      _publishHttpOptions(http);
      _options = options;
      await session.runtime.configure(optionsJson: options);
    } catch (error, stack) {
      if (!session.closed) Log.error('Network', error, stack);
    }
  }

  void _publishHttpOptions(http_backend.HttpOptions options) =>
      http_backend.configureSourceHttp(
        cookiePath: '${App.dataPath}/cookie.db',
        options: options,
      );

  @override
  Future<void> doInit() async {
    final http = await readHttpOptions();
    _options = _encodeOptions(http);
    final runtime = await backend.ScriptRuntime.open(optionsJson: _options!);
    final session = ScriptSession(runtime);
    _session = session;
    _publishHttpOptions(http);
    appdata.settings.addListener(resetDio);
    resetDio();
    unawaited(_listen(session));
  }

  Future<void> _listen(ScriptSession session) async {
    try {
      while (!session.closed) {
        final encoded = await session.runtime.nextEvent();
        if (encoded == null) break;
        final event = jsonDecode(encoded);
        // Dialogs may stay open while other script/UI events continue.
        unawaited(_dispatchEvent(session, event));
      }
    } catch (error, stack) {
      if (!session.closed) Log.error('JS Engine', error, stack);
    } finally {
      session.close();
      session.runtime.dispose();
    }
  }

  Future<void> _dispatchEvent(
    ScriptSession session,
    Map<String, dynamic> event,
  ) async {
    if (session.closed) return;
    if (event['event'] == 'sourceChanged') {
      ComicSourceManager().notifyStateChange();
      return;
    }
    final data = session.decode(event['data']) as Map<String, dynamic>;
    if (event['event'] == 'log') {
      Log.addLog(
        switch (data['level']) {
          'error' => LogLevel.error,
          'info' => LogLevel.info,
          _ => LogLevel.warning,
        },
        data['title']?.toString() ?? 'Source',
        data['content'].toString(),
      );
      return;
    }
    dynamic result;
    String? error;
    try {
      switch (data['method']) {
        case 'localFile':
          final path = data['path'] as String;
          final to = data['to'] as String?;
          if (!path.startsWith('android://') &&
              !(to?.startsWith('android://') ?? false)) {
            throw StateError('Expected SAF file operation');
          }
          switch (data['operation']) {
            case 'list':
              result = await Directory(path)
                  .list()
                  .map(
                    (entry) => {
                      'path': entry.path,
                      'is_dir': entry is Directory,
                    },
                  )
                  .toList();
            case 'exists':
              result =
                  await Directory(path).exists() || await File(path).exists();
            case 'modified':
              result = (await Directory(
                path,
              ).stat()).modified.millisecondsSinceEpoch;
            case 'mkdir':
              await Directory(path).create();
            case 'copy':
              await File(path).copyMem(to!);
            case 'rename':
              await Directory(path).rename(to!);
              if (!await Directory(to).exists() ||
                  await Directory(path).exists()) {
                throw StateError('Directory rename was not completed');
              }
            case 'remove':
              await Directory(path).delete(recursive: true);
              if (await Directory(path).exists()) {
                throw StateError('Directory deletion was not completed');
              }
            default:
              throw StateError('Unknown local file operation');
          }
        case 'imageFavoriteFile':
          final path = data['path'] as String;
          if (!path.startsWith('android://')) {
            throw StateError('Expected SAF URI');
          }
          result = switch (data['operation']) {
            'list' =>
              await Directory(path)
                  .list()
                  .where((entry) => entry is File)
                  .map((entry) => entry.path)
                  .toList(),
            'read' => await File(path).readAsBytes(),
            _ => throw StateError('Unknown favorite file operation'),
          };
        case 'UI':
          data['_bridgeLoadingId'] = event['ticket'];
          result = await handleUIMessage(data);
        case 'setClipboard':
          await Clipboard.setData(ClipboardData(text: data['text']));
        case 'getClipboard':
          result = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
        default:
          throw StateError('Unsupported platform event');
      }
    } catch (e, s) {
      error = e.toString();
      Log.error('JS UI', e, s);
    }
    if (!session.closed && event['reply'] == true) {
      session.runtime.resolveEvent(
        id: event['ticket'],
        valueJson: jsonEncode(encodeScriptValue(result)),
        error: error,
      );
    }
  }

  dynamic runCode(String js, [String? name]) =>
      (_session ?? (throw StateError('JS runtime is not initialized')))
          .evaluate(js);

  Future<Map<String, dynamic>> parseSource(String code) async {
    final session = _session!;
    return session.decodeJson(await session.runtime.parseSource(code: code));
  }

  Future<void> initializeSource(String key) =>
      _session!.runtime.initializeSource(key: key);

  Future<dynamic> compute(String source, List<dynamic> arguments) async {
    final session =
        _session ?? (throw StateError('JS runtime is not initialized'));
    return session.decodeJson(
      await backend.computeScript(
        optionsJson: _options!,
        source: source,
        argumentsJson: jsonEncode(encodeScriptValue(arguments)),
      ),
    );
  }

  void dispose() {
    appdata.settings.removeListener(resetDio);
    _systemProxyRefresh?.cancel();
    _systemProxyRefresh = null;
    _session?.close();
    _session = null;
    if (identical(_cache, this)) _cache = null;
  }
}

class JSAutoFreeFunction {
  final JSInvokable func;

  /// Automatically free the function when it's not used anymore
  JSAutoFreeFunction(this.func) {
    func.dup();
    finalizer.attach(this, func);
  }

  dynamic call(List<dynamic> args) {
    return func(args);
  }

  static final finalizer = Finalizer<JSInvokable>((func) {
    func.destroy();
  });
}
