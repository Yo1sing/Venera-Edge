import 'dart:async';
import 'dart:convert';

import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/src/rust/api/follow_updates.dart' as backend;

class ComicUpdateResult {
  final bool updated;
  final String? errorMessage;
  ComicUpdateResult(this.updated, this.errorMessage);
}

class UpdateProgress {
  final int total;
  final int current;
  final int skipped;
  final int errors;
  final int updated;
  final String status;
  final FavoriteItemWithUpdateInfo? comic;
  final String? errorMessage;

  UpdateProgress.fromJson(Map<String, dynamic> json)
    : total = json['total'],
      current = json['current'],
      skipped = json['skipped'],
      errors = json['errors'],
      updated = json['updated'],
      status = json['status'],
      errorMessage = json['error_message'],
      comic = json['comic'] == null ? null : _comic(json['comic']);

  static FavoriteItemWithUpdateInfo _comic(Map<String, dynamic> row) =>
      FavoriteItemWithUpdateInfo(
        FavoriteItem.fromRow(row),
        row['last_update_time'],
        row['has_new_update'],
        row['last_check_time'],
      );

  double get fraction => total == 0 ? 1 : current / total;
  bool get isDone => status != 'running';
}

/// Bridges settings, task handles and snapshots. Rust owns scheduling and rules.
abstract class FollowUpdatesBackend {
  static Future<backend.FollowUpdateService>? _opening;
  static bool paused = false;
  static bool restoring = false;
  static String? automaticFolder;

  static String get _sourceTypes => jsonEncode({
    for (final source in ComicSource.all())
      '${source.key.hashCode}': source.key,
  });

  static Future<backend.FollowUpdateService> _service() {
    if (restoring) throw StateError('Data restore in progress');
    return _opening ??= _open();
  }

  static Future<backend.FollowUpdateService> _open() async {
    final service = await backend.FollowUpdateService.open(
      runtime: JsEngine().runtime,
      favorites: LocalFavoritesManager().backendStore,
    );
    try {
      unawaited(_listen(service));
      await _configure(service);
      return service;
    } catch (_) {
      await service.close();
      service.dispose();
      _opening = null;
      rethrow;
    }
  }

  static Future<void> _listen(backend.FollowUpdateService service) async {
    try {
      while (true) {
        final event = await service.nextEvent();
        if (event == null) break;
        final progress = UpdateProgress.fromJson(jsonDecode(event));
        if (progress.isDone && !restoring) {
          LocalFavoritesManager().notifyChanges();
        }
        if (progress.errorMessage != null) {
          Log.error(
            'Check Updates',
            progress.errorMessage ?? 'Update check failed',
          );
        }
      }
    } catch (error, stack) {
      Log.error('Check Updates', error, stack);
    }
  }

  static Future<void> _configure(backend.FollowUpdateService service) =>
      service.configure(
        folder: automaticFolder,
        paused: paused,
        traditional: App.locale.countryCode == 'TW',
        sourceTypesJson: _sourceTypes,
      );

  static Future<void> configure() async {
    if (restoring) return;
    final service = await _service();
    if (!restoring) await _configure(service);
  }

  /// Await before closing/replacing the favorite database during a restore.
  static Future<void> close() async {
    final opening = _opening;
    _opening = null;
    if (opening == null) return;
    final service = await opening;
    await service.close();
    service.dispose();
  }
}

/// A page can cancel this handle while the native task is being created.
class UpdateSession {
  final String folder;
  final bool force;
  final bool metadataOnly;
  final List<Map<String, dynamic>>? keys;
  backend.FollowUpdateTask? _task;
  bool _cancelled = false;

  UpdateSession(
    this.folder,
    this.force, {
    this.keys,
    this.metadataOnly = false,
  });

  void cancel() {
    _cancelled = true;
    _task?.cancel();
  }

  Stream<UpdateProgress> get progress async* {
    final service = await FollowUpdatesBackend._service();
    if (_cancelled) return;
    final task = metadataOnly
        ? await service.refreshMetadata(folder: folder)
        : await service.start(
            folder: folder,
            force: force,
            keysJson: keys == null ? null : jsonEncode(keys),
          );
    _task = task;
    try {
      if (_cancelled) task.cancel();
      while (true) {
        final snapshot = await task.nextSnapshot();
        if (snapshot == null) break;
        final progress = UpdateProgress.fromJson(jsonDecode(snapshot));
        yield progress;
        if (progress.isDone) {
          if (progress.status == 'failed') {
            throw StateError(progress.errorMessage ?? 'Update check failed');
          }
          break;
        }
      }
    } finally {
      task.cancel();
      await task.wait();
      _task = null;
      task.dispose();
      if (!FollowUpdatesBackend.restoring) {
        LocalFavoritesManager().notifyChanges();
      }
    }
  }
}

Stream<UpdateProgress> updateFolder(String folder, bool ignoreCheckTime) =>
    UpdateSession(folder, ignoreCheckTime).progress;

Future<ComicUpdateResult> updateComic(
  FavoriteItemWithUpdateInfo comic,
  String folder,
) async {
  UpdateProgress? result;
  await for (final progress in UpdateSession(
    folder,
    true,
    keys: [
      {'id': comic.id, 'type': comic.type.value},
    ],
  ).progress) {
    result = progress;
  }
  return ComicUpdateResult((result?.updated ?? 0) > 0, result?.errorMessage);
}

Future<String> getUpdatedComicsAsJson(String folder) async => jsonEncode(
  LocalFavoritesManager()
      .getUpdates(folder)
      .map(
        (comic) => {
          'id': comic.id,
          'name': comic.name,
          'coverUrl': comic.coverPath,
          'author': comic.author,
          'type': comic.type.sourceKey,
          'updateTime': comic.updateTime,
          'tags': comic.tags,
        },
      )
      .toList(),
);
