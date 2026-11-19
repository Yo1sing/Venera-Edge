library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:venera_edge/src/rust/api/script.dart' as script_backend;
import 'package:venera_edge/src/rust/api/sources.dart' as sources_backend;
import 'package:venera_edge/src/rust/api/http.dart' show HttpCancellation;
import 'package:venera_edge/src/rust/api/follow_updates.dart' as follow_backend;
import 'package:venera_edge/foundation/source_data.dart';
import 'package:venera_edge/foundation/app.dart';
import 'package:venera_edge/foundation/appdata.dart';
import 'package:venera_edge/foundation/comic_type.dart';
import 'package:venera_edge/foundation/history.dart';
import 'package:venera_edge/foundation/res.dart';
import 'package:venera_edge/pages/category_comics_page.dart';
import 'package:venera_edge/pages/search_result_page.dart';
import 'package:venera_edge/utils/data_sync.dart';
import 'package:venera_edge/utils/ext.dart';
import 'package:venera_edge/utils/init.dart';

import '../js_engine.dart';
import '../log.dart';

part 'category.dart';

part 'favorites.dart';

part 'parser.dart';

part 'models.dart';

part 'types.dart';

class ComicSourceManager with ChangeNotifier, Init {
  final List<ComicSource> _sources = [];
  late sources_backend.SourceManager _backend;

  static ComicSourceManager? _instance;

  ComicSourceManager._create();

  factory ComicSourceManager() => _instance ??= ComicSourceManager._create();

  List<ComicSource> installed() => List.of(_sources);

  /// Sources currently available for browsing and update tracking.
  List<ComicSource> all() => _sources.where((source) => source.isEnabled).toList();

  ComicSource? find(String key) =>
      _sources.firstWhereOrNull((element) => element.key == key);

  ComicSource? fromIntKey(int key) =>
      _sources.firstWhereOrNull((element) => element.key.hashCode == key);

  @override
  @protected
  Future<void> doInit() async {
    await appdata.ensureInit();
    await JsEngine().ensureInit();
    _backend = await sources_backend.SourceManager.open(
      runtime: JsEngine().runtime,
    );
    await reload();
    await appdata.saveData(false);
  }

  Future<void> reload() async {
    final cancellation = HttpCancellation();
    try {
      final result = jsonDecode(
        await _backend.load(cancellation: cancellation),
      );
      for (final error in result['errors']) {
        Log.error('ComicSource', error);
      }
      await _refresh();
    } finally {
      cancellation.dispose();
    }
  }

  Future<void> _refresh({String? added}) async {
    while (true) {
      final encoded = _backend.snapshot();
      final snapshot = jsonDecode(encoded);
      final sources = <ComicSource>[];
      try {
        for (final metadata in snapshot['sources']) {
          sources.add(
            await ComicSourceParser().fromMetadata(
              Map<String, dynamic>.from(metadata),
            ),
          );
        }
      } catch (_) {
        if (_backend.snapshot() != encoded) continue;
        rethrow;
      }
      if (_backend.snapshot() != encoded) continue;
      _sources
        ..clear()
        ..addAll(sources);
      _availableUpdates = Map<String, String>.from(snapshot['updates']);
      final pages =
          jsonDecode(
                _backend.reconcilePages(
                  settingsJson: jsonEncode(appdata.toJson()['settings']),
                  added: added,
                ),
              )
              as Map<String, dynamic>;
      for (final entry in pages.entries) {
        appdata.settings[entry.key] = entry.value;
      }
      notifyListeners();
      return;
    }
  }

  Future<void> _apply(Future<String> operation, {bool added = false}) async {
    final metadata = jsonDecode(await operation);
    await _refresh(added: added ? metadata['key'] : null);
    await appdata.saveData(false);
    DataSync().onDataChanged();
  }

  Future<void> installUrl(String url, HttpCancellation cancellation) => _apply(
    _backend.installUrl(url: url, cancellation: cancellation),
    added: true,
  );

  Future<void> install(
    List<int> code,
    String name,
    HttpCancellation cancellation,
  ) => _apply(
    _backend.install(code: code, name: name, cancellation: cancellation),
    added: true,
  );

  Future<void> update(String key, HttpCancellation cancellation) =>
      _apply(_backend.update(key: key, cancellation: cancellation));

  Future<void> save(String key, String code, HttpCancellation cancellation) =>
      _apply(_backend.save(key: key, code: code, cancellation: cancellation));

  Future<String> read(String key) => _backend.read(key: key);
  Future<String> beginEdit(String key) => _backend.beginEdit(key: key);
  Future<void> saveEdit(
    String key,
    String path,
    HttpCancellation cancellation,
  ) => _apply(
    _backend.saveEdit(key: key, path: path, cancellation: cancellation),
  );
  Future<void> discardEdit(String path) => _backend.discardEdit(path: path);

  Future<void> remove(String key, HttpCancellation cancellation) async {
    await _backend.remove(key: key, cancellation: cancellation);
    await _refresh();
    await appdata.saveData(false);
    DataSync().onDataChanged();
  }

  Future<List<dynamic>> catalog(
    String url,
    HttpCancellation cancellation,
  ) async =>
      jsonDecode(await _backend.catalog(url: url, cancellation: cancellation));

  Future<int> checkUpdates(
    List<String> urls,
    HttpCancellation cancellation,
  ) async {
    _availableUpdates = Map<String, String>.from(
      jsonDecode(
        await _backend.checkUpdates(urls: urls, cancellation: cancellation),
      ),
    );
    notifyListeners();
    return _availableUpdates.length;
  }

  bool get isEmpty => !_sources.any((source) => source.isEnabled);

  /// Key is the source key, value is the version.
  Map<String, String> _availableUpdates = {};

  Map<String, String> get availableUpdates => Map.from(_availableUpdates);

  void notifyStateChange() {
    notifyListeners();
  }
}

class ComicSource {
  static List<ComicSource> all() => ComicSourceManager().all();

  static List<ComicSource> installed() => ComicSourceManager().installed();

  // Keep lookups by identity available for management and local records.
  static ComicSource? find(String key) => ComicSourceManager().find(key);

  static ComicSource? fromIntKey(int key) =>
      ComicSourceManager().fromIntKey(key);

  static bool get isEmpty => ComicSourceManager().isEmpty;

  /// Name of this source.
  final String name;

  /// Identifier of this source.
  final String key;

  bool get isEnabled => appdata.settings.isComicSourceEnabled(key);

  int get intKey {
    return key.hashCode;
  }

  /// Account config.
  final AccountConfig? account;

  /// Category data used to build a static category tags page.
  final CategoryData? categoryData;

  /// Category comics data used to build a comics page with a category tag.
  final CategoryComicsData? categoryComicsData;

  /// Favorite data used to build favorite page.
  final FavoriteData? favoriteData;

  /// Explore pages.
  final List<ExplorePageData> explorePages;

  /// Search page.
  final SearchPageData? searchPageData;

  /// Load comic info.
  final LoadComicFunc? loadComicInfo;

  final ComicThumbnailLoader? loadComicThumbnail;

  /// Load comic pages.
  final LoadComicPagesFunc? loadComicPages;

  final GetImageLoadingConfigFunc? getImageLoadingConfig;

  final Map<String, dynamic> Function(String imageKey)?
  getThumbnailLoadingConfig;

  late final _sourceData = SourceData(key);
  Map<String, dynamic> get data => _sourceData.snapshot;
  void setData(String field, Object? value) => _sourceData.set(field, value);

  bool get isLogged => data["account"] != null;

  final String filePath;

  final String url;

  final String version;

  final CommentsLoader? commentsLoader;

  final SendCommentFunc? sendCommentFunc;

  final ChapterCommentsLoader? chapterCommentsLoader;

  final SendChapterCommentFunc? sendChapterCommentFunc;

  final RegExp? idMatcher;

  final LikeOrUnlikeComicFunc? likeOrUnlikeComic;

  final VoteCommentFunc? voteCommentFunc;

  final LikeCommentFunc? likeCommentFunc;

  final Map<String, Map<String, String>>? translations;

  final HandleClickTagEvent? handleClickTagEvent;

  /// Callback when a tag suggestion is selected in search.
  final TagSuggestionSelectFunc? onTagSuggestionSelected;

  final LinkHandler? linkHandler;

  final bool enableTagsSuggestions;

  final bool enableTagsTranslate;

  final StarRatingFunc? starRatingFunc;

  final ArchiveDownloader? archiveDownloader;

  Future<void> loadData() async {
    script_backend.loadSourceData(directory: App.dataPath, key: key);
  }

  Future<void> saveData() async {
    // Map/list mutations have already been persisted by the Rust source store.
    DataSync().onDataChanged();
  }

  Future<bool> reLogin() async =>
      await JsEngine().runCode('__sources.reLogin(${jsonEncode(key)})');

  /// Returns the currently installed script's dynamic setting descriptors and
  /// the effective values resolved by the Rust source store.
  Map<String, Map<String, dynamic>> getSettingsDynamic() {
    final value = JsEngine().runCode(
      '__venera.sourceSettings(${jsonEncode(key)})',
    );
    return (value as Map).map((key, value) {
      final field = Map<String, dynamic>.from(value as Map);
      final callback = field['callback'];
      if (callback is JSInvokable) {
        field['callback'] = JSAutoFreeFunction(callback);
      }
      return MapEntry(key as String, field);
    });
  }

  void setSourceSetting(String setting, Object? value) {
    JsEngine().runtime.editSourceSetting(
      key: key,
      setting: setting,
      valueJson: jsonEncode(value),
    );
  }

  void resetSourceSetting(String setting) {
    JsEngine().runtime.editSourceSetting(key: key, setting: setting);
  }

  ComicSource(
    this.name,
    this.key,
    this.account,
    this.categoryData,
    this.categoryComicsData,
    this.favoriteData,
    this.explorePages,
    this.searchPageData,
    this.loadComicInfo,
    this.loadComicThumbnail,
    this.loadComicPages,
    this.getImageLoadingConfig,
    this.getThumbnailLoadingConfig,
    this.filePath,
    this.url,
    this.version,
    this.commentsLoader,
    this.sendCommentFunc,
    this.chapterCommentsLoader,
    this.sendChapterCommentFunc,
    this.likeOrUnlikeComic,
    this.voteCommentFunc,
    this.likeCommentFunc,
    this.idMatcher,
    this.translations,
    this.handleClickTagEvent,
    this.onTagSuggestionSelected,
    this.linkHandler,
    this.enableTagsSuggestions,
    this.enableTagsTranslate,
    this.starRatingFunc,
    this.archiveDownloader,
  );
}

class AccountConfig {
  final LoginFunction? login;

  final String? loginWebsite;

  final String? registerWebsite;

  final void Function() logout;

  final List<AccountInfoItem> infoItems;

  final bool Function(String url, String title)? checkLoginStatus;

  final void Function()? onLoginWithWebviewSuccess;

  final List<String>? cookieFields;

  final Future<bool> Function(List<String>)? validateCookies;

  const AccountConfig(
    this.login,
    this.loginWebsite,
    this.registerWebsite,
    this.logout,
    this.checkLoginStatus,
    this.onLoginWithWebviewSuccess,
    this.cookieFields,
    this.validateCookies,
  ) : infoItems = const [];
}

class AccountInfoItem {
  final String title;
  final String Function()? data;
  final void Function()? onTap;
  final WidgetBuilder? builder;

  AccountInfoItem({required this.title, this.data, this.onTap, this.builder});
}

class LoadImageRequest {
  String url;

  Map<String, String> headers;

  LoadImageRequest(this.url, this.headers);
}

class ExplorePageData {
  final String title;

  final ExplorePageType type;

  final ComicListBuilder? loadPage;

  final ComicListBuilderWithNext? loadNext;

  final Future<Res<List<ExplorePagePart>>> Function()? loadMultiPart;

  /// return a `List` contains `List<Comic>` or `ExplorePagePart`
  final Future<Res<List<Object>>> Function(int index)? loadMixed;

  ExplorePageData(
    this.title,
    this.type,
    this.loadPage,
    this.loadNext,
    this.loadMultiPart,
    this.loadMixed,
  );
}

class ExplorePagePart {
  final String title;

  final List<Comic> comics;

  /// If this is not null, the [ExplorePagePart] will show a button to jump to new page.
  ///
  /// Value of this field should match the following format:
  ///   - search:keyword
  ///   - category:categoryName
  ///
  /// End with `@`+`param` if the category has a parameter.
  final PageJumpTarget? viewMore;

  const ExplorePagePart(this.title, this.comics, this.viewMore);
}

enum ExplorePageType {
  multiPageComicList,
  singlePageWithMultiPart,
  mixed,
  override,
}

typedef SearchFunction =
    Future<Res<List<Comic>>> Function(
      String keyword,
      int page,
      List<String> searchOption,
    );

typedef SearchNextFunction =
    Future<Res<List<Comic>>> Function(
      String keyword,
      String? next,
      List<String> searchOption,
    );

class SearchPageData {
  /// If this is not null, the default value of search options will be first element.
  final List<SearchOptions>? searchOptions;

  final SearchFunction? loadPage;

  final SearchNextFunction? loadNext;

  const SearchPageData(this.searchOptions, this.loadPage, this.loadNext);
}

class SearchOptions {
  final LinkedHashMap<String, String> options;

  final String label;

  final String type;

  final String? defaultVal;

  const SearchOptions(this.options, this.label, this.type, this.defaultVal);

  String get defaultValue => defaultVal ?? options.keys.firstOrNull ?? "";
}

typedef CategoryComicsLoader =
    Future<Res<List<Comic>>> Function(
      String category,
      String? param,
      List<String> options,
      int page,
    );

typedef CategoryOptionsLoader =
    Future<Res<List<CategoryComicsOptions>>> Function(
      String category,
      String? param,
    );

class CategoryComicsData {
  /// options
  final List<CategoryComicsOptions>? options;

  final CategoryOptionsLoader? optionsLoader;

  /// [category] is the one clicked by the user on the category page.
  ///
  /// if [BaseCategoryPart.categoryParams] is not null, [param] will be not null.
  ///
  /// [Res.subData] should be maxPage or null if there is no limit.
  final CategoryComicsLoader load;

  final RankingData? rankingData;

  const CategoryComicsData({
    this.options,
    this.optionsLoader,
    required this.load,
    this.rankingData,
  });
}

class RankingData {
  final Map<String, String> options;

  final Future<Res<List<Comic>>> Function(String option, int page)? load;

  final Future<Res<List<Comic>>> Function(String option, String? next)?
  loadWithNext;

  const RankingData(this.options, this.load, this.loadWithNext);
}

class CategoryComicsOptions {
  // The label will not be displayed if it is empty.
  final String label;

  /// Use a [LinkedHashMap] to describe an option list.
  /// key is for loading comics, value is the name displayed on screen.
  /// Default value will be the first of the Map.
  final LinkedHashMap<String, String> options;

  /// If [notShowWhen] contains category's name, the option will not be shown.
  final List<String> notShowWhen;

  final List<String>? showWhen;

  const CategoryComicsOptions(
    this.label,
    this.options,
    this.notShowWhen,
    this.showWhen,
  );
}

class LinkHandler {
  final List<String> domains;

  final String? Function(String url) linkToId;

  const LinkHandler(this.domains, this.linkToId);
}

class ArchiveDownloader {
  final Future<Res<List<ArchiveInfo>>> Function(String cid) getArchives;

  final Future<Res<String>> Function(String cid, String aid) getDownloadUrl;

  const ArchiveDownloader(this.getArchives, this.getDownloadUrl);
}
