import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:venera_edge/foundation/comic_source/comic_source.dart';
import '../foundation/app.dart';

extension AppTranslation on String {
  String _translate() {
    final locale = App.locale;
    final key = switch (locale.languageCode) {
      "en" => "en_US",
      "zh" => switch ((locale.scriptCode, locale.countryCode)) {
        ("Hant", _) => "zh_TW",
        ("Hans", _) => "zh_CN",
        (_, "TW" || "HK" || "MO") => "zh_TW",
        _ => "zh_CN",
      },
      _ => "${locale.languageCode}_${locale.countryCode}",
    };
    return (translations[key]?[this]) ?? this;
  }

  String get tl => _translate();

  String get tlEN => translations["en_US"]![this] ?? this;

  String tlParams(Map<String, Object> values) {
    var res = _translate();
    for (var entry in values.entries) {
      res = res.replaceFirst("@${entry.key}", entry.value.toString());
    }
    return res;
  }

  static late final Map<String, Map<String, String>> translations;

  static Future<void> init() async {
    var data = await rootBundle.load("assets/translation.json");
    var json = jsonDecode(utf8.decode(data.buffer.asUint8List()));
    translations = {
      for (var e in json.entries) e.key: Map<String, String>.from(e.value),
    };
  }

  /// Translate a string using specified comic source
  String ts(String sourceKey) {
    var comicSource = ComicSource.find(sourceKey);
    if (comicSource == null || comicSource.translations == null) {
      return this;
    }
    var locale = App.locale;
    var lc = locale.languageCode;
    var cc = locale.countryCode;
    var key = "$lc${cc == null ? "" : "_$cc"}";
    return (comicSource.translations![key] ??
            comicSource.translations![lc])?[this] ??
        this;
  }
}

extension ListTranslation on List<String> {
  List<String> _translate() {
    return List.generate(length, (index) => this[index].tl);
  }

  List<String> get tl => _translate();
}
