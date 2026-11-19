import 'dart:convert';

import 'package:venera_edge/foundation/app.dart';
import 'package:venera_edge/src/rust/api/script.dart' as backend;

/// Source data is read as a snapshot. Settings use the schema-aware script
/// runtime API; account and other source data use explicit field writes.
class SourceData {
  const SourceData(this.key);
  final String key;

  Map<String, dynamic> get snapshot =>
      _freeze(
            jsonDecode(
              backend.loadSourceData(directory: App.dataPath, key: key),
            ),
          )!
          as Map<String, dynamic>;

  void set(String field, Object? value) => backend.updateSourceData(
    directory: App.dataPath,
    key: key,
    path: [field],
    valueJson: jsonEncode(value),
  );
}

Object? _freeze(Object? value) => switch (value) {
  Map<String, dynamic> map => Map<String, dynamic>.unmodifiable(
    map.map((key, value) => MapEntry(key, _freeze(value))),
  ),
  List<dynamic> list => List<dynamic>.unmodifiable(list.map(_freeze)),
  _ => value,
};
