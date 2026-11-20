import 'dart:convert';
import 'dart:io' as io;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show AnyhowException;
import 'package:material_ui/material_ui.dart';
import 'package:prism_ui/prism_ui.dart'
    as prism
    show
        AppShape,
        IconButton,
        PopupAnchor,
        PopupMenu,
        PopupMenuItem,
        SnapSheetRoute,
        Switch;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_edge/components/components.dart';
import 'package:venera_edge/foundation/app.dart';
import 'package:venera_edge/foundation/appdata.dart';
import 'package:venera_edge/foundation/comic_source/comic_source.dart';
import 'package:venera_edge/foundation/log.dart';
import 'package:venera_edge/src/rust/api/http.dart' show HttpCancellation;
import 'package:venera_edge/network/cookie_jar.dart';
import 'package:venera_edge/pages/webview.dart';
import 'package:venera_edge/utils/io.dart';
import 'package:venera_edge/utils/translations.dart';

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
        SliverAppbar(
          title: Text('Comic Source'.tl),
          style: AppbarStyle.shadow,
          actions: [
            prism.IconButton(
              tooltip: 'Manage subscription URLs'.tl,
              icon: const Icon(Icons.link),
              onPressed: () =>
                  showPopUpWidget(context, const _SubscriptionUrls()),
            ),
            prism.PopupAnchor(
              targetBuilder: (open) => prism.IconButton(
                tooltip: 'Add comic source'.tl,
                icon: const Icon(Icons.add_circle_outline),
                onPressed: open,
              ),
              popupBuilder: (_) => prism.PopupMenu(
                items: [
                  prism.PopupMenuItem(label: 'File'.tl, onPressed: _selectFile),
                  prism.PopupMenuItem(
                    label: 'Link'.tl,
                    onPressed: _openCatalog,
                  ),
                ],
              ),
            ),
          ],
        ),
        buildCard(),
        for (final source in ComicSource.all())
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

  Widget buildCard() {
    return SliverToBoxAdapter(
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.tonalIcon(
            icon: const Icon(Icons.article_outlined),
            label: Text("Comic Source list".tl),
            onPressed: _openCatalog,
          ),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.help_outline),
            label: Text("Help".tl),
            onPressed: help,
          ),
          const _CheckUpdatesButton(),
        ],
      ).paddingHorizontal(12).paddingVertical(8),
    );
  }

  void _openCatalog() => showPopUpWidget(context, const _ComicSourceList());

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
}

typedef _CatalogSource = ({
  String subscription,
  String key,
  String name,
  String url,
  String details,
});

class _ComicSourceList extends StatefulWidget {
  const _ComicSourceList();

  @override
  State<_ComicSourceList> createState() => _ComicSourceListState();
}

class _ComicSourceListState extends State<_ComicSourceList> {
  final _manager = ComicSourceManager();
  late List<String> _urls;
  final _expandedUrls = <String>{};
  final _catalogs = <String, List<_CatalogSource>>{};
  final _failedUrls = <String>{};
  final _loads = <String, HttpCancellation>{};
  final _selected = <String, _CatalogSource>{};
  HttpCancellation? _installation;
  bool _cancelling = false;

  @override
  void initState() {
    super.initState();
    _urls = _readUrls();
    _expandedUrls.addAll(_urls.take(1));
    appdata.settings.addListener(_syncUrls);
    _manager.addListener(_syncInstalled);
    for (final url in _urls) {
      _load(url);
    }
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_syncUrls);
    _manager.removeListener(_syncInstalled);
    _installation?.cancel();
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
    final current = urls.toSet();
    setState(() {
      for (final url in previous.difference(current)) {
        _expandedUrls.remove(url);
        _loads.remove(url)?.cancel();
        _catalogs.remove(url);
        _failedUrls.remove(url);
      }
      _selected.removeWhere(
        (_, source) => !current.contains(source.subscription),
      );
      if (_urls.isEmpty) _expandedUrls.addAll(urls.take(1));
      _urls = urls;
    });
    for (final url in urls) {
      if (!previous.contains(url)) _load(url);
    }
  }

  void _syncInstalled() {
    setState(
      () => _selected.removeWhere((key, _) => _manager.find(key) != null),
    );
  }

  Future<void> _load(String url) async {
    _loads.remove(url)?.cancel();
    final cancellation = HttpCancellation();
    _loads[url] = cancellation;
    setState(() {
      _catalogs.remove(url);
      _failedUrls.remove(url);
      _selected.removeWhere((_, source) => source.subscription == url);
    });
    try {
      final entries = await _manager.catalog(url, cancellation);
      if (!mounted || !identical(_loads[url], cancellation)) return;
      setState(() {
        _catalogs[url] = [
          for (final entry in entries)
            (
              subscription: url,
              key: entry['key'] as String,
              name: entry['name'] as String,
              url: entry['url'] as String,
              details: [entry['version'], ?entry['description']].join('\n'),
            ),
        ];
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

  Future<void> _installSelected() async {
    if (_installation != null || _selected.isEmpty) return;
    final sources = _selected.values.toList();
    final cancellation = HttpCancellation();
    setState(() {
      _installation = cancellation;
      _cancelling = false;
    });
    var added = 0;
    final failures = <String>[];
    try {
      for (final source in sources) {
        if (!mounted || _cancelling) break;
        if (_manager.find(source.key) != null) continue;
        try {
          await _manager.installUrl(source.url, cancellation);
          added++;
          if (mounted) setState(() => _selected.remove(source.key));
        } catch (error, stack) {
          if (!mounted || _cancelling) break;
          Log.error('Add comic source', error, stack);
          final message = error is AnyhowException
              ? error.message.split('\n\nStack backtrace:').first
              : error.toString();
          failures.add('${source.name}\n$message');
        }
      }
    } finally {
      cancellation.dispose();
      if (mounted) setState(() => _installation = null);
      if (added > 0) App.forceRebuild();
    }
    if (!mounted) return;
    final summary = 'Comic sources added (@n)'.tlParams({'n': added});
    if (failures.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Unable to add comic sources'.tl),
          scrollable: true,
          content: Text([if (added > 0) summary, ...failures].join('\n\n')),
          actions: [
            TextButton(onPressed: dialogContext.pop, child: Text('OK'.tl)),
          ],
        ),
      );
    } else if (added > 0) {
      context.showMessage(message: summary);
    }
  }

  void _openSubscriptions() =>
      showPopUpWidget(context, const _SubscriptionUrls());

  @override
  Widget build(BuildContext context) {
    final busy = _installation != null;
    return PopUpWidgetScaffold(
      title: "Comic Source list".tl,
      tailing: [
        IconButton(
          tooltip: 'Manage subscription URLs'.tl,
          icon: const Icon(Icons.link),
          onPressed: busy ? null : _openSubscriptions,
        ),
      ],
      body: buildBody(),
    );
  }

  Widget buildBody() {
    if (_urls.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            Text(
              'No subscription URLs configured'.tl,
              textAlign: TextAlign.center,
            ),
            FilledButton.tonalIcon(
              onPressed: _openSubscriptions,
              icon: const Icon(Icons.add),
              label: Text('Add subscription URL'.tl),
            ),
          ],
        ).paddingHorizontal(16),
      );
    }
    final installed = _manager.all().map((source) => source.key).toSet();
    return Column(
      children: [
        Expanded(
          child: CustomScrollView(
            slivers: [
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
              for (final url in _urls) _buildRepository(url, installed),
            ],
          ),
        ),
        const Divider(height: 1),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: _buildActions(installed),
          ),
        ),
      ],
    );
  }

  Widget _buildActions(Set<String> installed) {
    final installation = _installation;
    if (installation != null) {
      return Row(
        spacing: 12,
        children: [
          Expanded(
            child: LinearProgressIndicator(
              semanticsLabel: 'Adding comic sources'.tl,
            ),
          ),
          TextButton(
            onPressed: _cancelling
                ? null
                : () {
                    setState(() => _cancelling = true);
                    installation.cancel();
                  },
            child: Text('Cancel'.tl),
          ),
        ],
      );
    }
    final available = <String, _CatalogSource>{};
    for (final url in _urls) {
      for (final source in _catalogs[url] ?? const <_CatalogSource>[]) {
        if (!installed.contains(source.key)) {
          available.putIfAbsent(source.key, () => source);
        }
      }
    }
    final allSelected =
        available.isNotEmpty && _selected.length == available.length;
    return Align(
      alignment: AlignmentDirectional.centerEnd,
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 4,
        children: [
          TextButton(
            onPressed: available.isEmpty
                ? null
                : () => setState(() {
                    if (allSelected) {
                      _selected.clear();
                    } else {
                      for (final entry in available.entries) {
                        _selected.putIfAbsent(entry.key, () => entry.value);
                      }
                    }
                  }),
            child: Text((allSelected ? 'Deselect All' : 'Select All').tl),
          ),
          FilledButton(
            onPressed: _selected.isEmpty ? null : _installSelected,
            child: Text('Add selected (@n)'.tlParams({'n': _selected.length})),
          ),
        ],
      ),
    );
  }

  Widget _buildRepository(String url, Set<String> installed) {
    final entries = _catalogs[url];
    final expanded = _expandedUrls.contains(url);
    return SliverPadding(
      key: ValueKey(url),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      sliver: DecoratedSliver(
        decoration: ShapeDecoration(
          color: Theme.of(context).cardColor,
          shape: prism.AppShape.lg,
        ),
        sliver: SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: _buildRepositoryHeader(url, expanded, entries == null),
            ),
            if (expanded && entries != null) ...[
              const SliverToBoxAdapter(
                child: Divider(height: 1, indent: 16, endIndent: 16),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(6, 2, 6, 6),
                sliver: _buildRepositoryEntries(url, entries, installed),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRepositoryHeader(String url, bool expanded, bool loading) {
    return Material(
      type: MaterialType.transparency,
      shape: prism.AppShape.lg,
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        expanded: expanded,
        child: ListTile(
          contentPadding: const EdgeInsetsDirectional.fromSTEB(14, 6, 10, 6),
          leading: Icon(Icons.link, color: context.colorScheme.primary),
          title: Tooltip(
            message: url,
            child: Text(url, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Refresh'.tl,
                onPressed: _installation != null || loading
                    ? null
                    : () => _load(url),
                icon: loading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
              AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeInOut,
                child: const Icon(Icons.expand_more),
              ),
            ],
          ),
          onTap: () => setState(() {
            if (expanded) {
              _expandedUrls.remove(url);
            } else {
              _expandedUrls.add(url);
            }
          }),
        ),
      ),
    );
  }

  Widget _buildRepositoryEntries(
    String url,
    List<_CatalogSource> entries,
    Set<String> installed,
  ) {
    if (_failedUrls.contains(url)) {
      return SliverToBoxAdapter(
        child: ListTile(
          leading: const Icon(Icons.error_outline),
          title: Text('Unable to load comic source list'.tl),
          subtitle: Text('Tap refresh to retry'.tl),
        ),
      );
    }
    if (entries.isEmpty) {
      return SliverToBoxAdapter(
        child: ListTile(title: Text('No sources found'.tl)),
      );
    }
    return SliverList.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) => Material(
        type: MaterialType.transparency,
        child: _buildEntry(entries[index], installed),
      ),
    );
  }

  Widget _buildEntry(_CatalogSource source, Set<String> installed) {
    final title = Text(source.name);
    final subtitle = Text(source.details);
    if (installed.contains(source.key)) {
      return ListTile(
        title: title,
        subtitle: subtitle,
        trailing: Tooltip(message: 'Added'.tl, child: const Icon(Icons.check)),
      );
    }
    return CheckboxListTile(
      title: title,
      subtitle: subtitle,
      value: _selected[source.key] == source,
      onChanged: _installation != null
          ? null
          : (checked) => setState(() {
              if (checked == true) {
                _selected[source.key] = source;
              } else {
                _selected.remove(source.key);
              }
            }),
    );
  }
}

List<String> _readUrls() =>
    (appdata.settings['comicSourceListUrls'] as List? ?? [])
        .whereType<String>()
        .toList();

bool _isHttpUrl(String url) {
  final uri = Uri.tryParse(url);
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}

class _SubscriptionUrls extends StatefulWidget {
  const _SubscriptionUrls();

  @override
  State<_SubscriptionUrls> createState() => _SubscriptionUrlsState();
}

class _SubscriptionUrlsState extends State<_SubscriptionUrls> {
  bool _saving = false;

  Future<bool> _save(VoidCallback edit) async {
    if (_saving) return false;
    setState(() => _saving = true);
    try {
      edit();
      await appdata.saveData();
      return true;
    } catch (error, stack) {
      Log.error('Save subscription URLs', error, stack);
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openAddSheet() async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final sheet = _AddSubscriptionUrlSheet(
      onAdd: (url) => _save(() {
        // A failed save can leave the URL in the settings preview.
        if (!_readUrls().contains(url)) {
          appdata.settings.addComicSourceListUrl(url);
        }
      }),
    );
    if (context.width > 500) {
      await navigator.push(SideBarRoute<void>(sheet, width: 420));
    } else {
      await navigator.push(
        prism.SnapSheetRoute<void>(
          fitsContent: true,
          sheetBarrierColor: context.colorScheme.scrim.withValues(alpha: 0.4),
          barrierLabel: MaterialLocalizations.of(
            context,
          ).modalBarrierDismissLabel,
          builder: (_, _) => SafeArea(top: false, child: sheet),
        ),
      );
    }
  }

  Future<void> _removeUrl(String url) async {
    final removed = await _save(
      () => appdata.settings.removeComicSourceListUrl(url),
    );
    if (!removed && mounted) {
      context.showMessage(message: 'Unable to save subscription URLs'.tl);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: 'Subscription URLs'.tl,
      tailing: [
        prism.IconButton(
          tooltip: 'Add subscription URL'.tl,
          icon: const Icon(Icons.add_circle_outline),
          onPressed: _saving ? null : _openAddSheet,
        ),
      ],
      body: ListenableBuilder(
        listenable: appdata.settings,
        builder: (context, _) {
          final urls = _readUrls();
          if (urls.isEmpty) {
            return Center(
              child: Text(
                'No subscription URLs configured'.tl,
                textAlign: TextAlign.center,
              ).paddingHorizontal(16),
            );
          }
          return ListView.separated(
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              16 + context.padding.bottom,
            ),
            itemCount: urls.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final url = urls[index];
              return Card(
                key: ValueKey(url),
                margin: EdgeInsets.zero,
                shape: prism.AppShape.lg,
                child: ListTile(
                  contentPadding: const EdgeInsetsDirectional.fromSTEB(
                    16,
                    8,
                    8,
                    8,
                  ),
                  leading: Icon(Icons.link, color: context.colorScheme.primary),
                  title: SelectableText(url),
                  trailing: IconButton(
                    tooltip: 'Remove'.tl,
                    onPressed: _saving ? null : () => _removeUrl(url),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _AddSubscriptionUrlSheet extends StatefulWidget {
  const _AddSubscriptionUrlSheet({required this.onAdd});

  final Future<bool> Function(String url) onAdd;

  @override
  State<_AddSubscriptionUrlSheet> createState() =>
      _AddSubscriptionUrlSheetState();
}

class _AddSubscriptionUrlSheetState extends State<_AddSubscriptionUrlSheet> {
  final _controller = TextEditingController();
  String? _inputError;
  String? _failedUrl;
  bool _submitting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final url = _controller.text.trim();
    if (!_isHttpUrl(url)) {
      setState(() => _inputError = 'Invalid URL');
      return;
    }
    if (url != _failedUrl && _readUrls().contains(url)) {
      setState(() => _inputError = 'This URL is already added');
      return;
    }
    setState(() {
      _submitting = true;
      _inputError = null;
    });
    final saved = await widget.onAdd(url);
    if (!mounted) return;
    if (saved && ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _submitting = false;
        _failedUrl = saved ? null : url;
        _inputError = saved ? null : 'Unable to save subscription URLs';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_submitting,
      child: Material(
        type: MaterialType.transparency,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              Text(
                'Add subscription URL'.tl,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              TextField(
                controller: _controller,
                readOnly: _submitting,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: 'URL of index.json'.tl,
                  errorText: _inputError?.tl,
                  errorMaxLines: 3,
                ),
                onChanged: (_) {
                  if (_inputError != null) setState(() => _inputError = null);
                },
                onSubmitted: (_) => _submit(),
              ),
              Text(
                "The URL should point to an 'index.json' file. Installed sources are kept when a repository is removed."
                    .tl,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: Text('Cancel'.tl),
                  ),
                  FilledButton(
                    onPressed: _submitting ? null : _submit,
                    child: Text('Add'.tl),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
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

      final resetButton = IconButton(
        tooltip: "Reset".tl,
        icon: const Icon(Icons.restart_alt),
        onPressed: () {
          final error = save(null, reset: true);
          if (error != null) context.showMessage(message: error);
        },
      );
      Widget actions(Widget control) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [resetButton, control],
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
          yield ChoiceDropdown<int>(
            title: Text(title),
            trailingAction: resetButton,
            options: options.asMap().map(
              (index, option) => MapEntry(index, label(option)),
            ),
            value: selected,
            onChanged: (index) {
              final error = save(options[index]['value']);
              if (error != null) context.showMessage(message: error);
            },
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
