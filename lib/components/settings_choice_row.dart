import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart' as prism;
import 'package:prism_ui/prism_ui.dart' as prism;

/// A single-choice settings row. The value button anchors the menu even when
/// the user opens it by tapping the title.
class SettingsChoiceRow<T> extends StatelessWidget {
  const SettingsChoiceRow({
    super.key,
    required this.title,
    required this.options,
    required this.value,
    required this.onChanged,
    this.fallbackLabel = '',
    this.trailingAction,
  });

  final Widget title;
  final Map<T, String> options;
  final T? value;
  final ValueChanged<T> onChanged;
  final String fallbackLabel;
  final Widget? trailingAction;

  @override
  Widget build(BuildContext context) {
    prism.PopupOpen? openMenu;
    final anchor = prism.PopupAnchor(
      targetBuilder: (open) {
        openMenu = open;
        return prism.TextButton(
          onPressed: options.isEmpty ? null : open,
          style: prism.ButtonStyle.from(
            foregroundColor: prism.Theme.of(
              context,
            ).colorScheme.onSurfaceVariant,
            textStyle: prism.BuildContextExtension(context).listTitleStyle,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: prism.PopupValueText(
                    options[value] ?? fallbackLabel,
                    alignment: AlignmentDirectional.centerEnd,
                  ),
                ),
              ),
              const prism.GlyphIcon(prism.Glyphs.picker),
            ],
          ),
        );
      },
      popupBuilder: (_) => prism.PopupMenu(
        items: [
          for (final entry in options.entries)
            prism.PopupMenuItem(
              label: entry.value,
              checked: entry.key == value,
              onPressed: () => onChanged(entry.key),
            ),
        ],
      ),
    );
    return prism.ItemPositionProvider(
      position: prism.ItemPosition.startAndEnd,
      child: prism.DecorationListItem(
        title: title,
        contentPadding: const EdgeInsets.only(left: 16, right: 8),
        onPressed: options.isEmpty ? null : () => openMenu?.call(),
        trailing: trailingAction == null
            ? anchor
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  trailingAction!,
                  Flexible(child: anchor),
                ],
              ),
      ),
    );
  }
}
