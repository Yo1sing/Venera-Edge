import 'dart:convert';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/js_engine.dart';

import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:path_provider/path_provider.dart';
import 'package:venera/src/rust/api/local.dart' as backend;
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/download.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/io.dart';

import 'app.dart';
import 'history.dart';

class LocalComic with HistoryMixin implements Comic {
  @override
  final String id;

  @override
  final String title;

  @override
  final String subtitle;

  @override
  final List<String> tags;

  /// The name of the directory where the comic is stored
  final String directory;

  /// key: chapter id, value: chapter title
  ///
  /// chapter id is the name of the directory in `LocalManager.path/$directory`
  final ComicChapters? chapters;

  bool get hasChapters => chapters != null;

  /// relative path to the cover image
  @override
  final String cover;

  final ComicType comicType;

  final List<String> downloadedChapters;

  final DateTime createdAt;

  const LocalComic({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.tags,
    required this.directory,
    required this.chapters,
    required this.cover,
    required this.comicType,
    required this.downloadedChapters,
    required this.createdAt,
  });

  LocalComic.fromBackend(Map<String, dynamic> row)
    : id = row['id'],
      title = row['title'],
      subtitle = row['subtitle'],
      tags = List<String>.from(row['tags']),
      directory = row['directory'],
      chapters = ComicChapters.fromJsonOrNull(row['chapters']),
      cover = row['cover'],
      comicType = ComicType(row['comic_type']),
      downloadedChapters = List<String>.from(row['downloaded_chapters']),
      createdAt = DateTime.fromMillisecondsSinceEpoch(row['created_at']);

  Map<String, dynamic> toBackend() => {
    'id': id,
    'title': title,
    'subtitle': subtitle,
    'tags': tags,
    'directory': directory,
    'chapters': chapters?.toJson(),
    'cover': cover,
    'comic_type': comicType.value,
    'downloaded_chapters': downloadedChapters,
    'created_at': createdAt.millisecondsSinceEpoch,
  };

  File get coverFile => File(FilePath.join(baseDir, cover));

  String get baseDir => (directory.contains('/') || directory.contains('\\'))
      ? directory
      : FilePath.join(LocalManager().path, directory);

  @override
  String get description => "";

  @override
  String get sourceKey =>
      comicType == ComicType.local ? "local" : comicType.sourceKey;

  @override
  Map<String, dynamic> toJson() {
    return {
      "title": title,
      "cover": cover,
      "id": id,
      "subTitle": subtitle,
      "tags": tags,
      "description": description,
      "sourceKey": sourceKey,
      "chapters": chapters?.toJson(),
    };
  }

  @override
  int? get maxPage => null;

  void read() {
    var history = HistoryManager().find(id, comicType);
    int? firstDownloadedChapter;
    int? firstDownloadedChapterGroup;
    if (downloadedChapters.isNotEmpty && chapters != null) {
      final chapters = this.chapters!;
      if (chapters.isGrouped) {
        for (int i = 0; i < chapters.groupCount; i++) {
          var group = chapters.getGroupByIndex(i);
          var keys = group.keys.toList();
          for (int j = 0; j < keys.length; j++) {
            var chapterId = keys[j];
            if (downloadedChapters.contains(chapterId)) {
              firstDownloadedChapter = j + 1;
              firstDownloadedChapterGroup = i + 1;
              break;
            }
          }
        }
      } else {
        var keys = chapters.allChapters.keys;
        for (int i = 0; i < keys.length; i++) {
          if (downloadedChapters.contains(keys.elementAt(i))) {
            firstDownloadedChapter = i + 1;
            break;
          }
        }
      }
    }
    App.rootContext.to(
      () => Reader(
        type: comicType,
        cid: id,
        name: title,
        chapters: chapters,
        initialChapter: history?.ep ?? firstDownloadedChapter,
        initialPage: history?.page,
        initialChapterGroup: history?.group ?? firstDownloadedChapterGroup,
        history: history ?? History.fromModel(model: this, ep: 0, page: 0),
        author: subtitle,
        tags: tags,
      ),
    );
  }

  @override
  HistoryType get historyType => comicType;

  @override
  String? get subTitle => subtitle;

  @override
  String? get language => null;

  @override
  String? get favoriteId => null;

  @override
  double? get stars => null;
}

class LocalManager with ChangeNotifier {
  static LocalManager? _instance;

  LocalManager._();

  factory LocalManager() {
    return _instance ??= LocalManager._();
  }

  late backend.LocalStore _store;

  /// path to the directory where all the comics are stored
  late String path;

  Directory get directory => Directory(path);

  void _checkNoMedia() {
    if (App.isAndroid) {
      var file = File(FilePath.join(path, '.nomedia'));
      if (!file.existsSync()) {
        file.createSync();
      }
    }
  }

  // return error message if failed
  Future<String?> setNewPath(String newPath) async {
    var newDir = Directory(newPath);
    if (!await newDir.exists()) {
      return "Directory does not exist";
    }
    if (!await newDir.list().isEmpty) {
      return "Directory is not empty";
    }
    try {
      await copyDirectoryIsolate(directory, newDir);
      await File(
        FilePath.join(App.dataPath, 'local_path'),
      ).writeAsString(newPath);
    } catch (e, s) {
      Log.error("IO", e, s);
      return e.toString();
    }
    await directory.deleteContents(recursive: true);
    path = newPath;
    _checkNoMedia();
    return null;
  }

  Future<String> findDefaultPath() async {
    if (App.isAndroid) {
      var external = await getExternalStorageDirectories();
      if (external != null && external.isNotEmpty) {
        return FilePath.join(external.first.path, 'local');
      } else {
        return FilePath.join(App.dataPath, 'local');
      }
    } else if (App.isIOS) {
      var oldPath = FilePath.join(App.dataPath, 'local');
      if (Directory(oldPath).existsSync() &&
          Directory(oldPath).listSync().isNotEmpty) {
        return oldPath;
      } else {
        var directory = await getApplicationDocumentsDirectory();
        return FilePath.join(directory.path, 'local');
      }
    } else {
      return FilePath.join(App.dataPath, 'local');
    }
  }

  Future<void> _checkPathValidation() async {
    var testFile = File(FilePath.join(path, 'venera_test'));
    try {
      testFile.createSync();
      testFile.deleteSync();
    } catch (e) {
      Log.error(
        "IO",
        "Failed to create test file in local path: $e\nUsing default path instead.",
      );
      path = await findDefaultPath();
    }
  }

  Future<void> init() async {
    _store = await backend.LocalStore.open(path: '${App.dataPath}/local.db');
    if (File(FilePath.join(App.dataPath, 'local_path')).existsSync()) {
      path = File(FilePath.join(App.dataPath, 'local_path')).readAsStringSync();
      if (!directory.existsSync()) {
        path = await findDefaultPath();
      }
    } else {
      path = await findDefaultPath();
    }
    try {
      if (!directory.existsSync()) {
        await directory.create();
      }
    } catch (e, s) {
      Log.error("IO", "Failed to create local folder: $e", s);
    }
    await _checkPathValidation();
    _checkNoMedia();
    await ComicSourceManager().ensureInit();
  }

  List<LocalComic> _comics(String json) => (jsonDecode(json) as List)
      .map((row) => LocalComic.fromBackend(Map<String, dynamic>.from(row)))
      .toList();
  List<LocalComic> getComics(LocalSortType sortType) =>
      _comics(_store.list(sort: sortType.value));
  LocalComic? find(String id, ComicType comicType) {
    final json = _store.find(id: id, comicType: comicType.value);
    return json == null ? null : LocalComic.fromBackend(jsonDecode(json));
  }

  @override
  void dispose() {
    _store.close();
    _store.dispose();
    super.dispose();
  }

  List<LocalComic> getRecent() =>
      _comics(_store.list(sort: 'time_desc', limit: 20));
  int get count => _store.count();
  LocalComic? findByName(String name) {
    final json = _store.findName(name: name);
    return json == null ? null : LocalComic.fromBackend(jsonDecode(json));
  }

  List<LocalComic> search(String keyword) =>
      _comics(_store.list(sort: 'time_desc', keyword: keyword));

  Future<List<String>> getImages(String id, ComicType type, Object ep) async {
    final result = await runOperation({
      'mode': 'images',
      'id': id,
      'type': type.value,
      'episode': ep,
    }, showProgress: false);
    final errors = result['errors'] as List;
    if (errors.isNotEmpty) throw StateError(errors.first['error']);
    return List<String>.from(result['images']);
  }

  bool isDownloaded(
    String id,
    ComicType type, [
    int? ep,
    ComicChapters? chapters,
  ]) => _store.downloaded(
    id: id,
    comicType: type.value,
    episode: ep,
    chaptersJson: chapters == null ? null : jsonEncode(chapters.toJson()),
  );

  List<DownloadTask> downloadingTasks = [];

  bool isDownloading(String id, ComicType type) {
    return downloadingTasks.any(
      (element) => element.id == id && element.comicType == type,
    );
  }

  void applyDownloadSnapshot(List<DownloadTask> tasks) {
    downloadingTasks = tasks;
    notifyListeners();
  }

  void removeTask(DownloadTask task) => task.cancel();
  void moveToFirst(DownloadTask task) =>
      DownloadQueueView.command(task.queueKey, 'first');
  Future<void> restoreDownloadingTasks() => DownloadQueueView.initialize();
  void addTask(DownloadTask task) => DownloadQueueView.add(task);

  Future<Map<String, dynamic>> runOperation(
    Map<String, dynamic> request, {
    bool showProgress = true,
  }) async {
    final operation = await backend.LocalOperation.start(
      runtime: JsEngine().runtime,
      optionsJson: jsonEncode({
        'data_path': App.dataPath,
        'cache_path': App.cachePath,
        'local_path': path,
        'traditional': App.locale.countryCode == 'TW',
        'at_end': appdata.settings['newFavoriteAddTo'] == 'end',
      }),
      requestJson: jsonEncode(request),
    );
    final controller = showProgress
        ? showLoadingDialog(
            App.rootContext,
            barrierDismissible: false,
            onCancel: operation.cancel,
          )
        : null;
    try {
      while (true) {
        final encoded = await operation.next();
        if (encoded == null) throw StateError('Missing local operation result');
        final event = jsonDecode(encoded);
        if (event['kind'] == 'progress') {
          controller?.setMessage(event['path']);
          continue;
        }
        final result = Map<String, dynamic>.from(event['result']);
        if (request['mode'] != 'images' && request['mode'] != 'recover') {
          notifyListeners();
          LocalFavoritesManager().initCounts();
          HistoryManager().notifyExternalChanges();
        }
        final errors = result['errors'] as List;
        if (errors.isNotEmpty) {
          final message = errors
              .map((error) {
                final target = error['path'] ?? error['id'];
                return target == null
                    ? '${error['error']}'
                    : '$target\n${error['error']}';
              })
              .join('\n');
          Log.error('Local Comics', message);
          if (showProgress) {
            controller?.close();
            App.rootContext.showMessage(message: message);
          }
        }
        return result;
      }
    } finally {
      controller?.close();
      operation.cancel();
      operation.dispose();
    }
  }

  Future<bool> deleteComic(
    LocalComic comic, [
    bool removeFileOnDisk = true,
  ]) async {
    final result = await runOperation({
      'mode': 'delete',
      'keys': [
        {'id': comic.id, 'type': comic.comicType.value},
      ],
      'remove_files': removeFileOnDisk,
      'local_only': true,
    });
    return (result['removed'] as List).isNotEmpty;
  }

  Future<bool> deleteComicChapters(
    LocalComic comic,
    List<String> chapters,
  ) async {
    if (chapters.isEmpty) return false;
    final result = await runOperation({
      'mode': 'chapters',
      'keys': [
        {'id': comic.id, 'type': comic.comicType.value},
      ],
      'chapters': chapters,
    });
    return (result['removed'] as List).isNotEmpty;
  }

  Future<bool> batchDeleteComics(
    List<LocalComic> comics, [
    bool removeFileOnDisk = true,
    bool removeFavoriteAndHistory = true,
  ]) async {
    if (comics.isEmpty) return false;
    final result = await runOperation({
      'mode': 'delete',
      'keys': comics
          .map((comic) => {'id': comic.id, 'type': comic.comicType.value})
          .toList(),
      'remove_files': removeFileOnDisk,
      'clear_associations': removeFavoriteAndHistory,
    });
    return (result['removed'] as List).isNotEmpty;
  }

  static String getChapterDirectoryName(String name) =>
      backend.chapterDirectoryName(name: name);
}

enum LocalSortType {
  name("name"),
  timeAsc("time_asc"),
  timeDesc("time_desc");

  final String value;

  const LocalSortType(this.value);

  static LocalSortType fromString(String value) {
    for (var type in values) {
      if (type.value == value) {
        return type;
      }
    }
    return name;
  }
}
