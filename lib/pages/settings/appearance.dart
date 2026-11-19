part of 'settings_page.dart';

class AppearanceSettings extends StatelessWidget {
  const AppearanceSettings({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appdata.settings,
      builder: (context, _) => SmoothCustomScrollView(
        slivers: [
          SliverAppbar(title: Text("Appearance".tl)),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
            sliver: SliverList.list(
              children: [
                Card(
                  child: Column(
                    children: [
                      SelectSetting(
                        title: "Theme Mode".tl,
                        settingKey: "theme_mode",
                        optionTranslation: {
                          "system": "System".tl,
                          "light": "Light".tl,
                          "dark": "Dark".tl,
                        },
                      ),
                      _SwitchSetting(
                        title: "Pure Black".tl,
                        settingKey: "pureBlack",
                      ),
                    ],
                  ),
                ),
                Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                        child: Text(
                          "Theme Color".tl,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ),
                      ListTile(
                        title: Text('System accent color'.tl),
                        subtitle: Text(
                          'Follow the wallpaper or system accent'.tl,
                        ),
                        leading: CircleAvatar(
                          radius: 16,
                          backgroundColor: AppTheme.seedOf(
                            context,
                            'system',
                            Theme.brightnessOf(context),
                          ),
                        ),
                        selected: appdata.settings['color'] == 'system',
                        trailing: appdata.settings['color'] == 'system'
                            ? const Icon(Icons.check_rounded)
                            : null,
                        onTap: () => _selectThemeColor('system'),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final entry in AppTheme.accents.entries)
                              _AccentSwatch(
                                name: entry.key,
                                color: entry.value,
                              ),
                          ],
                        ),
                      ),
                      SelectSetting(
                        title: "Color Style".tl,
                        settingKey: "colorStyle",
                        optionTranslation: {
                          "vivid": "Vivid".tl,
                          "tinted": "Tinted".tl,
                          "soft": "Soft".tl,
                          "monochrome": "Monochrome".tl,
                        },
                      ),
                    ],
                  ),
                ),
                Card(
                  child: SelectSetting(
                    title: "Bottom Navigation Style".tl,
                    settingKey: "bottomNavigationStyle",
                    optionTranslation: {
                      "standard": "Standard".tl,
                      "floating": "Floating".tl,
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _selectThemeColor(String name) async {
  if (appdata.settings['color'] == name) return;
  appdata.settings['color'] = name;
  await appdata.saveData();
}

class _AccentSwatch extends StatelessWidget {
  const _AccentSwatch({required this.name, required this.color});

  final String name;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final selected = appdata.settings['color'] == name;
    final label = (name[0].toUpperCase() + name.substring(1)).tl;
    final checkColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;
    const duration = Duration(milliseconds: 200);
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        label: label,
        child: SizedBox.square(
          dimension: 44,
          child: prism.PressSurface(
            shape: prism.AppShape.circle,
            fill: Colors.transparent,
            selected: selected,
            ringStandsOff: selected,
            childFills: true,
            onPressed: () => _selectThemeColor(name),
            child: Stack(
              alignment: Alignment.center,
              children: [
                AnimatedOpacity(
                  opacity: selected ? 1 : 0,
                  duration: duration,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: color, width: 2.5),
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
                SizedBox.square(
                  dimension: 32,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                AnimatedScale(
                  scale: selected ? 1 : 0,
                  duration: duration,
                  curve: Curves.easeOutBack,
                  child: Icon(Icons.check_rounded, size: 18, color: checkColor),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
