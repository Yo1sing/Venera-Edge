import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:venera_edge/src/rust/api/cookies.dart';

/// Compatibility adapter for platform Cookie values and the source JavaScript API.
/// Persistence, expiry and request matching are owned by Rust.
class CookieJarSql {
  final String path;
  late final CookieStore _store = CookieStore.open(path: path);

  CookieJarSql(this.path) {
    init();
  }

  void init() => reopen();

  bool saveFromWebview(
    Uri uri,
    List<Cookie> cookies, {
    required int generation,
    String? userAgent,
  }) => _store.saveWebview(
    url: uri.toString(),
    cookies: _toStoredCookies(cookies),
    userAgent: userAgent,
    generation: generation,
  );

  int get generation => _store.generation();

  bool completeCloudflare(
    String url,
    List<Cookie> cookies,
    String userAgent,
    int generation,
  ) => _store.completeCloudflare(
    url: url,
    cookies: _toStoredCookies(cookies),
    userAgent: userAgent,
    generation: generation,
  );

  List<StoredCookie> _toStoredCookies(List<Cookie> cookies) => cookies
      .map(
        (cookie) => StoredCookie(
          name: cookie.name,
          value: cookie.value,
          domain: cookie.domain,
          path: cookie.path,
          expiresMs: cookie.expires?.millisecondsSinceEpoch,
          secure: cookie.secure,
          httpOnly: cookie.httpOnly,
          maxAge: cookie.maxAge,
        ),
      )
      .toList();

  List<Cookie> loadForRequest(Uri uri) => _store
      .load(url: uri.toString())
      .map(
        (cookie) => Cookie(cookie.name, cookie.value)
          ..domain = cookie.domain
          ..path = cookie.path
          ..expires = cookie.expiresMs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(cookie.expiresMs!)
          ..secure = cookie.secure
          ..httpOnly = cookie.httpOnly,
      )
      .toList();

  void saveFromResponseCookieHeader(Uri uri, List<String> headers) =>
      _store.saveHeaders(url: uri.toString(), headers: headers);

  String loadForRequestCookieHeader(Uri uri) =>
      _store.header(url: uri.toString());

  void delete(Uri uri, String name) =>
      _store.delete(url: uri.toString(), name: name);

  void deleteUri(Uri uri) => _store.delete(url: uri.toString());

  void deleteAll() => _store.clear();

  void pause() => _store.close();

  void reopen() => _store.reopen();

  void dispose() => pause();
}

class SingleInstanceCookieJar extends CookieJarSql {
  factory SingleInstanceCookieJar(String path) =>
      instance ??= SingleInstanceCookieJar._create(path);

  SingleInstanceCookieJar._create(super.path);

  static SingleInstanceCookieJar? instance;

  static Future<SingleInstanceCookieJar> createInstance() async {
    if (instance != null) {
      return instance!;
    }
    var dataPath = (await getApplicationSupportDirectory()).path;
    instance = SingleInstanceCookieJar("$dataPath/cookie.db");
    return instance!;
  }
}
