import 'package:material_ui/material_ui.dart';
import 'package:venera_edge/components/components.dart';
import 'package:venera_edge/foundation/app.dart';
import 'package:venera_edge/foundation/appdata.dart';
import 'package:venera_edge/foundation/favorites.dart';
import 'package:venera_edge/foundation/home_layout.dart';
import 'package:venera_edge/utils/translations.dart';

class HomeLayoutPage extends StatelessWidget {
  const HomeLayoutPage({super.key});

  Future<void> _save(
    BuildContext context, [
    void Function(HomeLayout)? change,
  ]) async {
    try {
      if (change == null) {
        appdata.settings.reset('homeLayout');
      } else {
        final layout = HomeLayout.fromJson(appdata.settings['homeLayout']);
        change(layout);
        appdata.settings['homeLayout'] = layout.toJson();
      }
      await appdata.saveData();
    } catch (error) {
      if (context.mounted) context.showMessage(message: error.toString());
    }
  }

  Future<void> _addFolder(BuildContext context) async {
    final folders = LocalFavoritesManager().folderNames;
    final name = await showPopUpWidget<String?>(
      context,
      PopUpWidgetScaffold(
        title: 'Add favorite folder'.tl,
        body: folders.isEmpty
            ? Center(child: Text('No favorite folders'.tl))
            : ListView.builder(
                itemCount: folders.length,
                itemBuilder: (context, index) => ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(folders[index]),
                  onTap: () => Navigator.of(
                    context,
                    rootNavigator: true,
                  ).pop(folders[index]),
                ),
              ),
      ),
    );
    if (name != null && context.mounted) {
      await _save(context, (layout) => layout.addFolder(name));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text('Customize home'.tl),
        actions: [
          IconButton(
            tooltip: 'Add favorite folder'.tl,
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: () => _addFolder(context),
          ),
          IconButton(
            tooltip: 'Restore defaults'.tl,
            icon: const Icon(Icons.restore),
            onPressed: () => _save(context),
          ),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: appdata.settings,
          builder: (context, _) {
            final layout = HomeLayout.fromJson(appdata.settings['homeLayout']);
            final order = layout.order;
            return ReorderableListView.builder(
              buildDefaultDragHandles: false,
              header: SwitchListTile(
                title: Text('Compact home'.tl),
                subtitle: Text('Reduce control height and spacing'.tl),
                value: layout.compact,
                onChanged: (value) =>
                    _save(context, (next) => next.compact = value),
              ),
              itemCount: order.length,
              onReorderItem: (from, to) =>
                  _save(context, (next) => next.move(order[from], order[to])),
              itemBuilder: (context, index) {
                final id = order[index];
                final folder = layout.folders[id];
                final title = folder ?? layout.title(id).tl;
                return ListTile(
                  key: ValueKey(id),
                  leading: ReorderableDragStartListener(
                    index: index,
                    child: Tooltip(
                      message: 'Reorder'.tl,
                      child: const SizedBox.square(
                        dimension: 48,
                        child: Icon(Icons.drag_handle),
                      ),
                    ),
                  ),
                  title: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (folder != null)
                        IconButton(
                          tooltip: 'Delete'.tl,
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () =>
                              _save(context, (next) => next.removeFolder(id)),
                        ),
                      Semantics(
                        label: title,
                        child: Switch(
                          key: ValueKey('toggle-$id'),
                          value: !layout.hidden.contains(id),
                          onChanged: (enabled) => _save(context, (next) {
                            if (enabled) {
                              next.hidden.remove(id);
                            } else if (next.order.contains(id)) {
                              next.hidden.add(id);
                            }
                          }),
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
