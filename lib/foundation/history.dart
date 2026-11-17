import 'dart:async';
import 'package:venera/src/rust/api/history.dart' as backend;
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/image_provider/image_favorites_provider.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/utils/translations.dart';

import 'app.dart';
import 'consts.dart';

part "image_favorites.dart";

typedef HistoryType = ComicType;

abstract mixin class HistoryMixin {
  String get title;

  String? get subTitle;

  String get cover;

  String get id;

  int? get maxPage => null;

  HistoryType get historyType;
}

class History implements Comic {
  HistoryType type;

  DateTime time;

  @override
  String title;

  @override
  String subtitle;

  @override
  String cover;

  /// index of chapters. 1-based.
  int ep;

  /// index of pages. 1-based.
  int page;

  /// index of chapter groups. 1-based.
  /// If [group] is not null, [ep] is the index of chapter in the group.
  int? group;

  @override
  String id;

  /// readEpisode is a set of episode numbers that have been read.
  /// For normal chapters, it is a set of chapter numbers.
  /// For grouped chapters, it is a set of strings in the format of "group_number-chapter_number".
  /// 1-based.
  Set<String> readEpisode;

  @override
  int? maxPage;

  History.fromModel({
    required HistoryMixin model,
    required this.ep,
    required this.page,
    this.group,
    Set<String>? readChapters,
    DateTime? time,
  }) : type = model.historyType,
       title = model.title,
       subtitle = model.subTitle ?? '',
       cover = model.cover,
       id = model.id,
       readEpisode = readChapters ?? <String>{},
       time = time ?? DateTime.now();

  History.fromMap(Map<String, dynamic> map)
    : type = HistoryType(map["type"]),
      time = DateTime.fromMillisecondsSinceEpoch(map["time"]),
      title = map["title"],
      subtitle = map["subtitle"],
      cover = map["cover"],
      ep = map["ep"],
      page = map["page"],
      id = map["id"],
      readEpisode = Set<String>.from(
        (map["readEpisode"] as List<dynamic>?)?.toSet() ?? const <String>{},
      ),
      maxPage = map["max_page"];

  @override
  String toString() {
    return 'History{type: $type, time: $time, title: $title, subtitle: $subtitle, cover: $cover, ep: $ep, page: $page, id: $id}';
  }

  @override
  bool operator ==(Object other) {
    return other is History && type == other.type && id == other.id;
  }

  @override
  int get hashCode => Object.hash(id, type);

  @override
  String get description {
    var res = "";
    if (group != null) {
      res += "${"Group @group".tlParams({"group": group!})} - ";
    }
    if (ep >= 1) {
      res += "Chapter @ep".tlParams({"ep": ep});
    }
    if (page >= 1) {
      if (ep >= 1) {
        res += " - ";
      }
      res += "Page @page".tlParams({"page": page});
    }
    return res;
  }

  @override
  String? get favoriteId => null;

  @override
  String? get language => null;

  @override
  String get sourceKey => type == ComicType.local
      ? 'local'
      : type.comicSource?.key ?? "Unknown:${type.value}";

  @override
  double? get stars => null;

  @override
  List<String>? get tags => null;

  @override
  Map<String, dynamic> toJson() {
    throw UnimplementedError();
  }
}

class HistoryManager with ChangeNotifier {
  static HistoryManager? cache;

  HistoryManager.create();

  factory HistoryManager() =>
      cache == null ? (cache = HistoryManager.create()) : cache!;

  late backend.HistoryStore _store;
  bool isInitialized = false;
  final cachedHistories = <String, History>{};
  int get length => _store.count();

  Future<void> init() async {
    if (isInitialized) return;
    _store = await backend.HistoryStore.open(
      path: '${App.dataPath}/history.db',
    );
    isInitialized = true;
    ImageFavoriteManager().init();
    notifyListeners();
  }

  backend.HistoryEntry _toBackend(History item) => backend.HistoryEntry(
    id: item.id,
    title: item.title,
    subtitle: item.subtitle,
    cover: item.cover,
    timeMs: item.time.millisecondsSinceEpoch,
    comicType: item.type.value,
    episode: item.ep,
    page: item.page,
    readEpisodes: item.readEpisode.toList(),
    maxPage: item.maxPage,
    chapterGroup: item.group,
  );

  History _fromBackend(backend.HistoryEntry item) => History.fromMap({
    'id': item.id,
    'title': item.title,
    'subtitle': item.subtitle,
    'cover': item.cover,
    'time': item.timeMs,
    'type': item.comicType,
    'ep': item.episode,
    'page': item.page,
    'readEpisode': item.readEpisodes,
    'max_page': item.maxPage,
  })..group = item.chapterGroup;

  Future<void> addHistoryAsync(History newItem) async {
    await _store.save(entry: _toBackend(newItem));
    notifyListeners();
  }

  void addHistory(History newItem) {
    _store.saveSync(entry: _toBackend(newItem));
    notifyListeners();
  }

  void clearHistory() {
    _store.clear();
    updateCache();
    notifyListeners();
  }

  void clearUnfavoritedHistory() {
    final keys = getAll()
        .where((item) => !LocalFavoritesManager().isExist(item.id, item.type))
        .map(
          (item) => backend.ComicKey(id: item.id, comicType: item.type.value),
        )
        .toList();
    _store.delete(keys: keys);
    updateCache();
    notifyListeners();
  }

  void remove(String id, ComicType type) {
    _store.delete(
      keys: [backend.ComicKey(id: id, comicType: type.value)],
    );
    updateCache();
    notifyListeners();
  }

  void updateCache() => cachedHistories.clear();

  void notifyExternalChanges() {
    updateCache();
    notifyListeners();
  }

  History? find(String id, ComicType type) {
    final entry = _store.find(id: id, comicType: type.value);
    return entry == null ? null : _fromBackend(entry);
  }

  List<History> getAll() => _store.list().map(_fromBackend).toList();
  List<History> getRecent() =>
      _store.list(limit: 20).map(_fromBackend).toList();
  int count() => _store.count();

  void close() {
    _store.close();
    isInitialized = false;
    updateCache();
  }

  void batchDeleteHistories(List<ComicID> histories) {
    _store.delete(
      keys: histories
          .map(
            (item) => backend.ComicKey(id: item.id, comicType: item.type.value),
          )
          .toList(),
    );
    updateCache();
    notifyListeners();
  }

  Future<backend.HistoryRefreshTask> startMetadataRefresh([History? history]) =>
      _store.refreshMetadata(
        runtime: JsEngine().runtime,
        sourcesJson: jsonEncode({
          for (final source in ComicSource.all())
            if (source.loadComicInfo != null)
              source.intKey.toString(): source.key,
        }),
        key: history == null
            ? null
            : backend.ComicKey(id: history.id, comicType: history.type.value),
      );

  Future<bool> refreshHistoryInfo(History history) async {
    final task = await startMetadataRefresh(history);
    try {
      var success = false;
      while (true) {
        final progress = await task.next();
        if (progress == null) break;
        success = progress.success != 0;
      }
      if (success) notifyExternalChanges();
      return success;
    } finally {
      task.dispose();
    }
  }
}
