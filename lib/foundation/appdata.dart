import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/src/rust/api/settings.dart' as backend;
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/init.dart';

/// Observable UI snapshot; persistence and synchronization rules live in Rust.
class Appdata with Init {
  Appdata._create();
  final Settings settings = Settings._create();
  var searchHistory = <String>[];
  var implicitData = <String, dynamic>{};
  Future<void> _pendingSave = Future.value();

  String? _savedSnapshot;

  Future<T> _serialize<T>(Future<T> Function() action) {
    final operation = _pendingSave.then((_) => action());
    _pendingSave = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        Log.error('Appdata', error, stack);
      },
    );
    return operation;
  }

  Future<void> flushSaves() => _pendingSave;

  Future<void> saveData([bool sync = true]) async {
    final changed = await _serialize(_persist);
    if (sync && changed) DataSync().onDataChanged();
  }

  Future<bool> _persist() async {
    final snapshot = jsonEncode(toJson());
    final previous = _savedSnapshot;
    if (previous == null) {
      await backend.saveAppData(directory: App.dataPath, dataJson: snapshot);
    } else if (previous != snapshot) {
      await backend.saveAppDataChanges(
        directory: App.dataPath,
        baseJson: previous,
        dataJson: snapshot,
      );
    }
    _savedSnapshot = snapshot;
    return previous != snapshot;
  }

  Future<Map<String, dynamic>> applyRestoredData(
    Future<Map<String, dynamic>> Function() apply,
  ) => _serialize(() async {
    final base = _savedSnapshot ?? jsonEncode(toJson());
    final result = await apply();
    final data = Map<String, dynamic>.from(result['data']);
    final restored = jsonEncode({
      'settings': data['settings'],
      'searchHistory': data['searchHistory'],
    });
    final rebased = backend.rebaseAppData(
      baseJson: base,
      editedJson: jsonEncode(toJson()),
      currentJson: restored,
    );
    _savedSnapshot = restored;
    _apply(jsonDecode(rebased));
    if (await _persist()) DataSync().onDataChanged();
    return result;
  });

  void applyUploadRevision(int revision) {
    settings['dataVersion'] = revision;
    final snapshot = _savedSnapshot;
    if (snapshot != null) {
      final data = jsonDecode(snapshot);
      data['settings']['dataVersion'] = revision;
      _savedSnapshot = jsonEncode(data);
    }
  }

  void addSearchHistory(String keyword) {
    searchHistory = backend.updateSearchHistory(
      history: searchHistory,
      keyword: keyword,
      remove: false,
    );
    unawaited(saveData());
  }

  void removeSearchHistory(String keyword) {
    searchHistory = backend.updateSearchHistory(
      history: searchHistory,
      keyword: keyword,
      remove: true,
    );
    unawaited(saveData());
  }

  void clearSearchHistory() {
    searchHistory = backend.updateSearchHistory(
      history: searchHistory,
      remove: true,
    );
    unawaited(saveData());
  }

  Map<String, dynamic> toJson() => {
    'settings': settings._data,
    'searchHistory': searchHistory,
  };

  void _apply(Map<String, dynamic> data) {
    settings._replace(Map<String, dynamic>.from(data['settings']));
    searchHistory = List<String>.from(data['searchHistory']);
  }

  void syncData(Map<String, dynamic> data) {
    _apply(
      jsonDecode(
        backend.mergeSyncedData(
          currentJson: jsonEncode(toJson()),
          incomingJson: jsonEncode(data),
        ),
      ),
    );
    unawaited(saveData());
  }

  void writeImplicitData() {
    final snapshot = jsonEncode(implicitData);
    unawaited(
      _serialize(
        () => backend.saveImplicitData(
          directory: App.dataPath,
          dataJson: snapshot,
        ),
      ).then(
        (_) {
          DataSync().refreshConfiguration();
        },
        onError: (Object _, StackTrace _) {
          // _serialize already logged the save failure.
        },
      ),
    );
  }

  @override
  Future<void> doInit() async {
    try {
      final data = jsonDecode(
        await backend.loadAppData(directory: App.dataPath),
      );
      _apply(data);
      implicitData = Map<String, dynamic>.from(data['implicitData']);
      await saveData(false);
    } catch (error, stack) {
      // Keep corrupt/unreadable files for recovery, and let other components initialize.
      Log.error('Appdata', error, stack);
    }
  }
}

final appdata = Appdata._create();

class Settings with ChangeNotifier {
  Settings._create();

  final Map<String, dynamic> _data = jsonDecode(backend.defaultSettingsJson());

  void _replace(Map<String, dynamic> values) {
    _data.addAll(values);
    notifyListeners();
  }

  operator [](String key) {
    return _data[key];
  }

  operator []=(String key, dynamic value) {
    _mutate('global', key: key, value: value);
    if (key != "dataVersion") {
      notifyListeners();
    }
  }

  void setEnabledComicSpecificSettings(
    String comicId,
    String sourceKey,
    bool enabled,
  ) {
    setReaderSetting(comicId, sourceKey, "enabled", enabled);
  }

  bool isComicSpecificSettingsEnabled(String? comicId, String? sourceKey) {
    if (comicId == null || sourceKey == null) {
      return false;
    }
    return _data['comicSpecificSettings']["$comicId@$sourceKey"]?["enabled"] ==
        true;
  }

  dynamic getReaderSetting(String comicId, String sourceKey, String key) {
    return jsonDecode(
      backend.readerSetting(
        settingsJson: jsonEncode(_data),
        comicKey: '$comicId@$sourceKey',
        key: key,
      ),
    );
  }

  void setReaderSetting(
    String comicId,
    String sourceKey,
    String key,
    dynamic value,
  ) {
    _mutate('comic', owner: '$comicId@$sourceKey', key: key, value: value);
    notifyListeners();
  }

  void resetComicReaderSettings(String key) {
    _mutate('comic', owner: key);
    notifyListeners();
  }

  void setEnabledDeviceSpecificSettings(bool enabled) {
    setDeviceReaderSetting("enabled", enabled);
  }

  bool isDeviceSpecificSettingsEnabled() {
    var deviceId = _data['deviceId'] as String;
    if (deviceId.isEmpty) {
      return false;
    }
    return _data['deviceSpecificSettings'][deviceId]?["enabled"] == true;
  }

  dynamic getDeviceReaderSetting(String key) {
    return jsonDecode(
      backend.readerSetting(settingsJson: jsonEncode(_data), key: key),
    );
  }

  void setDeviceReaderSetting(String key, dynamic value) {
    _mutate('device', key: key, value: value);
    notifyListeners();
  }

  void resetDeviceReaderSettings() {
    _mutate('device');
    notifyListeners();
  }

  void _mutate(String scope, {String? owner, String? key, dynamic value}) {
    final next = jsonDecode(
      backend.mutateSettings(
        settingsJson: jsonEncode(_data),
        scope: scope,
        owner: owner,
        key: key,
        valueJson: key == null ? null : jsonEncode(value),
      ),
    );
    _data
      ..clear()
      ..addAll(Map<String, dynamic>.from(next));
  }

  @override
  String toString() {
    return _data.toString();
  }
}

String get defaultCustomImageProcessing =>
    jsonDecode(backend.defaultSettingsJson())['customImageProcessing']
        as String;
