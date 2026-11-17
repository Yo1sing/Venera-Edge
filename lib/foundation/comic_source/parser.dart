part of 'comic_source.dart';

class ComicSourceParseException implements Exception {
  final String message;

  ComicSourceParseException(this.message);

  @override
  String toString() {
    return message;
  }
}

class ComicSourceParser {
  /// comic source key
  String? _key;

  String? _name;
  late Map<String, dynamic> _configuration;

  Future<ComicSource> fromMetadata(
    Map<String, dynamic> metadata, {
    Map<String, dynamic>? configuration,
  }) async {
    final String filePath = metadata['file_path'];
    _name = metadata['name'];
    final String key = metadata['key'];
    _key = key;
    _configuration =
        configuration ??
        Map<String, dynamic>.from(
          JsEngine().runCode('__sources.describe(${jsonEncode(key)})'),
        );
    final String version = metadata['version'];
    final String url = metadata['url'];

    var source = ComicSource(
      _name!,
      key,
      _loadAccountConfig(),
      _loadCategoryData(),
      _loadCategoryComicsData(),
      _loadFavoriteData(),
      _loadExploreData(),
      _loadSearchData(),
      _parseLoadComicFunc(),
      _parseThumbnailLoader(),
      _parseLoadComicPagesFunc(),
      _parseImageLoadingConfigFunc(),
      _parseThumbnailLoadingConfigFunc(),
      filePath,
      url,
      version,
      _parseCommentsLoader(),
      _parseSendCommentFunc(),
      _parseChapterCommentsLoader(),
      _parseSendChapterCommentFunc(),
      _parseLikeFunc(),
      _parseVoteCommentFunc(),
      _parseLikeCommentFunc(),
      _parseIdMatch(),
      _parseTranslation(),
      _parseClickTagEvent(),
      _parseTagSuggestionSelectFunc(),
      _parseLinkHandler(),
      _getValue("search.enableTagsSuggestions") ?? false,
      _getValue("comic.enableTagsTranslate") ?? false,
      _parseStarRatingFunc(),
      _parseArchiveDownloader(),
    );

    return source;
  }

  bool _checkExists(String index) => _getValue(index) != null;

  dynamic _getValue(String index) {
    dynamic value = _configuration;
    final segments = index
        .replaceAll('?', '')
        .replaceAll('[', '.')
        .replaceAll(']', '')
        .split('.');
    for (final segment in segments) {
      if (value == null) return null;
      value = value is List ? value[int.parse(segment)] : value[segment];
    }
    return value;
  }

  AccountConfig? _loadAccountConfig() {
    if (!_checkExists("account")) {
      return null;
    }

    Future<Res<bool>> Function(String account, String pwd)? login;

    if (_checkExists("account.login")) {
      login = (account, pwd) async {
        try {
          await JsEngine().runCode("""
          ComicSource.sources[${jsonEncode(_key)}].account.login(${jsonEncode(account)},
          ${jsonEncode(pwd)})
        """);
          return const Res(true);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      };
    }

    void logout() {
      JsEngine().runCode(
        "ComicSource.sources[${jsonEncode(_key)}].account.logout()",
      );
    }

    bool Function(String url, String title)? checkLoginStatus;

    void Function()? onLoginSuccess;

    if (_checkExists('account.loginWithWebview')) {
      checkLoginStatus = (url, title) {
        return JsEngine().runCode("""
            ComicSource.sources[${jsonEncode(_key)}].account.loginWithWebview.checkStatus(
              ${jsonEncode(url)}, ${jsonEncode(title)})
          """);
      };

      if (_checkExists('account.loginWithWebview.onLoginSuccess')) {
        onLoginSuccess = () {
          JsEngine().runCode("""
            ComicSource.sources[${jsonEncode(_key)}].account.loginWithWebview.onLoginSuccess()
          """);
        };
      }
    }

    Future<bool> Function(List<String>)? validateCookies;

    if (_checkExists('account.loginWithCookies?.validate')) {
      validateCookies = (cookies) async {
        try {
          var res = await JsEngine().runCode("""
            ComicSource.sources[${jsonEncode(_key)}].account.loginWithCookies.validate(${jsonEncode(cookies)})
          """);
          return res;
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return false;
        }
      };
    }

    return AccountConfig(
      login,
      _getValue("account.loginWithWebview?.url"),
      _getValue("account.registerWebsite"),
      logout,
      checkLoginStatus,
      onLoginSuccess,
      ListOrNull.from(_getValue("account.loginWithCookies?.fields")),
      validateCookies,
    );
  }

  List<ExplorePageData> _loadExploreData() {
    if (!_checkExists("explore")) {
      return const [];
    }
    final length = (_getValue('explore') as List).length;
    var pages = <ExplorePageData>[];
    for (int i = 0; i < length; i++) {
      final String title = _getValue("explore[$i].title");
      final String type = _getValue("explore[$i].type");
      Future<Res<List<ExplorePagePart>>> Function()? loadMultiPart;
      Future<Res<List<Comic>>> Function(int page)? loadPage;
      Future<Res<List<Comic>>> Function(String? next)? loadNext;
      Future<Res<List<Object>>> Function(int index)? loadMixed;
      if (type == "singlePageWithMultiPart") {
        loadMultiPart = () async {
          try {
            var res = await JsEngine().runCode(
              "ComicSource.sources[${jsonEncode(_key)}].explore[$i].load()",
            );
            return Res(
              List.from(
                res.keys
                    .map(
                      (e) => ExplorePagePart(
                        e,
                        (res[e] as List)
                            .map<Comic>((e) => Comic.fromJson(e, _key!))
                            .toList(),
                        null,
                      ),
                    )
                    .toList(),
              ),
            );
          } catch (e, s) {
            Log.error("Data Analysis", "$e\n$s");
            return Res.error(e.toString());
          }
        };
      } else if (type == "multiPageComicList") {
        if (_checkExists("explore[$i].load")) {
          loadPage = (int page) async {
            try {
              var res = await JsEngine().runCode(
                "ComicSource.sources[${jsonEncode(_key)}].explore[$i].load(${jsonEncode(page)})",
              );
              return Res(
                List.generate(
                  res["comics"].length,
                  (index) => Comic.fromJson(res["comics"][index], _key!),
                ),
                subData: res["maxPage"],
              );
            } catch (e, s) {
              Log.error("Network", "$e\n$s");
              return Res.error(e.toString());
            }
          };
        } else {
          loadNext = (next) async {
            try {
              var res = await JsEngine().runCode(
                "ComicSource.sources[${jsonEncode(_key)}].explore[$i].loadNext(${jsonEncode(next)})",
              );
              return Res(
                List.generate(
                  res["comics"].length,
                  (index) => Comic.fromJson(res["comics"][index], _key!),
                ),
                subData: res["next"],
              );
            } catch (e, s) {
              Log.error("Network", "$e\n$s");
              return Res.error(e.toString());
            }
          };
        }
      } else if (type == "multiPartPage") {
        loadMultiPart = () async {
          try {
            var res = await JsEngine().runCode(
              "ComicSource.sources[${jsonEncode(_key)}].explore[$i].load()",
            );
            return Res(
              List.from(
                (res as List).map((e) {
                  return ExplorePagePart(
                    e['title'],
                    (e['comics'] as List).map((e) {
                      return Comic.fromJson(e, _key!);
                    }).toList(),
                    PageJumpTarget.parse(_key!, e['viewMore']),
                  );
                }),
              ),
            );
          } catch (e, s) {
            Log.error("Data Analysis", "$e\n$s");
            return Res.error(e.toString());
          }
        };
      } else if (type == 'mixed') {
        loadMixed = (index) async {
          try {
            var res = await JsEngine().runCode(
              "ComicSource.sources[${jsonEncode(_key)}].explore[$i].load(${jsonEncode(index)})",
            );
            var list = <Object>[];
            for (var data in (res['data'] as List)) {
              if (data is List) {
                list.add(data.map((e) => Comic.fromJson(e, _key!)).toList());
              } else if (data is Map) {
                list.add(
                  ExplorePagePart(
                    data['title'],
                    (data['comics'] as List).map((e) {
                      return Comic.fromJson(e, _key!);
                    }).toList(),
                    data['viewMore'],
                  ),
                );
              }
            }
            return Res(list, subData: res['maxPage']);
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        };
      }
      pages.add(
        ExplorePageData(
          title,
          switch (type) {
            "singlePageWithMultiPart" =>
              ExplorePageType.singlePageWithMultiPart,
            "multiPartPage" => ExplorePageType.singlePageWithMultiPart,
            "multiPageComicList" => ExplorePageType.multiPageComicList,
            "mixed" => ExplorePageType.mixed,
            _ => throw ComicSourceParseException(
              "Unknown explore page type $type",
            ),
          },
          loadPage,
          loadNext,
          loadMultiPart,
          loadMixed,
        ),
      );
    }
    return pages;
  }

  CategoryData? _loadCategoryData() {
    var doc = _getValue("category");

    if (doc?["title"] == null) {
      return null;
    }

    final String title = doc["title"];
    final bool? enableRankingPage = doc["enableRankingPage"];

    var categoryParts = <BaseCategoryPart>[];

    for (final part in doc['parts']) {
      final String name = part['name'];
      final categories = (part['categories'] as List?)
          ?.map(
            (item) => CategoryItem(
              item['label'],
              PageJumpTarget.parse(_key!, item['target']),
            ),
          )
          .toList();
      switch (part['type']) {
        case 'fixed':
          if (categories != null) {
            categoryParts.add(FixedCategoryPart(name, categories));
          }
        case 'random':
          if (categories != null) {
            categoryParts.add(
              RandomCategoryPart(name, categories, part['randomNumber'] ?? 1),
            );
          }
        case 'dynamic':
          if (categories == null) {
            categoryParts.add(
              DynamicCategoryPart(
                name,
                JSAutoFreeFunction(part['loader']),
                _key!,
              ),
            );
          }
      }
    }

    return CategoryData(
      title: title,
      categories: categoryParts,
      enableRankingPage: enableRankingPage ?? false,
      key: title,
    );
  }

  CategoryComicsData? _loadCategoryComicsData() {
    if (!_checkExists("categoryComics")) return null;

    List<CategoryComicsOptions>? options;
    if (_checkExists("categoryComics.optionList")) {
      options = <CategoryComicsOptions>[];
      for (var element in _getValue("categoryComics.optionList") ?? []) {
        final map = LinkedHashMap<String, String>.from(element['_options']);
        options.add(
          CategoryComicsOptions(
            element["label"] ?? "",
            map,
            List.from(element["notShowWhen"] ?? []),
            element["showWhen"] == null ? null : List.from(element["showWhen"]),
          ),
        );
      }
    }

    CategoryOptionsLoader? optionLoader;
    if (_checkExists("categoryComics.optionLoader")) {
      optionLoader = (category, param) async {
        try {
          dynamic res = JsEngine().runCode("""
          ComicSource.sources[${jsonEncode(_key)}].categoryComics.optionLoader(
            ${jsonEncode(category)}, ${jsonEncode(param)})
        """);
          if (res is Future) {
            res = await res;
          }
          if (res is! List) {
            return Res.error(
              "Invalid data:\nExpected: List\nGot: ${res.runtimeType}",
            );
          }
          var options = <CategoryComicsOptions>[];
          for (var element in res) {
            if (element is! Map) {
              return Res.error(
                "Invalid option data:\nExpected: Map\nGot: ${element.runtimeType}",
              );
            }
            final map = LinkedHashMap<String, String>.from(element['_options']);
            options.add(
              CategoryComicsOptions(
                element["label"] ?? "",
                map,
                List.from(element["notShowWhen"] ?? []),
                element["showWhen"] == null
                    ? null
                    : List.from(element["showWhen"]),
              ),
            );
          }
          return Res(options);
        } catch (e) {
          Log.error("Data Analysis", "Failed to load category options.\n$e");
          return Res.error(e.toString());
        }
      };
    }

    RankingData? rankingData;
    if (_checkExists("categoryComics.ranking")) {
      final options = Map<String, String>.from(
        _getValue('categoryComics.ranking._options'),
      );
      Future<Res<List<Comic>>> Function(String option, int page)? load;
      Future<Res<List<Comic>>> Function(String option, String? next)?
      loadWithNext;
      if (_checkExists("categoryComics.ranking.load")) {
        load = (option, page) async {
          try {
            var res = await JsEngine().runCode("""
            ComicSource.sources[${jsonEncode(_key)}].categoryComics.ranking.load(
              ${jsonEncode(option)}, ${jsonEncode(page)})
          """);
            return Res(
              List.generate(
                res["comics"].length,
                (index) => Comic.fromJson(res["comics"][index], _key!),
              ),
              subData: res["maxPage"],
            );
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        };
      } else {
        loadWithNext = (option, next) async {
          try {
            var res = await JsEngine().runCode("""
            ComicSource.sources[${jsonEncode(_key)}].categoryComics.ranking.loadWithNext(
              ${jsonEncode(option)}, ${jsonEncode(next)})
          """);
            return Res(
              List.generate(
                res["comics"].length,
                (index) => Comic.fromJson(res["comics"][index], _key!),
              ),
              subData: res["next"],
            );
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        };
      }
      rankingData = RankingData(options, load, loadWithNext);
    }

    if (options == null && optionLoader == null) {
      options = [];
    }

    return CategoryComicsData(
      options: options,
      optionsLoader: optionLoader,
      load: (category, param, options, page) async {
        try {
          var res = await JsEngine().runCode("""
              ComicSource.sources[${jsonEncode(_key)}].categoryComics.load(
                ${jsonEncode(category)},
                ${jsonEncode(param)},
                ${jsonEncode(options)},
                ${jsonEncode(page)}
              )
            """);
          return Res(
            List.generate(
              res["comics"].length,
              (index) => Comic.fromJson(res["comics"][index], _key!),
            ),
            subData: res["maxPage"],
          );
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      },
      rankingData: rankingData,
    );
  }

  SearchPageData? _loadSearchData() {
    if (!_checkExists("search")) return null;
    var options = <SearchOptions>[];
    for (var element in _getValue("search.optionList") ?? []) {
      final map = LinkedHashMap<String, String>.from(element['_options']);
      options.add(
        SearchOptions(
          map,
          element["label"],
          element['type'] ?? 'select',
          element['default'] == null ? null : jsonEncode(element['default']),
        ),
      );
    }

    SearchFunction? loadPage;

    SearchNextFunction? loadNext;

    if (_checkExists('search.load')) {
      loadPage = (keyword, page, searchOption) async {
        try {
          var res = await JsEngine().runCode("""
          ComicSource.sources[${jsonEncode(_key)}].search.load(
            ${jsonEncode(keyword)}, ${jsonEncode(searchOption)}, ${jsonEncode(page)})
        """);
          return Res(
            List.generate(
              res["comics"].length,
              (index) => Comic.fromJson(res["comics"][index], _key!),
            ),
            subData: res["maxPage"],
          );
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      };
    } else {
      loadNext = (keyword, next, searchOption) async {
        try {
          var res = await JsEngine().runCode("""
          ComicSource.sources[${jsonEncode(_key)}].search.loadNext(
            ${jsonEncode(keyword)}, ${jsonEncode(searchOption)}, ${jsonEncode(next)})
        """);
          return Res(
            List.generate(
              res["comics"].length,
              (index) => Comic.fromJson(res["comics"][index], _key!),
            ),
            subData: res["next"],
          );
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      };
    }

    return SearchPageData(options, loadPage, loadNext);
  }

  LoadComicFunc? _parseLoadComicFunc() {
    return (id) async {
      try {
        var res = await JsEngine().runCode("""
          ComicSource.sources[${jsonEncode(_key)}].comic.loadInfo(${jsonEncode(id)})
        """);
        if (res is! Map<String, dynamic>) throw "Invalid data";
        res['comicId'] = id;
        res['sourceKey'] = _key;
        return Res(ComicDetails.fromJson(res));
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  LoadComicPagesFunc? _parseLoadComicPagesFunc() {
    return (id, ep) async {
      try {
        var res = await JsEngine().runCode("""
          ComicSource.sources[${jsonEncode(_key)}].comic.loadEp(${jsonEncode(id)}, ${jsonEncode(ep)})
        """);
        return Res(List.from(res["images"]));
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  FavoriteData? _loadFavoriteData() {
    if (!_checkExists("favorites")) return null;

    final bool multiFolder = _getValue("favorites.multiFolder");
    final bool? isOldToNewSort = _getValue("favorites.isOldToNewSort");
    final bool? singleFolderForSingleComic = _getValue(
      "favorites.singleFolderForSingleComic",
    );

    Future<Res<bool>> addOrDelFavFunc(
      String comicId,
      String folderId,
      bool isAdding,
      String? favId,
    ) async {
      try {
        await JsEngine().runCode("""
          ComicSource.sources[${jsonEncode(_key)}].favorites.addOrDelFavorite(
            ${jsonEncode(comicId)}, ${jsonEncode(folderId)}, ${jsonEncode(isAdding)})
        """);
        return const Res(true);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res<bool>.error(e.toString());
      }
    }

    Future<Res<List<Comic>>> Function(int page, [String? folder])? loadComic;

    Future<Res<List<Comic>>> Function(String? next, [String? folder])? loadNext;

    if (_checkExists("favorites.loadComics")) {
      loadComic = (int page, [String? folder]) async {
        try {
          var res = await JsEngine().runCode("""
          ComicSource.sources[${jsonEncode(_key)}].favorites.loadComics(
            ${jsonEncode(page)}, ${jsonEncode(folder)})
        """);
          return Res(
            List.generate(
              res["comics"].length,
              (index) => Comic.fromJson(res["comics"][index], _key!),
            ),
            subData: res["maxPage"],
          );
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      };
    }

    if (_checkExists("favorites.loadNext")) {
      loadNext = (String? next, [String? folder]) async {
        try {
          var res = await JsEngine().runCode("""
          ComicSource.sources[${jsonEncode(_key)}].favorites.loadNext(
            ${jsonEncode(next)}, ${jsonEncode(folder)})
        """);
          return Res(
            List.generate(
              res["comics"].length,
              (index) => Comic.fromJson(res["comics"][index], _key!),
            ),
            subData: res["next"],
          );
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      };
    }

    Future<Res<Map<String, String>>> Function([String? comicId])? loadFolders;

    Future<Res<bool>> Function(String name)? addFolder;

    Future<Res<bool>> Function(String key)? deleteFolder;

    if (multiFolder) {
      loadFolders = ([String? comicId]) async {
        try {
          var res = await JsEngine().runCode("""
          ComicSource.sources[${jsonEncode(_key)}].favorites.loadFolders(${jsonEncode(comicId)})
        """);
          List<String>? subData;
          if (res["favorited"] != null) {
            subData = List.from(res["favorited"]);
          }
          return Res(Map.from(res["folders"]), subData: subData);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      };
      if (_checkExists("favorites.addFolder")) {
        addFolder = (name) async {
          try {
            await JsEngine().runCode("""
            ComicSource.sources[${jsonEncode(_key)}].favorites.addFolder(${jsonEncode(name)})
          """);
            return const Res(true);
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        };
      }
      if (_checkExists("favorites.deleteFolder")) {
        deleteFolder = (key) async {
          try {
            await JsEngine().runCode("""
            ComicSource.sources[${jsonEncode(_key)}].favorites.deleteFolder(${jsonEncode(key)})
          """);
            return const Res(true);
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        };
      }
    }

    return FavoriteData(
      key: _key!,
      title: _name!,
      multiFolder: multiFolder,
      loadComic: loadComic,
      loadNext: loadNext,
      loadFolders: loadFolders,
      addFolder: addFolder,
      deleteFolder: deleteFolder,
      addOrDelFavorite: addOrDelFavFunc,
      isOldToNewSort: isOldToNewSort,
      singleFolderForSingleComic: singleFolderForSingleComic ?? false,
    );
  }

  CommentsLoader? _parseCommentsLoader() {
    if (!_checkExists("comic.loadComments")) return null;
    return (id, subId, page, replyTo) async {
      try {
        var res = await JsEngine().runCode("""
          ComicSource.sources[${jsonEncode(_key)}].comic.loadComments(
            ${jsonEncode(id)}, ${jsonEncode(subId)}, ${jsonEncode(page)}, ${jsonEncode(replyTo)})
        """);
        return Res(
          (res["comments"] as List).map((e) => Comment.fromJson(e)).toList(),
          subData: res["maxPage"],
        );
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  SendCommentFunc? _parseSendCommentFunc() {
    if (!_checkExists("comic.sendComment")) return null;
    return (id, subId, content, replyTo) async {
      Future<Res<bool>> func() async {
        try {
          await JsEngine().runCode("""
            ComicSource.sources[${jsonEncode(_key)}].comic.sendComment(
              ${jsonEncode(id)}, ${jsonEncode(subId)}, ${jsonEncode(content)}, ${jsonEncode(replyTo)})
          """);
          return const Res(true);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      }

      return func();
    };
  }

  ChapterCommentsLoader? _parseChapterCommentsLoader() {
    if (!_checkExists("comic.loadChapterComments")) return null;
    return (comicId, epId, page, replyTo) async {
      try {
        var res = await JsEngine().runCode("""
          ComicSource.sources[${jsonEncode(_key)}].comic.loadChapterComments(
            ${jsonEncode(comicId)}, ${jsonEncode(epId)}, ${jsonEncode(page)}, ${jsonEncode(replyTo)})
        """);
        return Res(
          (res["comments"] as List).map((e) => Comment.fromJson(e)).toList(),
          subData: res["maxPage"],
        );
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  SendChapterCommentFunc? _parseSendChapterCommentFunc() {
    if (!_checkExists("comic.sendChapterComment")) return null;
    return (comicId, epId, content, replyTo) async {
      Future<Res<bool>> func() async {
        try {
          await JsEngine().runCode("""
            ComicSource.sources[${jsonEncode(_key)}].comic.sendChapterComment(
              ${jsonEncode(comicId)}, ${jsonEncode(epId)}, ${jsonEncode(content)}, ${jsonEncode(replyTo)})
          """);
          return const Res(true);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      }

      return func();
    };
  }

  GetImageLoadingConfigFunc? _parseImageLoadingConfigFunc() {
    if (!_checkExists("comic.onImageLoad")) {
      return null;
    }
    return (imageKey, comicId, ep) async {
      var res = JsEngine().runCode("""
          ComicSource.sources[${jsonEncode(_key)}].comic.onImageLoad(
            ${jsonEncode(imageKey)}, ${jsonEncode(comicId)}, ${jsonEncode(ep)})
        """);
      if (res is Future) {
        return await res;
      }
      return res;
    };
  }

  GetThumbnailLoadingConfigFunc? _parseThumbnailLoadingConfigFunc() {
    if (!_checkExists("comic.onThumbnailLoad")) {
      return null;
    }
    return (imageKey) {
      var res = JsEngine().runCode("""
          ComicSource.sources[${jsonEncode(_key)}].comic.onThumbnailLoad(${jsonEncode(imageKey)})
        """);
      if (res is! Map) {
        Log.error("Network", "function onThumbnailLoad return invalid data");
        throw "function onThumbnailLoad return invalid data";
      }
      return res as Map<String, dynamic>;
    };
  }

  ComicThumbnailLoader? _parseThumbnailLoader() {
    if (!_checkExists("comic.loadThumbnails")) {
      return null;
    }
    return (id, next) async {
      try {
        var res = await JsEngine().runCode("""
          ComicSource.sources[${jsonEncode(_key)}].comic.loadThumbnails(${jsonEncode(id)}, ${jsonEncode(next)})
        """);
        return Res(List<String>.from(res['thumbnails']), subData: res['next']);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  LikeOrUnlikeComicFunc? _parseLikeFunc() {
    if (!_checkExists("comic.likeComic")) {
      return null;
    }
    return (id, isLiking) async {
      try {
        await JsEngine().runCode("""
          ComicSource.sources[${jsonEncode(_key)}].comic.likeComic(${jsonEncode(id)}, ${jsonEncode(isLiking)})
        """);
        return const Res(true);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  VoteCommentFunc? _parseVoteCommentFunc() {
    if (!_checkExists("comic.voteComment")) {
      return null;
    }
    return (id, subId, commentId, isUp, isCancel) async {
      try {
        var res = await JsEngine().runCode("""
          ComicSource.sources[${jsonEncode(_key)}].comic.voteComment(${jsonEncode(id)}, ${jsonEncode(subId)}, ${jsonEncode(commentId)}, ${jsonEncode(isUp)}, ${jsonEncode(isCancel)})
        """);
        return Res(res is num ? res.toInt() : 0);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  LikeCommentFunc? _parseLikeCommentFunc() {
    if (!_checkExists("comic.likeComment")) {
      return null;
    }
    return (id, subId, commentId, isLiking) async {
      try {
        var res = await JsEngine().runCode("""
          ComicSource.sources[${jsonEncode(_key)}].comic.likeComment(${jsonEncode(id)}, ${jsonEncode(subId)}, ${jsonEncode(commentId)}, ${jsonEncode(isLiking)})
        """);
        return Res(res is num ? res.toInt() : 0);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  RegExp? _parseIdMatch() {
    if (!_checkExists("comic.idMatch")) {
      return null;
    }
    return RegExp(_getValue("comic.idMatch"));
  }

  Map<String, Map<String, String>>? _parseTranslation() {
    if (!_checkExists("translation")) {
      return null;
    }
    var data = _getValue("translation");
    var res = <String, Map<String, String>>{};
    for (var e in data.entries) {
      res[e.key] = Map<String, String>.from(e.value);
    }
    return res;
  }

  HandleClickTagEvent? _parseClickTagEvent() {
    if (!_checkExists("comic.onClickTag")) {
      return null;
    }
    return (namespace, tag) {
      var res = JsEngine().runCode("""
          ComicSource.sources[${jsonEncode(_key)}].comic.onClickTag(${jsonEncode(namespace)}, ${jsonEncode(tag)})
        """);
      if (res is! Map) {
        return null;
      }
      var r = Map<String, dynamic>.from(res);
      r.removeWhere((key, value) => value == null);
      return PageJumpTarget.parse(_key!, r);
    };
  }

  TagSuggestionSelectFunc? _parseTagSuggestionSelectFunc() {
    if (!_checkExists("search.onTagSuggestionSelected")) {
      return null;
    }
    return (namespace, tag) {
      var res = JsEngine().runCode("""
          ComicSource.sources[${jsonEncode(_key)}].search.onTagSuggestionSelected(
            ${jsonEncode(namespace)}, ${jsonEncode(tag)})
        """);
      return res is String ? res : "$namespace:$tag";
    };
  }

  LinkHandler? _parseLinkHandler() {
    if (!_checkExists("comic.link")) {
      return null;
    }
    List<String> domains = List.from(_getValue("comic.link.domains"));
    linkToId(String link) {
      var res = JsEngine().runCode("""
          ComicSource.sources[${jsonEncode(_key)}].comic.link.linkToId(${jsonEncode(link)})
        """);
      return res as String?;
    }

    return LinkHandler(domains, linkToId);
  }

  StarRatingFunc? _parseStarRatingFunc() {
    if (!_checkExists("comic.starRating")) {
      return null;
    }
    return (id, rating) async {
      try {
        await JsEngine().runCode("""
          ComicSource.sources[${jsonEncode(_key)}].comic.starRating(${jsonEncode(id)}, ${jsonEncode(rating)})
        """);
        return const Res(true);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  ArchiveDownloader? _parseArchiveDownloader() {
    if (!_checkExists("comic.archive")) {
      return null;
    }
    return ArchiveDownloader(
      (cid) async {
        try {
          var res = await JsEngine().runCode("""
              ComicSource.sources[${jsonEncode(_key)}].comic.archive.getArchives(${jsonEncode(cid)})
            """);
          return Res(
            (res as List).map((e) => ArchiveInfo.fromJson(e)).toList(),
          );
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      },
      (cid, aid) async {
        try {
          var res = await JsEngine().runCode("""
              ComicSource.sources[${jsonEncode(_key)}].comic.archive.getDownloadUrl(${jsonEncode(cid)}, ${jsonEncode(aid)})
            """);
          return Res(res as String);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      },
    );
  }
}
