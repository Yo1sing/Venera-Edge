import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart' as prism;
import 'package:prism_ui/prism_ui.dart' as prism;

/// Project dropdown. Supplying a title makes the entire row open the value's menu.
class ChoiceDropdown<T> extends StatelessWidget {
  const ChoiceDropdown({
    super.key,
    this.title,
    required this.options,
    required this.value,
    required this.onChanged,
    this.fallbackLabel = '',
    this.trailingAction,
    this.minWidth = 0,
  }) : assert(trailingAction == null || title != null),
       assert(minWidth >= 0);

  final Widget? title;
  final Map<T, String> options;
  final T? value;
  final ValueChanged<T>? onChanged;
  final double minWidth;
  final String fallbackLabel;
  final Widget? trailingAction;

  @override
  Widget build(BuildContext context) {
    final enabled = options.isNotEmpty && onChanged != null;
    final theme = prism.Theme.of(context);
    prism.PopupOpen? openMenu;
    final anchor = prism.PopupAnchor(
      targetBuilder: (open) {
        openMenu = open;
        return ConstrainedBox(
          constraints: BoxConstraints(minWidth: minWidth),
          child: prism.TextButton(
            onPressed: enabled ? open : null,
            style: prism.ButtonStyle.from(
              foregroundColor: theme.colorScheme.onSurfaceVariant,
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
          ),
        );
      },
      popupBuilder: (_) => prism.PopupMenu(
        items: [
          for (final entry in options.entries)
            prism.PopupMenuItem(
              label: entry.value,
              checked: entry.key == value,
              onPressed: () => onChanged?.call(entry.key),
            ),
        ],
      ),
    );
    final rowTitle = title;
    if (rowTitle == null) return anchor;
    // Dialogs and flyouts measure the intrinsic width of the row.
    return prism.Card(
      shape: prism.AppShape.xl,
      padding: EdgeInsets.zero,
      onPressed: enabled ? () => openMenu?.call() : null,
      child: prism.ListRow(
        title: rowTitle,
        padding: const EdgeInsets.only(left: 16, right: 8),
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
