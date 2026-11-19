import 'dart:convert';
import 'dart:io' as io;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:prism_ui/switch.dart' as prism;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/src/rust/api/http.dart' show HttpCancellation;
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/pages/webview.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

class ComicSourcePage extends StatelessWidget {
  const ComicSourcePage({super.key});

  static Future<void> update(
    ComicSource source, [
    bool showLoading = true,
    HttpCancellation? cancellation,
    bool Function()? isActive,
  ]) async {
    final token = cancellation ?? HttpCancellation();
    var cancelled = false;
    final controller = showLoading
        ? showLoadingDialog(
            App.rootContext,
            barrierDismissible: false,
            onCancel: () {
              cancelled = true;
              token.cancel();
            },
          )
        : null;
    try {
      await ComicSourceManager().update(source.key, token);
      if (showLoading) App.forceRebuild();
    } catch (error) {
      if (cancelled || isActive?.call() == false) return;
      if (!showLoading) rethrow;
      App.rootContext.showMessage(message: error.toString());
    } finally {
      controller?.close();
      if (cancellation == null) token.dispose();
    }
  }

  static Future<int> checkComicSourceUpdate([
    HttpCancellation? cancellation,
  ]) async {
    if (ComicSource.all().isEmpty) return 0;
    final urls = _readUrls();
    if (urls.isEmpty) return 0;
    final token = cancellation ?? HttpCancellation();
    try {
      return await ComicSourceManager().checkUpdates(urls, token);
    } catch (error, stack) {
      Log.error('Check source updates', error, stack);
      return -1;
    } finally {
      if (cancellation == null) token.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: const _Body());
  }
}

class _Body extends StatefulWidget {
  const _Body();

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  var url = "";
  final _operations = <HttpCancellation>{};

  void updateUI() {
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    ComicSourceManager().addListener(updateUI);
  }

  @override
  void dispose() {
    super.dispose();
    ComicSourceManager().removeListener(updateUI);
    for (final operation in _operations) {
      operation.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text('Comic Source'.tl), style: AppbarStyle.shadow),
        buildCard(context),
        for (var source in ComicSource.all())
          _SliverComicSource(
            key: ValueKey(source.key),
            source: source,
            edit: edit,
            update: update,
            delete: delete,
          ),
        SliverPadding(padding: EdgeInsets.only(bottom: context.padding.bottom)),
      ],
    );
  }

  void delete(ComicSource source) {
    showConfirmDialog(
      context: App.rootContext,
      title: "Delete".tl,
      content: "Delete comic source '@n' ?".tlParams({"n": source.name}),
      btnColor: context.colorScheme.error,
      onConfirm: () async {
        final cancellation = HttpCancellation();
        _operations.add(cancellation);
        try {
          await ComicSourceManager().remove(source.key, cancellation);
          App.forceRebuild();
        } catch (error) {
          if (mounted) context.showMessage(message: error.toString());
        } finally {
          _operations.remove(cancellation);
          cancellation.dispose();
        }
      },
    );
  }

  void edit(ComicSource source) async {
    if (App.isDesktop) {
      String? draft;
      try {
        draft = await ComicSourceManager().beginEdit(source.key);
        final process = await io.Process.run("code", [draft], runInShell: true);
        if (process.exitCode != 0) throw StateError(process.stderr.toString());
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text("Reload Configs".tl),
            actions: [
              TextButton(
                onPressed: () => dialogContext.pop(),
                child: Text("Cancel".tl),
              ),
              TextButton(
                onPressed: () async {
                  final cancellation = HttpCancellation();
                  _operations.add(cancellation);
                  try {
                    await ComicSourceManager().saveEdit(
                      source.key,
                      draft!,
                      cancellation,
                    );
                    if (dialogContext.mounted) dialogContext.pop();
                    App.forceRebuild();
                  } catch (error) {
                    if (dialogContext.mounted) {
                      dialogContext.showMessage(message: error.toString());
                    }
                  } finally {
                    _operations.remove(cancellation);
                    cancellation.dispose();
                  }
                },
                child: Text("Confirm".tl),
              ),
            ],
          ),
        );
        return;
      } catch (error, stack) {
        Log.error('Source editor', error, stack);
      } finally {
        if (draft != null) await ComicSourceManager().discardEdit(draft);
      }
    }
    if (mounted) context.to(() => _EditFilePage(source.key));
  }

  void update(ComicSource source, [bool showLoading = true]) async {
    final cancellation = HttpCancellation();
    _operations.add(cancellation);
    try {
      await ComicSourcePage.update(
        source,
        showLoading,
        cancellation,
        () => mounted,
      );
    } finally {
      _operations.remove(cancellation);
      cancellation.dispose();
    }
  }

  Widget buildCard(BuildContext context) {
    return SliverToBoxAdapter(
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text("Add comic source".tl),
              leading: const Icon(Icons.dashboard_customize),
            ),
            TextField(
              decoration: InputDecoration(
                hintText: "URL".tl,
                border: const UnderlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                suffix: IconButton(
                  onPressed: () => handleAddSource(url),
                  icon: const Icon(Icons.check),
                ),
              ),
              onChanged: (value) {
                url = value;
              },
              onSubmitted: handleAddSource,
            ).paddingHorizontal(16).paddingBottom(8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  icon: Icon(Icons.article_outlined),
                  label: Text("Comic Source list".tl),
                  onPressed: () {
                    showPopUpWidget(
                      App.rootContext,
                      _ComicSourceList(handleAddSource),
                    );
                  },
                ),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.link),
                  label: Text("Subscription URLs".tl),
                  onPressed: () =>
                      showPopUpWidget(context, const _SubscriptionUrls()),
                ),
                FilledButton.tonalIcon(
                  icon: Icon(Icons.file_open_outlined),
                  label: Text("Use a config file".tl),
                  onPressed: _selectFile,
                ),
                FilledButton.tonalIcon(
                  icon: Icon(Icons.help_outline),
                  label: Text("Help".tl),
                  onPressed: help,
                ),
                _CheckUpdatesButton(),
              ],
            ).paddingHorizontal(12).paddingVertical(8),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _selectFile() async {
    final file = await selectFile(ext: ["js"]);
    if (file == null || !mounted) return;
    final cancellation = HttpCancellation();
    _operations.add(cancellation);
    try {
      await ComicSourceManager().install(
        await file.readAsBytes(),
        file.name,
        cancellation,
      );
      App.forceRebuild();
    } catch (error, stack) {
      if (mounted) context.showMessage(message: error.toString());
      Log.error('Add comic source', error, stack);
    } finally {
      _operations.remove(cancellation);
      cancellation.dispose();
    }
  }

  void help() {
    launchUrlString(
      "https://github.com/Yo1sing/Venera-Edge/blob/master/doc/comic_source.md",
    );
  }

  Future<void> handleAddSource(String url) async {
    if (url.isEmpty) return;
    final cancellation = HttpCancellation();
    _operations.add(cancellation);
    var cancelled = false;
    final controller = showLoadingDialog(
      context,
      barrierDismissible: false,
      onCancel: () {
        cancelled = true;
        cancellation.cancel();
      },
    );
    try {
      await ComicSourceManager().installUrl(url, cancellation);
      App.forceRebuild();
    } catch (error, stack) {
      if (mounted && !cancelled) context.showMessage(message: error.toString());
      Log.error('Add comic source', error, stack);
    } finally {
      controller.close();
      _operations.remove(cancellation);
      cancellation.dispose();
    }
  }
}

class _ComicSourceList extends StatefulWidget {
  const _ComicSourceList(this.onAdd);

  final Future<void> Function(String) onAdd;

  @override
  State<_ComicSourceList> createState() => _ComicSourceListState();
}

class _ComicSourceListState extends State<_ComicSourceList> {
  late List<String> _urls;
  final _catalogs = <String, List<dynamic>?>{};
  final _failedUrls = <String>{};
  final _loads = <String, HttpCancellation>{};
  @override
  void initState() {
    super.initState();
    _urls = _readUrls();
    appdata.settings.addListener(_syncUrls);
    for (final url in _urls) {
      _load(url);
    }
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_syncUrls);
    for (final cancellation in _loads.values) {
      cancellation.cancel();
    }
    _loads.clear();
    super.dispose();
  }

  void _syncUrls() {
    final urls = _readUrls();
    if (listEquals(_urls, urls)) return;
    final previous = _urls.toSet();
    setState(() {
      for (final url in previous.difference(urls.toSet())) {
        _loads.remove(url)?.cancel();
        _catalogs.remove(url);
        _failedUrls.remove(url);
      }
      _urls = urls;
    });
    for (final url in urls) {
      if (!previous.contains(url)) _load(url);
    }
  }

  Future<void> _load(String url) async {
    _loads.remove(url)?.cancel();
    final cancellation = HttpCancellation();
    _loads[url] = cancellation;
    setState(() {
      _catalogs[url] = null;
      _failedUrls.remove(url);
    });
    try {
      final entries = await ComicSourceManager().catalog(url, cancellation);
      if (!mounted || !identical(_loads[url], cancellation)) return;
      setState(() {
        _catalogs[url] = entries;
      });
    } catch (error, stack) {
      if (!mounted || !identical(_loads[url], cancellation)) return;
      Log.error('Load comic source list', error, stack);
      setState(() {
        _catalogs[url] = [];
        _failedUrls.add(url);
      });
    } finally {
      if (identical(_loads[url], cancellation)) {
        _loads.remove(url);
      }
      cancellation.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "Comic Source list".tl,
      tailing: [
        IconButton(
          tooltip: "Subscription URLs".tl,
          icon: const Icon(Icons.link),
          onPressed: () => showPopUpWidget(context, const _SubscriptionUrls()),
        ),
      ],
      body: buildBody(),
    );
  }

  Widget buildBody() {
    if (_urls.isEmpty) {
      return Center(child: Text("No subscription URLs configured".tl));
    }
    final installed = ComicSource.all().map((e) => e.key).toSet();
    return ListView.builder(
      itemCount: _urls.length,
      itemBuilder: (context, index) =>
          _buildRepository(_urls[index], installed),
    );
  }

  Widget _buildRepository(String url, Set<String> installed) {
    final entries = _catalogs[url];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: const Icon(Icons.link),
          title: Text(url, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: IconButton(
            tooltip: "Refresh".tl,
            onPressed: () => _load(url),
            icon: const Icon(Icons.refresh),
          ),
        ),
        if (entries == null)
          Center(
            child: CircularProgressIndicator(strokeWidth: 2),
          ).fixWidth(24).fixHeight(24).paddingVertical(8)
        else if (_failedUrls.contains(url))
          ListTile(
            leading: const Icon(Icons.error_outline),
            title: Text("Unable to load comic source list".tl),
            subtitle: Text("Tap refresh to retry".tl),
          )
        else if (entries.isEmpty)
          ListTile(title: Text("No sources found".tl))
        else
          ...entries.map((entry) => _buildEntry(entry, installed)),
        const Divider(height: 1),
      ],
    );
  }

  Widget _buildEntry(dynamic entry, Set<String> installed) {
    final key = entry["key"]?.toString() ?? "";
    final name = entry["name"]?.toString() ?? key;
    var description = entry["version"]?.toString() ?? "";
    if (entry["description"] != null) {
      description = "$description\n${entry["description"]}";
    }
    return ListTile(
      title: Text(name),
      subtitle: Text(description),
      trailing: installed.contains(key)
          ? const Icon(Icons.check, size: 20).paddingRight(8)
          : Button.filled(
              child: Text("Add".tl),
              onPressed: () async {
                await widget.onAdd(entry["url"] as String);
                if (mounted) setState(() {});
              },
            ).fixHeight(32),
    );
  }
}

List<String> _readUrls() =>
    (appdata.settings['comicSourceListUrls'] as List? ?? [])
        .whereType<String>()
        .toList();

class _SubscriptionUrls extends StatefulWidget {
  const _SubscriptionUrls();

  @override
  State<_SubscriptionUrls> createState() => _SubscriptionUrlsState();
}

class _SubscriptionUrlsState extends State<_SubscriptionUrls> {
  final _controller = TextEditingController();
  String? _inputError;
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save(VoidCallback edit, {bool clearInput = false}) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      edit();
      await appdata.saveData();
      if (mounted && clearInput) _controller.clear();
    } catch (error, stack) {
      Log.error('Save subscription URLs', error, stack);
      if (mounted) {
        context.showMessage(message: "Unable to save subscription URLs".tl);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _addUrl() {
    if (_saving) return;
    final url = _controller.text.trim();
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      setState(() => _inputError = "Invalid URL");
      return;
    }
    if (_readUrls().contains(url)) {
      setState(() => _inputError = "This URL is already added");
      return;
    }
    setState(() => _inputError = null);
    _save(() => appdata.settings.addComicSourceListUrl(url), clearInput: true);
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "Subscription URLs".tl,
      body: ListenableBuilder(
        listenable: appdata.settings,
        builder: (context, _) {
          final urls = _readUrls();
          return ListView.builder(
            itemCount: urls.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) return _buildInput();
              final url = urls[index - 1];
              return ListTile(
                leading: const Icon(Icons.link),
                title: SelectableText(url),
                trailing: IconButton(
                  tooltip: "Remove".tl,
                  onPressed: _saving
                      ? null
                      : () => _save(
                          () => appdata.settings.removeComicSourceListUrl(url),
                        ),
                  icon: const Icon(Icons.delete_outline),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _controller,
          readOnly: _saving,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: "URL of index.json".tl,
            errorText: _inputError?.tl,
            suffixIcon: IconButton(
              tooltip: "Add".tl,
              onPressed: _saving ? null : _addUrl,
              icon: const Icon(Icons.add),
            ),
          ),
          onChanged: (_) {
            if (_inputError != null) setState(() => _inputError = null);
          },
          onSubmitted: (_) => _addUrl(),
        ),
        const SizedBox(height: 8),
        Text(
          "The URL should point to an 'index.json' file. Installed sources are kept when a repository is removed."
              .tl,
        ),
      ],
    ).paddingHorizontal(16).paddingVertical(8);
  }
}

class _EditFilePage extends StatefulWidget {
  const _EditFilePage(this.sourceKey);
  final String sourceKey;
  @override
  State<_EditFilePage> createState() => __EditFilePageState();
}

class __EditFilePageState extends State<_EditFilePage> {
  String? current;
  HttpCancellation? _saving;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final code = await ComicSourceManager().read(widget.sourceKey);
      if (mounted) {
        setState(() {
          current = code;
        });
      }
    } catch (error) {
      if (mounted) context.showMessage(message: error.toString());
    }
  }

  Future<void> _save() async {
    if (current == null || _saving != null) return;
    final cancellation = HttpCancellation();
    setState(() {
      _saving = cancellation;
    });
    try {
      await ComicSourceManager().save(widget.sourceKey, current!, cancellation);
      if (mounted) context.pop();
      App.forceRebuild();
    } catch (error) {
      if (mounted) context.showMessage(message: error.toString());
    } finally {
      _saving = null;
      cancellation.dispose();
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _saving?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: Appbar(
      title: Text("Edit".tl),
      actions: [
        IconButton(
          onPressed: current == null || _saving != null ? null : _save,
          icon: const Icon(Icons.save),
        ),
      ],
    ),
    body: current == null
        ? const Center(child: CircularProgressIndicator())
        : CodeEditor(
            initialValue: current!,
            onChanged: (value) => current = value,
          ),
  );
}

class _CheckUpdatesButton extends StatefulWidget {
  const _CheckUpdatesButton();

  @override
  State<_CheckUpdatesButton> createState() => _CheckUpdatesButtonState();
}

class _CheckUpdatesButtonState extends State<_CheckUpdatesButton> {
  HttpCancellation? _updating;
  HttpCancellation? _checking;
  @override
  void dispose() {
    _updating?.cancel();
    _checking?.cancel();
    super.dispose();
  }

  bool isLoading = false;

  void check() async {
    setState(() {
      isLoading = true;
    });
    final cancellation = HttpCancellation();
    _checking = cancellation;
    final count = await ComicSourcePage.checkComicSourceUpdate(cancellation);
    _checking = null;
    cancellation.dispose();
    if (!mounted) return;
    if (count == -1) {
      context.showMessage(message: "Network error".tl);
    } else if (count == 0) {
      context.showMessage(message: "No updates".tl);
    } else {
      showUpdateDialog();
    }
    setState(() {
      isLoading = false;
    });
  }

  void showUpdateDialog() async {
    var text = ComicSourceManager().availableUpdates.entries
        .map((e) {
          return "${ComicSource.find(e.key)!.name}: ${e.value}";
        })
        .join("\n");
    bool doUpdate = false;
    await showDialog(
      context: App.rootContext,
      builder: (context) {
        return ContentDialog(
          title: "Updates".tl,
          content: Text(text).paddingHorizontal(16),
          actions: [
            FilledButton(
              onPressed: () {
                doUpdate = true;
                context.pop();
              },
              child: Text("Update".tl),
            ),
          ],
        );
      },
    );
    if (doUpdate && mounted) {
      final cancellation = HttpCancellation();
      _updating = cancellation;
      var cancelled = false;
      var loadingController = showLoadingDialog(
        context,
        message: "Updating".tl,
        withProgress: true,
        barrierDismissible: false,
        onCancel: () {
          cancelled = true;
          cancellation.cancel();
        },
      );
      int current = 0;
      int total = ComicSourceManager().availableUpdates.length;
      try {
        var shouldUpdate = ComicSourceManager().availableUpdates.keys.toList();
        for (var key in shouldUpdate) {
          var source = ComicSource.find(key)!;
          if (cancelled) break;
          await ComicSourcePage.update(source, false, cancellation);
          current++;
          loadingController.setProgress(current / total);
        }
      } catch (e) {
        if (mounted && !cancelled) context.showMessage(message: e.toString());
      } finally {
        loadingController.close();
        _updating = null;
        cancellation.dispose();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      icon: isLoading
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(Icons.update),
      label: Text("Check updates".tl),
      onPressed: isLoading ? null : check,
    );
  }
}

class _CallbackSetting extends StatefulWidget {
  const _CallbackSetting({required this.setting, required this.sourceKey});

  final MapEntry<String, Map<String, dynamic>> setting;

  final String sourceKey;

  @override
  State<_CallbackSetting> createState() => _CallbackSettingState();
}

class _CallbackSettingState extends State<_CallbackSetting> {
  String get key => widget.setting.key;

  String get buttonText => widget.setting.value['buttonText'] ?? "Click";

  String get title => widget.setting.value['title'] ?? key;

  bool isLoading = false;

  Future<void> onClick() async {
    var func = widget.setting.value['callback'];
    var result = func([]);
    if (result is Future) {
      setState(() {
        isLoading = true;
      });
      try {
        await result;
      } finally {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title.ts(widget.sourceKey)),
      trailing: Button.normal(
        onPressed: onClick,
        isLoading: isLoading,
        child: Text(buttonText.ts(widget.sourceKey)),
      ).fixHeight(32),
    );
  }
}

class _SliverComicSource extends StatefulWidget {
  const _SliverComicSource({
    super.key,
    required this.source,
    required this.edit,
    required this.update,
    required this.delete,
  });

  final ComicSource source;

  final void Function(ComicSource source) edit;
  final void Function(ComicSource source) update;
  final void Function(ComicSource source) delete;

  @override
  State<_SliverComicSource> createState() => _SliverComicSourceState();
}

class _SliverComicSourceState extends State<_SliverComicSource> {
  ComicSource get source => widget.source;

  @override
  Widget build(BuildContext context) {
    var newVersion = ComicSourceManager().availableUpdates[source.key];
    bool hasUpdate = newVersion != null;

    return SliverMainAxisGroup(
      slivers: [
        SliverPadding(padding: const EdgeInsets.only(top: 16)),
        SliverToBoxAdapter(
          child: ListTile(
            title: Row(
              children: [
                Text(source.name, style: ts.s18),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: context.colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    source.version,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                if (hasUpdate)
                  Tooltip(
                    message: newVersion,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: context.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        "New Version".tl,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ).paddingLeft(4),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Tooltip(
                  message: "Edit".tl,
                  child: IconButton(
                    onPressed: () => widget.edit(source),
                    icon: const Icon(Icons.edit_note),
                  ),
                ),
                Tooltip(
                  message: "Update".tl,
                  child: IconButton(
                    onPressed: () => widget.update(source),
                    icon: const Icon(Icons.update),
                  ),
                ),
                Tooltip(
                  message: "Delete".tl,
                  child: IconButton(
                    onPressed: () => widget.delete(source),
                    icon: const Icon(Icons.delete),
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: context.colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Column(children: buildSourceSettings().toList()),
        ),
        SliverToBoxAdapter(child: Column(children: _buildAccount().toList())),
      ],
    );
  }

  Iterable<Widget> buildSourceSettings() sync* {
    final Map<String, Map<String, dynamic>> settings;
    try {
      settings = source.getSettingsDynamic();
    } catch (error, stack) {
      Log.error("ComicSourcePage", error, stack);
      return;
    }
    for (final item in settings.entries) {
      final key = item.key;
      final setting = item.value;
      final current = setting['effectiveValue'];
      final title = (setting['title']?.toString() ?? key).ts(source.key);

      String? save(Object? value, {bool reset = false}) {
        try {
          if (reset) {
            source.resetSourceSetting(key);
          } else {
            source.setSourceSetting(key, value);
          }
          setState(() {});
          return null;
        } catch (_) {
          return "Invalid input".tl;
        }
      }

      Widget actions(Widget control) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: "Reset".tl,
            icon: const Icon(Icons.restart_alt),
            onPressed: () {
              final error = save(null, reset: true);
              if (error != null) context.showMessage(message: error);
            },
          ),
          control,
        ],
      );

      switch (setting['type']) {
        case 'select':
          final options = (setting['options'] as List? ?? [])
              .whereType<Map>()
              .where(
                (option) =>
                    option['value'] is String ||
                    option['value'] is num ||
                    option['value'] is bool,
              )
              .toList();
          if (options.isEmpty) continue;
          String label(Map option) =>
              (option['text'] ?? option['value']).toString().ts(source.key);
          final selected = options.indexWhere(
            (option) => option['value'] == current,
          );
          yield ListTile(
            title: Text(title),
            trailing: actions(
              Select(
                current: selected < 0 ? '' : label(options[selected]),
                values: options.map(label).toList(),
                onTap: (index) {
                  final error = save(options[index]['value']);
                  if (error != null) context.showMessage(message: error);
                },
              ),
            ),
          );
        case 'switch':
          yield ListTile(
            title: Text(title),
            trailing: actions(
              prism.Switch(
                value: current == true,
                onChanged: (value) {
                  final error = save(value);
                  if (error != null) context.showMessage(message: error);
                },
              ),
            ),
          );
        case 'input':
          final text = current?.toString() ?? '';
          RegExp? hintValidator;
          final pattern = setting['validator'];
          if (pattern is String) {
            try {
              hintValidator = RegExp(pattern);
            } on FormatException {
              // The backend handles JavaScript patterns Dart cannot preview.
            }
          }
          yield ListTile(
            title: Text(title),
            subtitle: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: actions(
              IconButton(
                icon: const Icon(Icons.edit),
                onPressed: () => showInputDialog(
                  context: context,
                  title: title,
                  initialValue: text,
                  inputValidator: hintValidator,
                  onConfirm: (value) => save(value),
                ),
              ),
            ),
          );
        case 'callback':
          yield _CallbackSetting(setting: item, sourceKey: source.key);
      }
    }
  }

  final _reLogin = <String, bool>{};

  Iterable<Widget> _buildAccount() sync* {
    if (source.account == null) return;
    final bool logged = source.isLogged;
    if (!logged) {
      yield ListTile(
        title: Text("Log in".tl),
        trailing: const Icon(Icons.arrow_right),
        onTap: () async {
          await context.to(
            () => _LoginPage(config: source.account!, source: source),
          );
          source.saveData();
          setState(() {});
        },
      );
    }
    if (logged) {
      for (var item in source.account!.infoItems) {
        if (item.builder != null) {
          yield item.builder!(context);
        } else {
          yield ListTile(
            title: Text(item.title.tl),
            subtitle: item.data == null ? null : Text(item.data!()),
            onTap: item.onTap,
          );
        }
      }
      if (source.data["account"] is List) {
        bool loading = _reLogin[source.key] == true;
        yield ListTile(
          title: Text("Re-login".tl),
          subtitle: Text("Click if login expired".tl),
          onTap: () async {
            if (source.data["account"] == null) {
              context.showMessage(message: "No data".tl);
              return;
            }
            setState(() {
              _reLogin[source.key] = true;
            });
            final List account = source.data["account"];
            var res = await source.account!.login!(account[0], account[1]);
            if (res.error) {
              context.showMessage(message: res.errorMessage!);
            } else {
              context.showMessage(message: "Success".tl);
            }
            setState(() {
              _reLogin[source.key] = false;
            });
          },
          trailing: loading
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
        );
      }
      yield ListTile(
        title: Text("Log out".tl),
        onTap: () {
          source.setData("account", null);
          source.account?.logout();
          source.saveData();
          ComicSourceManager().notifyStateChange();
          setState(() {});
        },
        trailing: const Icon(Icons.logout),
      );
    }
  }
}

class _LoginPage extends StatefulWidget {
  const _LoginPage({required this.config, required this.source});

  final AccountConfig config;

  final ComicSource source;

  @override
  State<_LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<_LoginPage> {
  String username = "";
  String password = "";
  bool loading = false;

  final Map<String, String> _cookies = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const Appbar(title: Text('')),
      body: Center(
        child: Container(
          padding: const EdgeInsets.all(16),
          constraints: const BoxConstraints(maxWidth: 400),
          child: AutofillGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("Login".tl, style: const TextStyle(fontSize: 24)),
                const SizedBox(height: 32),
                if (widget.config.cookieFields == null)
                  TextField(
                    decoration: InputDecoration(
                      labelText: "Username".tl,
                      border: const OutlineInputBorder(),
                    ),
                    enabled: widget.config.login != null,
                    onChanged: (s) {
                      username = s;
                    },
                    autofillHints: const [AutofillHints.username],
                  ).paddingBottom(16),
                if (widget.config.cookieFields == null)
                  TextField(
                    decoration: InputDecoration(
                      labelText: "Password".tl,
                      border: const OutlineInputBorder(),
                    ),
                    obscureText: true,
                    enabled: widget.config.login != null,
                    onChanged: (s) {
                      password = s;
                    },
                    onSubmitted: (s) => login(),
                    autofillHints: const [AutofillHints.password],
                  ).paddingBottom(16),
                for (var field in widget.config.cookieFields ?? <String>[])
                  TextField(
                    decoration: InputDecoration(
                      labelText: field,
                      border: const OutlineInputBorder(),
                    ),
                    obscureText: true,
                    enabled: widget.config.validateCookies != null,
                    onChanged: (s) {
                      _cookies[field] = s;
                    },
                  ).paddingBottom(16),
                if (widget.config.login == null &&
                    widget.config.cookieFields == null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline),
                      const SizedBox(width: 8),
                      Text("Login with password is disabled".tl),
                    ],
                  )
                else
                  Button.filled(
                    isLoading: loading,
                    onPressed: login,
                    child: Text("Continue".tl),
                  ),
                const SizedBox(height: 24),
                if (widget.config.loginWebsite != null)
                  TextButton(
                    onPressed: () {
                      if (App.isLinux) {
                        loginWithWebview2();
                      } else {
                        loginWithWebview();
                      }
                    },
                    child: Text("Login with webview".tl),
                  ),
                const SizedBox(height: 8),
                if (widget.config.registerWebsite != null)
                  TextButton(
                    onPressed: () =>
                        launchUrlString(widget.config.registerWebsite!),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.link),
                        const SizedBox(width: 8),
                        Text("Create Account".tl),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void login() {
    if (widget.config.login != null) {
      if (username.isEmpty || password.isEmpty) {
        showToast(
          message: "Cannot be empty".tl,
          icon: const Icon(Icons.error_outline),
          context: context,
        );
        return;
      }
      setState(() {
        loading = true;
      });
      widget.config.login!(username, password).then((value) {
        if (value.error) {
          context.showMessage(message: value.errorMessage!);
          setState(() {
            loading = false;
          });
        } else {
          if (mounted) {
            context.pop();
          }
        }
      });
    } else if (widget.config.validateCookies != null) {
      setState(() {
        loading = true;
      });
      var cookies = widget.config.cookieFields!
          .map((e) => _cookies[e] ?? '')
          .toList();
      widget.config.validateCookies!(cookies).then((value) {
        if (value) {
          widget.source.setData('account', 'ok');
          widget.source.saveData();
          context.pop();
        } else {
          context.showMessage(message: "Invalid cookies".tl);
          setState(() {
            loading = false;
          });
        }
      });
    }
  }

  void loginWithWebview() async {
    final jar = SingleInstanceCookieJar.instance!;
    final generation = jar.generation;
    var url = widget.config.loginWebsite!;
    var title = '';
    bool success = false;
    bool open = true;

    void validate(InAppWebViewController c) async {
      if (open &&
          !success &&
          widget.config.checkLoginStatus != null &&
          widget.config.checkLoginStatus!(url, title)) {
        final loginUrl = url;
        final cookies = await c.getCookies(loginUrl);
        final userAgent = await c.getUA();
        var localStorageItems = await c.webStorage.localStorage.getItems();
        var mappedLocalStorage = <String, dynamic>{};
        for (var item in localStorageItems) {
          if (item.key != null) {
            mappedLocalStorage[item.key!] = item.value;
          }
        }
        if (!open ||
            !mounted ||
            success ||
            !jar.saveFromWebview(
              Uri.parse(loginUrl),
              cookies,
              generation: generation,
              userAgent: userAgent,
            )) {
          return;
        }
        success = true;
        widget.source.setData('_localStorage', mappedLocalStorage);
        await widget.source.saveData();
        widget.config.onLoginWithWebviewSuccess?.call();
        App.mainNavigatorKey?.currentContext?.pop();
      }
    }

    await context.to(
      () => AppWebview(
        initialUrl: widget.config.loginWebsite!,
        onNavigation: (u, c) {
          url = u;
          validate(c);
          return false;
        },
        onTitleChange: (t, c) {
          title = t;
          validate(c);
        },
      ),
    );
    open = false;
    if (success) {
      widget.source.setData('account', 'ok');
      widget.source.saveData();
      context.pop();
    }
  }

  // for linux
  void loginWithWebview2() async {
    if (!await DesktopWebview.isAvailable()) {
      context.showMessage(message: "Webview is not available".tl);
    }

    final jar = SingleInstanceCookieJar.instance!;
    final generation = jar.generation;
    var url = widget.config.loginWebsite!;
    var title = '';
    bool success = false;
    bool open = true;

    void onClose() {
      open = false;
      if (success) {
        widget.source.setData('account', 'ok');
        widget.source.saveData();
        context.pop();
      }
    }

    void validate(DesktopWebview webview) async {
      if (open &&
          !success &&
          widget.config.checkLoginStatus != null &&
          widget.config.checkLoginStatus!(url, title)) {
        final loginUrl = url;
        final cookies = await webview.readCookies();
        var localStorageJson = await webview.evaluateJavascript(
          "JSON.stringify(window.localStorage);",
        );
        var localStorage = <String, dynamic>{};
        try {
          var decoded = jsonDecode(localStorageJson ?? '');
          if (decoded is Map<String, dynamic>) {
            localStorage = decoded;
          }
        } catch (e) {
          Log.error("ComicSourcePage", "Failed to parse localStorage JSON\n$e");
        }
        if (!open ||
            !mounted ||
            success ||
            !jar.saveFromWebview(
              Uri.parse(loginUrl),
              cookies,
              generation: generation,
              userAgent: webview.userAgent,
            )) {
          return;
        }
        success = true;
        widget.source.setData('_localStorage', localStorage);
        await widget.source.saveData();
        widget.config.onLoginWithWebviewSuccess?.call();
        webview.close();
      }
    }

    var webview = DesktopWebview(
      initialUrl: widget.config.loginWebsite!,
      onTitleChange: (t, webview) {
        title = t;
        validate(webview);
      },
      onNavigation: (u, webview) {
        url = u;
        validate(webview);
      },
      onClose: onClose,
    );

    webview.open();
  }
}
