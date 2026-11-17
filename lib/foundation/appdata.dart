import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/src/rust/api/settings.dart' as backend;
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/init.dart';

typedef _Edit = Map<String, Object?>;

class SettingsEditsRejected extends StateError {
  SettingsEditsRejected(super.message);
}

Object? _freeze(Object? value) => switch (value) {
  Map<String, dynamic> map => Map<String, dynamic>.unmodifiable(
    map.map((key, value) => MapEntry(key, _freeze(value))),
  ),
  List<dynamic> list => List<dynamic>.unmodifiable(list.map(_freeze)),
  _ => value,
};

/// Applies Rust's previews immediately and persists edits against the latest
/// backend state. Pending edits are replayed when a save or restore returns.
class Appdata with Init {
  Appdata._create();
  late final Settings settings = Settings._create(this);
  List<String> _searchHistory = const [];
  List<String> get searchHistory => _searchHistory;
  Map<String, dynamic> _implicitData = const {};
  Map<String, dynamic> get implicitData => _implicitData;
  final _pendingEdits = <_Edit>[];
  final _implicitChanges = <String, Object?>{};
  Future<void> _pendingSave = Future.value();

  Future<T> _serialize<T>(Future<T> Function() action) {
    final operation = _pendingSave.then((_) => action());
    _pendingSave = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) =>
          Log.error('Appdata', error, stack),
    );
    return operation;
  }

  Future<void> flushSaves() => _pendingSave;

  Future<void> saveData([bool sync = true]) async {
    final changed = await _serialize(_persist);
    if (sync && changed) DataSync().onDataChanged();
  }

  Future<bool> _persist() async {
    if (_pendingEdits.isEmpty) return false;
    final count = _pendingEdits.length;
    final result = jsonDecode(
      await backend.applyAppDataEdits(
        directory: App.dataPath,
        editsJson: jsonEncode(_pendingEdits),
      ),
    );
    _pendingEdits.removeRange(0, count);
    _applyPending(result['data']);
    if (result['rejected'].isNotEmpty) {
      if (result['changed'] == true) DataSync().onDataChanged();
      throw SettingsEditsRejected(result['rejected'].join('\n'));
    }
    return result['changed'] as bool;
  }

  Future<Map<String, dynamic>> applyRestoredData(
    Future<Map<String, dynamic>> Function() apply,
  ) => _serialize(() async {
    final result = await apply();
    _applyPending(result['data']);
    return result;
  });

  void applyUploadRevision(int revision) => settings._applyRevision(revision);

  void addSearchHistory(String keyword) => _editHistory(keyword, false);
  void removeSearchHistory(String keyword) => _editHistory(keyword, true);
  void clearSearchHistory() => _editHistory(null, true);

  void _editHistory(String? keyword, bool remove) {
    _edit([
      {'scope': 'search', 'keyword': keyword, 'remove': remove},
    ]);
    unawaited(saveData());
  }

  Map<String, dynamic> toJson() => {
    'settings': settings._data,
    'searchHistory': _searchHistory,
  };

  void _edit(List<_Edit> edits) {
    final payload = jsonEncode(edits);
    final next = jsonDecode(
      backend.previewAppDataEdits(
        dataJson: jsonEncode(toJson()),
        editsJson: payload,
        strict: true,
      ),
    )['data'];
    _pendingEdits.addAll(List<_Edit>.from(jsonDecode(payload)));
    _apply(next);
  }

  void _applyPending(Map<String, dynamic> data) {
    final next = _pendingEdits.isEmpty
        ? data
        : jsonDecode(
            backend.previewAppDataEdits(
              dataJson: jsonEncode(data),
              editsJson: jsonEncode(_pendingEdits),
              strict: false,
            ),
          )['data'];
    _apply(next);
  }

  void _apply(Map<String, dynamic> data) {
    _searchHistory = List<String>.unmodifiable(data['searchHistory']);
    settings._replace(data['settings']);
  }

  void setImplicitData(String key, Object? value) {
    final frozen = _freeze(value);
    _implicitChanges[key] = frozen;
    _implicitData = Map.unmodifiable({..._implicitData, key: frozen});
  }

  void writeImplicitData() {
    unawaited(
      saveImplicitData().catchError((Object _, StackTrace _) {
        // _serialize already logged the save failure.
      }),
    );
  }

  Future<void> saveImplicitData() => _serialize(() async {
    if (_implicitChanges.isEmpty) return;
    final changes = Map<String, Object?>.of(_implicitChanges);
    final result =
        jsonDecode(
              await backend.applyImplicitDataEdits(
                directory: App.dataPath,
                changesJson: jsonEncode(changes),
              ),
            )
            as Map<String, dynamic>;
    for (final entry in changes.entries) {
      if (_implicitChanges[entry.key] == entry.value) {
        _implicitChanges.remove(entry.key);
      }
    }
    _implicitData =
        _freeze({...result, ..._implicitChanges})! as Map<String, dynamic>;
    if (changes.containsKey('webdavAutoSync')) {
      DataSync().refreshConfiguration();
    }
  });

  @override
  Future<void> doInit() async {
    try {
      final result = jsonDecode(
        await backend.applyAppDataEdits(
          directory: App.dataPath,
          editsJson: '[]',
        ),
      );
      final data = result['data'] as Map<String, dynamic>;
      _implicitData = _freeze(data['implicitData'])! as Map<String, dynamic>;
      _applyPending(data);
    } catch (error, stack) {
      Log.error('Appdata', error, stack);
    }
  }
}

final appdata = Appdata._create();

class Settings with ChangeNotifier {
  Settings._create(this._app);
  final Appdata _app;
  Map<String, dynamic> _data =
      _freeze(jsonDecode(backend.defaultSettingsJson()))!
          as Map<String, dynamic>;

  void _replace(Map<String, dynamic> values) {
    final revision = _data['dataVersion'] as int;
    if (revision > (values['dataVersion'] as int)) {
      values = {...values, 'dataVersion': revision};
    }
    if (jsonEncode(_data) == jsonEncode(values)) return;
    _data = _freeze(values)! as Map<String, dynamic>;
    notifyListeners();
  }

  void _applyRevision(int revision) {
    if (revision > (_data['dataVersion'] as int)) {
      _data = Map.unmodifiable({..._data, 'dataVersion': revision});
    }
  }

  dynamic operator [](String key) => _data[key];

  void operator []=(String key, dynamic value) {
    final previous = _data[key];
    if (previous is List || previous is Map || value is List || value is Map) {
      replaceValue(key, previous: previous, value: value);
    } else {
      _change(key, {'action': 'set', 'value': value});
    }
  }

  void reset(String key) => _change(key, {'action': 'reset'});

  void replaceValue(
    String key, {
    required Object? previous,
    required Object? value,
  }) =>
      _change(key, {'action': 'replace', 'previous': previous, 'value': value});

  void replaceWebDav({
    required Object? previous,
    required String previousExclusions,
    required Object? config,
    required String exclusions,
  }) => _app._edit([
    {
      'scope': 'webDav',
      'previous': previous,
      'previousExclusions': previousExclusions,
      'config': config,
      'exclusions': exclusions,
    },
  ]);

  void addBlockedWord(String key, String value) =>
      _change(key, {'action': 'add', 'value': value});

  void removeBlockedWord(String key, String value) =>
      _change(key, {'action': 'remove', 'value': value});

  void addComicSourceListUrl(String value) =>
      _change('comicSourceListUrls', {'action': 'add', 'value': value});

  void removeComicSourceListUrl(String value) =>
      _change('comicSourceListUrls', {'action': 'remove', 'value': value});

  void _change(String key, _Edit change) => _app._edit([
    {'scope': 'global', 'key': key, 'change': change},
  ]);

  void setEnabledComicSpecificSettings(
    String comicId,
    String sourceKey,
    bool enabled,
  ) => setReaderSetting(comicId, sourceKey, 'enabled', enabled);

  bool isComicSpecificSettingsEnabled(String? comicId, String? sourceKey) =>
      comicId != null &&
      sourceKey != null &&
      _data['comicSpecificSettings']['$comicId@$sourceKey']?['enabled'] == true;

  dynamic getReaderSetting(String comicId, String sourceKey, String key) =>
      _resolveReaderSetting(key, comicKey: '$comicId@$sourceKey');

  void setReaderSetting(
    String comicId,
    String sourceKey,
    String key,
    dynamic value,
  ) => _app._edit([
    {
      'scope': 'comic',
      'owner': '$comicId@$sourceKey',
      'edit': {'key': key, 'value': value},
    },
  ]);

  void resetComicReaderSettings(String key) => _app._edit([
    {'scope': 'comic', 'owner': key},
  ]);

  void setEnabledDeviceSpecificSettings(bool enabled) =>
      setDeviceReaderSetting('enabled', enabled);

  bool isDeviceSpecificSettingsEnabled() =>
      _data['deviceSpecificSettings'][_data['deviceId']]?['enabled'] == true;

  dynamic getDeviceReaderSetting(String key) => _resolveReaderSetting(key);

  dynamic _resolveReaderSetting(String key, {String? comicKey}) => jsonDecode(
    backend.readerSetting(
      settingsJson: jsonEncode(_data),
      comicKey: comicKey,
      key: key,
    ),
  );

  void setDeviceReaderSetting(String key, dynamic value) => _app._edit([
    {
      'scope': 'device',
      'edit': {'key': key, 'value': value},
    },
  ]);

  void resetDeviceReaderSettings() => _app._edit([
    {'scope': 'device'},
  ]);

  @override
  String toString() => _data.toString();
}
