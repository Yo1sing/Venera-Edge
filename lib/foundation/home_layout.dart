class HomeLayout {
  static const titles = {
    'search': 'Search',
    'sync': 'Data Sync',
    'history': 'History',
    'local': 'Local',
    'updates': 'Follow Updates',
    'sources': 'Comic Source',
    'images': 'Image Favorites',
  };

  // Keep these modules in imported layouts for round trips through Prime.
  static const _primeOnly = {'random', 'readLater', 'statistics'};

  final _order = <String>[];
  final hidden = <String>{};
  final folders = <String, String>{};
  bool compact = false;

  HomeLayout.fromJson(Object? value) {
    final data = value is Map ? value : const {};
    compact = data['compact'] == true;
    final savedFolders = data['folders'];
    if (savedFolders is Map) {
      for (final entry in savedFolders.entries) {
        final name = entry.value;
        if (name is String && name.isNotEmpty && entry.key == 'folder:$name') {
          folders['folder:$name'] = name;
        }
      }
    }

    final valid = {...titles.keys, ..._primeOnly, ...folders.keys};
    final savedOrder = data['order'];
    _order.addAll({
      if (savedOrder is List)
        ...savedOrder.whereType<String>().where(valid.contains),
      ...titles.keys,
      ...folders.keys,
    });
    final savedHidden = data['hidden'];
    if (savedHidden is List) {
      hidden.addAll(savedHidden.whereType<String>().where(valid.contains));
    }
  }

  List<String> get order =>
      _order.where((id) => !_primeOnly.contains(id)).toList();

  String title(String id) => folders[id] ?? titles[id] ?? id;

  void addFolder(String name) {
    if (name.isEmpty) return;
    final id = 'folder:$name';
    folders[id] = name;
    if (!_order.contains(id)) _order.add(id);
    hidden.remove(id);
  }

  void removeFolder(String id) {
    if (folders.remove(id) == null) return;
    _order.remove(id);
    hidden.remove(id);
  }

  void move(String id, String to) {
    final modules = order;
    final destination = modules.indexOf(to);
    if (id == to || destination < 0 || !modules.remove(id)) return;
    modules.insert(destination, id);
    // Leave unavailable Prime modules in their original slots.
    var index = 0;
    for (var i = 0; i < _order.length; i++) {
      if (!_primeOnly.contains(_order[i])) _order[i] = modules[index++];
    }
  }

  Map<String, dynamic> toJson() => {
    'compact': compact,
    'folders': Map.of(folders),
    'order': List.of(_order),
    'hidden': hidden.toList(),
  };
}
