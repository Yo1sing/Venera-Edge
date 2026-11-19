part of 'settings_page.dart';

class _SwitchSetting extends StatefulWidget {
  const _SwitchSetting({
    required this.title,
    required this.settingKey,
    this.onChanged,
    this.subtitle,
    this.comicId,
    this.comicSource,
    this.useDeviceSettings = false,
  });

  final String title;

  final String settingKey;

  final VoidCallback? onChanged;

  final String? subtitle;

  final String? comicId;

  final String? comicSource;

  final bool useDeviceSettings;

  @override
  State<_SwitchSetting> createState() => _SwitchSettingState();
}

class _SwitchSettingState extends State<_SwitchSetting> {
  @override
  Widget build(BuildContext context) {
    var value = widget.comicId != null
        ? appdata.settings.getReaderSetting(
            widget.comicId!,
            widget.comicSource!,
            widget.settingKey,
          )
        : widget.useDeviceSettings
        ? appdata.settings.getDeviceReaderSetting(widget.settingKey)
        : appdata.settings[widget.settingKey];

    assert(value is bool);

    return ListTile(
      title: Text(widget.title),
      subtitle: widget.subtitle == null ? null : Text(widget.subtitle!),
      trailing: prism.Switch(
        semanticLabel: widget.title,
        value: value,
        onChanged: (value) {
          setState(() {
            if (widget.comicId != null) {
              appdata.settings.setReaderSetting(
                widget.comicId!,
                widget.comicSource!,
                widget.settingKey,
                value,
              );
            } else if (widget.useDeviceSettings) {
              appdata.settings.setDeviceReaderSetting(widget.settingKey, value);
            } else {
              appdata.settings[widget.settingKey] = value;
            }
          });
          appdata.saveData().then((_) {
            widget.onChanged?.call();
          });
        },
      ),
    );
  }
}

class SelectSetting extends StatelessWidget {
  const SelectSetting({
    super.key,
    required this.title,
    required this.settingKey,
    required this.optionTranslation,
    this.onChanged,
    this.help,
    this.comicId,
    this.comicSource,
    this.useDeviceSettings = false,
  });

  final String title;

  final String settingKey;

  final Map<String, String> optionTranslation;

  final VoidCallback? onChanged;

  final String? help;

  final String? comicId;

  final String? comicSource;

  final bool useDeviceSettings;

  void _select(String value) {
    final settings = appdata.settings;
    if (comicId != null) {
      settings.setReaderSetting(comicId!, comicSource!, settingKey, value);
    } else if (useDeviceSettings) {
      settings.setDeviceReaderSetting(settingKey, value);
    } else {
      settings[settingKey] = value;
    }
    appdata.saveData();
    onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final settings = appdata.settings;
    final helpText = help;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final value = comicId != null
            ? settings.getReaderSetting(comicId!, comicSource!, settingKey)
            : useDeviceSettings
            ? settings.getDeviceReaderSetting(settingKey)
            : settings[settingKey];
        return ChoiceDropdown<String>(
          title: helpText == null
              ? Text(title)
              : Row(
                  children: [
                    Flexible(child: Text(title)),
                    const SizedBox(width: 4),
                    Button.icon(
                      size: 18,
                      icon: const Icon(Icons.help_outline),
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (context) => ContentDialog(
                          title: "Help".tl,
                          content: Text(helpText)
                              .paddingHorizontal(16)
                              .fixWidth(double.infinity),
                          actions: [
                            Button.filled(
                              onPressed: context.pop,
                              child: Text("OK".tl),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
          options: optionTranslation,
          value: value is String ? value : null,
          fallbackLabel: 'None',
          onChanged: _select,
        );
      },
    );
  }
}

class _SliderSetting extends StatefulWidget {
  const _SliderSetting({
    required this.title,
    required this.settingsIndex,
    required this.interval,
    required this.min,
    required this.max,
    this.onChanged,
    this.comicId,
    this.comicSource,
    this.useDeviceSettings = false,
  });

  final String title;

  final String settingsIndex;

  final double interval;

  final double min;

  final double max;

  final VoidCallback? onChanged;

  final String? comicId;

  final String? comicSource;

  final bool useDeviceSettings;

  @override
  State<_SliderSetting> createState() => _SliderSettingState();
}

class _SliderSettingState extends State<_SliderSetting> {
  @override
  Widget build(BuildContext context) {
    var value =
        (widget.comicId != null
                ? appdata.settings.getReaderSetting(
                    widget.comicId!,
                    widget.comicSource!,
                    widget.settingsIndex,
                  )
                : widget.useDeviceSettings
                ? appdata.settings.getDeviceReaderSetting(widget.settingsIndex)
                : appdata.settings[widget.settingsIndex])
            .toDouble();
    return ListTile(
      title: Text(widget.title, softWrap: true, maxLines: 2),
      trailing: Text(value.toString(), style: ts.s12),
      subtitle: Slider(
        value: value,
        onChanged: (value) {
          if (value.toInt() == value) {
            setState(() {
              if (widget.comicId != null) {
                appdata.settings.setReaderSetting(
                  widget.comicId!,
                  widget.comicSource!,
                  widget.settingsIndex,
                  value.toInt(),
                );
              } else if (widget.useDeviceSettings) {
                appdata.settings.setDeviceReaderSetting(
                  widget.settingsIndex,
                  value.toInt(),
                );
              } else {
                appdata.settings[widget.settingsIndex] = value.toInt();
              }
              appdata.saveData();
            });
          } else {
            setState(() {
              if (widget.comicId != null) {
                appdata.settings.setReaderSetting(
                  widget.comicId!,
                  widget.comicSource!,
                  widget.settingsIndex,
                  value,
                );
              } else if (widget.useDeviceSettings) {
                appdata.settings.setDeviceReaderSetting(
                  widget.settingsIndex,
                  value,
                );
              } else {
                appdata.settings[widget.settingsIndex] = value;
              }
              appdata.saveData();
            });
          }
          widget.onChanged?.call();
        },
        divisions: ((widget.max - widget.min) / widget.interval).toInt(),
        min: widget.min,
        max: widget.max,
      ),
    );
  }
}

class _PopupWindowSetting extends StatelessWidget {
  const _PopupWindowSetting({required this.title, required this.builder});

  final Widget Function() builder;

  final String title;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      trailing: const Icon(Icons.arrow_right),
      onTap: () {
        showPopUpWidget(App.rootContext, builder());
      },
    );
  }
}

class _MultiPagesFilter extends StatefulWidget {
  const _MultiPagesFilter({
    required this.title,
    required this.settingsIndex,
    required this.pages,
  });

  final String title;

  final String settingsIndex;

  // key - name
  final Map<String, String> pages;

  @override
  State<_MultiPagesFilter> createState() => _MultiPagesFilterState();
}

class _MultiPagesFilterState extends State<_MultiPagesFilter> {
  late List<String> keys;
  late Object? original;

  @override
  void initState() {
    original = appdata.settings[widget.settingsIndex];
    keys = List<String>.from(original as List? ?? []);
    keys.remove("");
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
    Future.microtask(() {
      updateSetting();
    });
  }

  var reorderWidgetKey = UniqueKey();
  var scrollController = ScrollController();
  final _key = GlobalKey();

  @override
  Widget build(BuildContext context) {
    var tiles = keys.map((e) => buildItem(e)).toList();

    var view = ReorderableBuilder<String>(
      key: reorderWidgetKey,
      scrollController: scrollController,
      longPressDelay: App.isDesktop
          ? const Duration(milliseconds: 100)
          : const Duration(milliseconds: 500),
      dragChildBoxDecoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        boxShadow: [
          BoxShadow(
            color: context.colorScheme.outlineVariant,
            blurRadius: 5,
            offset: const Offset(0, 2),
            spreadRadius: 2,
          ),
        ],
      ),
      onReorder: (reorderFunc) {
        setState(() {
          keys = List.from(reorderFunc(keys));
        });
      },
      children: tiles,
      builder: (children) {
        return GridView(
          key: _key,
          controller: scrollController,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 1,
            mainAxisExtent: 48,
          ),
          children: children,
        );
      },
    );

    return PopUpWidgetScaffold(
      title: widget.title,
      tailing: [
        if (keys.length < widget.pages.length)
          TextButton.icon(
            label: Text("Add".tl),
            icon: const Icon(Icons.add),
            onPressed: showAddDialog,
          ),
      ],
      body: view,
    );
  }

  Widget buildItem(String key) {
    Widget removeButton = Padding(
      padding: const EdgeInsets.only(right: 8),
      child: IconButton(
        onPressed: () {
          setState(() {
            keys.remove(key);
          });
        },
        icon: const Icon(Icons.delete_outline),
      ),
    );

    return ListTile(
      title: Text(widget.pages[key] ?? "(Invalid) $key"),
      key: Key(key),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [removeButton, const Icon(Icons.drag_handle)],
      ),
    );
  }

  void showAddDialog() {
    var canAdd = <String, String>{};
    widget.pages.forEach((key, value) {
      if (!keys.contains(key)) {
        canAdd[key] = value;
      }
    });
    var selected = <String>[];
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: "Add".tl,
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: canAdd.entries
                    .map(
                      (e) => CheckboxListTile(
                        value: selected.contains(e.key),
                        title: Text(e.value),
                        key: Key(e.key),
                        onChanged: (value) {
                          setState(() {
                            if (value!) {
                              selected.add(e.key);
                            } else {
                              selected.remove(e.key);
                            }
                          });
                        },
                      ),
                    )
                    .toList(),
              ),
              actions: [
                if (selected.length < canAdd.length)
                  TextButton(
                    child: Text("Select All".tl),
                    onPressed: () {
                      setState(() {
                        selected = canAdd.keys.toList();
                      });
                    },
                  )
                else
                  TextButton(
                    child: Text("Deselect All".tl),
                    onPressed: () {
                      setState(() {
                        selected.clear();
                      });
                    },
                  ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: selected.isNotEmpty
                      ? () {
                          this.setState(() {
                            keys.addAll(selected);
                          });
                          Navigator.pop(context);
                        }
                      : null,
                  child: Text("Add".tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> updateSetting() async {
    try {
      appdata.settings.replaceValue(widget.settingsIndex, previous: original, value: keys);
      await appdata.saveData();
    } catch (error) {
      App.rootContext.showMessage(message: error.toString());
    }
  }
}

class _CallbackSetting extends StatelessWidget {
  const _CallbackSetting({
    required this.title,
    required this.callback,
    required this.actionTitle,
    this.subtitle,
  });

  final String title;

  final String? subtitle;

  final VoidCallback callback;

  final String actionTitle;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: Button.normal(
        onPressed: callback,
        child: Text(actionTitle),
      ).fixHeight(28),
      onTap: callback,
    );
  }
}

class _SettingPartTitle extends StatelessWidget {
  const _SettingPartTitle({required this.title, required this.icon});

  final String title;

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        padding: const EdgeInsets.only(left: 16, top: 16, bottom: 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: context.colorScheme.onSurface.withValues(alpha: 0.1),
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 24),
            const SizedBox(width: 8),
            Text(title, style: ts.s18),
          ],
        ),
      ),
    );
  }
}
