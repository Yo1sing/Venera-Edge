part of 'favorites_page.dart';

/// Open a dialog to create a new favorite folder.
Future<void> newFolder() async {
  return showDialog(
    context: App.rootContext,
    builder: (context) {
      var controller = TextEditingController();
      String? error;

      return StatefulBuilder(
        builder: (context, setState) {
          return ContentDialog(
            title: "New Folder".tl,
            content: Column(
              children: [
                TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: "Folder Name".tl,
                    errorText: error,
                  ),
                  onChanged: (s) {
                    if (error != null) {
                      setState(() {
                        error = null;
                      });
                    }
                  },
                ),
              ],
            ).paddingHorizontal(16),
            actions: [
              TextButton(
                child: Text("Import from file".tl),
                onPressed: () async {
                  var file = await selectFile(ext: ['json']);
                  if (file == null) return;
                  var data = await file.readAsBytes();
                  try {
                    LocalFavoritesManager().fromJson(utf8.decode(data));
                  } catch (e) {
                    context.showMessage(message: "Failed to import".tl);
                    return;
                  }
                  context.pop();
                },
              ).paddingRight(4),
              FilledButton(
                onPressed: () {
                  var e = validateFolderName(controller.text);
                  if (e != null) {
                    setState(() {
                      error = e;
                    });
                  } else {
                    LocalFavoritesManager().createFolder(controller.text);
                    context.pop();
                  }
                },
                child: Text("Create".tl),
              ),
            ],
          );
        },
      );
    },
  );
}

String? validateFolderName(String newFolderName) {
  var folders = LocalFavoritesManager().folderNames;
  if (newFolderName.isEmpty) {
    return "Folder name cannot be empty".tl;
  } else if (newFolderName.length > 50) {
    return "Folder name is too long".tl;
  } else if (folders.contains(newFolderName)) {
    return "Folder already exists".tl;
  }
  return null;
}

void addFavorite(List<Comic> comics) {
  var folders = LocalFavoritesManager().folderNames;

  showDialog(
    context: App.rootContext,
    builder: (context) {
      String? selectedFolder = appdata.settings['quickFavorite'];

      return StatefulBuilder(
        builder: (context, setState) {
          return ContentDialog(
            title: "Select a folder".tl,
            content: Select(
              title: Text("Folder".tl),
              current: selectedFolder,
              values: folders,
              minWidth: 112,
              onTap: (v) => setState(() => selectedFolder = folders[v]),
            ),
            actions: [
              FilledButton(
                onPressed: () {
                  if (selectedFolder != null) {
                    for (var comic in comics) {
                      LocalFavoritesManager().addComic(
                        selectedFolder!,
                        FavoriteItem(
                          id: comic.id,
                          name: comic.title,
                          coverPath: comic.cover,
                          author: comic.subtitle ?? '',
                          type: ComicType(
                            (comic.sourceKey == 'local'
                                ? 0
                                : comic.sourceKey.hashCode),
                          ),
                          tags: comic.tags ?? [],
                        ),
                      );
                    }
                    context.pop();
                  }
                },
                child: Text("Confirm".tl),
              ),
            ],
          );
        },
      );
    },
  );
}

Future<void> updateComicsInfo(String folder) async {
  final task = UpdateSession(folder, true, metadataOnly: true);
  final dialog = showLoadingDialog(
    App.rootContext,
    barrierDismissible: false,
    withProgress: true,
    onCancel: task.cancel,
    message: "Updating".tl,
  );
  try {
    await for (final progress in task.progress) {
      dialog.setProgress(progress.fraction);
      if (progress.isDone && progress.errors > 0 && !dialog.closed) {
        App.rootContext.showMessage(
          message: progress.errorMessage ?? "Errors: ${progress.errors}",
        );
      }
    }
  } catch (error, stack) {
    Log.error('Favorite metadata', error, stack);
    App.rootContext.showMessage(message: error.toString());
  } finally {
    dialog.close();
  }
}

Future<void> sortFolders() async {
  var folders = LocalFavoritesManager().folderNames;

  await showPopUpWidget(
    App.rootContext,
    StatefulBuilder(
      builder: (context, setState) {
        return PopUpWidgetScaffold(
          title: "Sort".tl,
          tailing: [
            Tooltip(
              message: "Help".tl,
              child: IconButton(
                icon: const Icon(Icons.help_outline),
                onPressed: () {
                  showInfoDialog(
                    context: context,
                    title: "Reorder".tl,
                    content: "Long press and drag to reorder.".tl,
                  );
                },
              ),
            ),
          ],
          body: ReorderableListView.builder(
            onReorderItem: (oldIndex, newIndex) {
              setState(() {
                var item = folders.removeAt(oldIndex);
                folders.insert(newIndex, item);
              });
            },
            itemCount: folders.length,
            itemBuilder: (context, index) {
              return ListTile(
                key: ValueKey(folders[index]),
                title: Text(folders[index]),
              );
            },
          ),
        );
      },
    ),
  );

  LocalFavoritesManager().updateOrder(folders);
}

Future<void> importNetworkFolder(
  String source,
  int updatePageNum,
  String? folder,
  String? folderID,
) async {
  final manager = LocalFavoritesManager();
  try {
    final task = await manager.backendStore.importNetwork(
      runtime: JsEngine().runtime,
      requestJson: jsonEncode({
        'source': source,
        'comic_type': source.hashCode,
        'page_limit': updatePageNum,
        'folder': folder,
        'remote_folder': folderID,
        'at_end': appdata.settings['newFavoriteAddTo'] == 'end',
        'traditional': App.locale.countryCode == 'TW',
      }),
    );
    final dialog = showLoadingDialog(
      App.rootContext,
      barrierDismissible: false,
      onCancel: task.cancel,
      message: "Importing".tl,
    );
    try {
      while (true) {
        final snapshot = await task.nextSnapshot();
        if (snapshot == null) break;
        final event = jsonDecode(snapshot) as Map<String, dynamic>;
        final message =
            "Imported @a comics, loaded @b pages, received @c comics".tlParams({
              'a': event['added'],
              'b': event['pages'],
              'c': event['received'],
            });
        dialog.setMessage(message);
        if (event['status'] != 'running') {
          if (!dialog.closed) {
            final error = event['error'] as String?;
            App.rootContext.showMessage(
              message: error == null
                  ? message
                  : error == 'Folder already exists'
                  ? error.tl
                  : '$message\n$error',
            );
          }
          break;
        }
      }
    } finally {
      task.dispose();
      dialog.close();
      if (!FollowUpdatesBackend.restoring) manager.initCounts();
    }
  } catch (error, stack) {
    Log.error('Import network favorites', error, stack);
    App.rootContext.showMessage(message: error.toString());
  }
}
