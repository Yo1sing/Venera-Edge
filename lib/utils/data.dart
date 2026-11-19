import 'dart:convert';

import 'package:venera_edge/foundation/app.dart';
import 'package:venera_edge/foundation/appdata.dart';
import 'package:venera_edge/foundation/comic_source/comic_source.dart';
import 'package:venera_edge/foundation/favorites.dart';
import 'package:venera_edge/foundation/follow_updates.dart';
import 'package:venera_edge/foundation/history.dart';
import 'package:venera_edge/foundation/log.dart';
import 'package:venera_edge/utils/data_sync.dart';
import 'package:venera_edge/src/rust/api/backup.dart' as backend;

import 'io.dart';

Future<File> exportAppData([bool sync = true]) async => File(
  await backend.exportAppData(
    directory: App.dataPath,
    cache: App.cachePath,
    sync_: sync,
  ),
);

Future<void> importAppData(File file) => DataSync().importBackup(file.path);

Future<void> applyScheduledBackup(
  backend.SyncController controller,
  int id,
  void Function() refreshFavorites,
) async {
  final wasPaused = FollowUpdatesBackend.paused;
  FollowUpdatesBackend.restoring = true;
  FollowUpdatesBackend.paused = true;
  try {
    await FollowUpdatesBackend.close();
    final result = await appdata.applyRestoredData(
      () async => jsonDecode(await controller.applyRestore(id: id)),
    );
    HistoryManager().notifyExternalChanges();
    refreshFavorites();
    if (result['sourcesChanged'] == true) await ComicSourceManager().reload();
    final folder = appdata.settings['followUpdatesFolder'];
    if (folder is String) {
      if (LocalFavoritesManager().existsFolder(folder)) {
        LocalFavoritesManager().prepareTableForFollowUpdates(folder, false);
      } else {
        appdata.settings['followUpdatesFolder'] = null;
      }
    }
    try {
      await appdata.saveData();
    } on SettingsEditsRejected catch (error, stack) {
      // The backup is already applied. Conflicting UI edits were rejected.
      Log.error('Appdata', error, stack);
    }
  } finally {
    FollowUpdatesBackend.paused = wasPaused;
    FollowUpdatesBackend.restoring = false;
    try {
      await FollowUpdatesBackend.configure();
    } catch (error, stack) {
      Log.error('Check Updates', error, stack);
    }
  }
}

Future<void> importPicaData(File file) async {
  await backend.importPicaData(
    input: file.path,
    cache: App.cachePath,
    directory: App.dataPath,
    sourceTypesJson: jsonEncode({
      for (final key in [
        'picacg',
        'ehentai',
        'jm',
        'hitomi',
        'wnacg',
        'nhentai',
      ])
        key: key.hashCode,
    }),
    installed: ComicSource.installed().map((s) => s.key).toList(),
    traditional: App.locale.countryCode == 'TW',
    atEnd: appdata.settings['newFavoriteAddTo'] == 'end',
  );
  LocalFavoritesManager().initCounts();
  ImageFavoriteManager().init();
}
