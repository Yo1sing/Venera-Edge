import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/src/rust/api/backup.dart' as backend;
import 'package:venera/utils/data.dart';
import 'package:venera/utils/translations.dart';

import 'io.dart';

class DataSync with ChangeNotifier {
  DataSync._() {
    _opening = _open();
    LocalFavoritesManager().addListener(_favoritesChanged);
  }

  static final _instance = DataSync._();
  factory DataSync() => _instance;

  late final Future<backend.SyncController> _opening;
  backend.SyncController? _controller;
  Map<String, dynamic> _snapshot = {};
  Completer<void>? _closing;
  bool _refreshingFavorites = false;

  bool get isDownloading =>
      _snapshot['phase'] == 'downloading' || _snapshot['phase'] == 'restoring';
  bool get isUploading => _snapshot['phase'] == 'uploading';
  bool get isEnabled => _snapshot['enabled'] == true;
  String? get lastError => _snapshot['error'] as String?;

  static bool _busy(Map<String, dynamic> state) =>
      state['phase'] != 'idle' || state['pending'] != 0;

  Future<backend.SyncController> _open() async {
    final controller = await backend.SyncController.open(
      directory: App.dataPath,
      cache: App.cachePath,
    );
    _controller = controller;
    _update(jsonDecode(controller.snapshot()));
    unawaited(_listen(controller));
    return controller;
  }

  void _update(Map<String, dynamic> snapshot) {
    _snapshot = snapshot;
    final revision = snapshot['revision'] as int?;
    if (revision != null &&
        revision > (appdata.settings['dataVersion'] as int)) {
      appdata.applyUploadRevision(revision);
    }
    final closing = _closing;
    if (closing != null && !closing.isCompleted && !_busy(snapshot)) {
      closing.complete();
    }
    notifyListeners();
  }

  Future<void> _listen(backend.SyncController controller) async {
    try {
      while (true) {
        final state =
            jsonDecode(await controller.nextSnapshot()) as Map<String, dynamic>;
        _update(state);
        final id = state['restore'] as int?;
        if (id != null) {
          String? error;
          try {
            await applyScheduledBackup(controller, id, _refreshFavorites);
          } catch (e, stack) {
            error = e.toString();
            Log.error('Sync', e, stack);
          } finally {
            controller.finishRestore(id: id, error: error);
          }
        }
      }
    } catch (error, stack) {
      Log.error('Sync', error, stack);
      final closing = _closing;
      if (closing != null && !closing.isCompleted) {
        closing.completeError(error, stack);
      }
    }
  }

  void _favoritesChanged() {
    if (!_refreshingFavorites) onDataChanged();
  }

  void _refreshFavorites() {
    _refreshingFavorites = true;
    try {
      LocalFavoritesManager().initCounts();
    } finally {
      _refreshingFavorites = false;
    }
  }

  bool allowWindowClose() {
    if (_closing != null) return false;
    final controller = _controller;
    if (controller == null) return true;
    final live = jsonDecode(controller.snapshot()) as Map<String, dynamic>;
    if (!_busy(live)) return true;

    final closing = _closing = Completer<void>();
    unawaited(
      showDialog<void>(
        context: App.rootContext,
        barrierDismissible: false,
        builder: (context) => PopScope(
          canPop: false,
          child: ListenableBuilder(
            listenable: this,
            builder: (context, _) => ContentDialog(
              title: switch (_snapshot['phase']) {
                'uploading' => "Uploading data...".tl,
                'restoring' => "Restoring data...".tl,
                _ => "Downloading data...".tl,
              },
              content: const Padding(
                padding: EdgeInsets.all(16),
                child: LinearProgressIndicator(),
              ),
              actions: [
                FilledButton(
                  onPressed: _snapshot['phase'] == 'restoring'
                      ? null
                      : () {
                          final current =
                              jsonDecode(controller.snapshot())
                                  as Map<String, dynamic>;
                          if (current['phase'] != 'restoring') exit(0);
                        },
                  child: Text("Shut Down".tl),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    unawaited(
      closing.future.then<void>(
        (_) => exit(0),
        onError: (Object _) {
          _closing = null;
        },
      ),
    );
    return false;
  }

  Future<void> _submit(String action, {String? path}) async {
    final controller = await _opening;
    await appdata.flushSaves();
    final runtime = jsonDecode(await JsEngine.runtimeOptions());
    await controller.submit(
      action: action,
      httpJson: jsonEncode(runtime['http']),
      path: path,
    );
  }

  Future<Res<bool>> _request(String action, {String? path}) async {
    try {
      if (action == 'upload') await appdata.saveData(false);
      await _submit(action, path: path);
      return const Res(true);
    } catch (error, stack) {
      Log.error('Sync', error, stack);
      return Res.error(error.toString());
    }
  }

  void start() => unawaited(_request('startup'));
  void resumed() => unawaited(_request('resume'));
  void onDataChanged() => unawaited(_request('changed'));
  void refreshConfiguration() => unawaited(_request('refresh'));

  Future<Res<bool>> uploadData() => _request('upload');
  Future<Res<bool>> downloadData() => _request('download');

  Future<void> importBackup(String path) => _submit('import', path: path);
}
