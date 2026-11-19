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
                      FutureBuilder(
                        future: AppTheme.systemSeeds,
                        builder: (context, snapshot) {
                          final system = snapshot.data;
                          final isDark =
                              Theme.brightnessOf(context) == Brightness.dark;
                          final systemSeed =
                              (isDark ? system?.dark : system?.light) ??
                              AppTheme.blue;
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final entry in {
                                  'system': systemSeed,
                                  ...AppTheme.accents,
                                }.entries)
                                  _AccentSwatch(
                                    name: entry.key,
                                    color: entry.value,
                                  ),
                              ],
                            ),
                          );
                        },
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
            onPressed: () async {
              if (selected) return;
              appdata.settings['color'] = name;
              await appdata.saveData();
            },
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
                if (name == 'system')
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: CircleAvatar(
                      radius: 10,
                      backgroundColor: Theme.of(context).cardColor,
                      child: Icon(
                        Icons.colorize,
                        size: 12,
                        color: context.colorScheme.onSurface,
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
