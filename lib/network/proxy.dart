import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/src/rust/api/http.dart';
import 'package:venera/utils/ext.dart';

String? _cachedProxy;

DateTime? _cachedProxyTime;

Future<String?> getProxy() async {
  final setting = (appdata.settings['proxy'] as String).removeAllBlank;
  if (setting == 'direct') return null;
  if (setting != 'system') return setting;
  if (_cachedProxyTime != null &&
      DateTime.now().difference(_cachedProxyTime!).inSeconds < 1) {
    return _cachedProxy;
  }
  final proxy = await _readSystemProxy();
  _cachedProxy = proxy;
  _cachedProxyTime = DateTime.now();
  return proxy;
}

Future<HttpOptions> readHttpOptions({
  int connectTimeoutMs = 15000,
  int receiveTimeoutMs = 15000,
  int maxRedirects = 5,
}) async {
  final overrides = <String, String>{};
  final config = appdata.settings['dnsOverrides'];
  if (appdata.settings['enableDnsOverrides'] == true && config is Map) {
    for (final entry in config.entries) {
      if (entry.key is String && entry.value is String) {
        overrides[entry.key] = entry.value;
      }
    }
  }
  final tlsSni = appdata.settings['sni'] != false;
  final verifyCertificates = appdata.settings['ignoreBadCertificate'] != true;
  return HttpOptions(
    proxy: await getProxy(),
    dnsOverrides: overrides,
    tlsSni: tlsSni,
    verifyCertificates: verifyCertificates,
    connectTimeoutMs: connectTimeoutMs,
    receiveTimeoutMs: receiveTimeoutMs,
    maxRedirects: maxRedirects,
  );
}

Future<String?> _readSystemProxy() async {
  String res;
  if (!App.isLinux) {
    const channel = MethodChannel("venera/method_channel");
    try {
      res = await channel.invokeMethod("getProxy");
    } catch (e) {
      return null;
    }
  } else {
    res = "No Proxy";
  }
  if (res == "No Proxy") return null;

  if (res.contains(";")) {
    var proxies = res.split(";");
    for (String proxy in proxies) {
      proxy = proxy.removeAllBlank;
      if (proxy.startsWith('https=')) {
        return proxy.substring(6);
      }
    }
  }

  final RegExp regex = RegExp(
    r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}:\d+$',
    caseSensitive: false,
    multiLine: false,
  );
  if (!regex.hasMatch(res)) {
    return null;
  }

  return res;
}
