part of 'components.dart';

class HoverBox extends StatefulWidget {
  const HoverBox(
      {super.key, required this.child, this.borderRadius = BorderRadius.zero});

  final Widget child;

  final BorderRadius borderRadius;

  @override
  State<HoverBox> createState() => _HoverBoxState();
}

class _HoverBoxState extends State<HoverBox> {
  bool isHover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => isHover = true),
      onExit: (_) => setState(() => isHover = false),
      cursor: SystemMouseCursors.click,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
            color: isHover
                ? Theme.of(context).colorScheme.surfaceContainerLow
                : null,
            borderRadius: widget.borderRadius),
        child: widget.child,
      ),
    );
  }
}

enum ButtonType { filled, outlined, text, normal }

class Button extends StatelessWidget {
  const Button(
      {super.key,
      required this.type,
      required this.child,
      this.isLoading = false,
      this.width,
      this.height,
      this.padding,
      this.color,
      this.onPressedAt,
      required this.onPressed});

  const Button.filled(
      {super.key,
      required this.child,
      required this.onPressed,
      this.width,
      this.height,
      this.padding,
      this.color,
      this.onPressedAt,
      this.isLoading = false})
      : type = ButtonType.filled;

  const Button.outlined(
      {super.key,
      required this.child,
      required this.onPressed,
      this.width,
      this.height,
      this.padding,
      this.color,
      this.onPressedAt,
      this.isLoading = false})
      : type = ButtonType.outlined;

  const Button.text(
      {super.key,
      required this.child,
      required this.onPressed,
      this.width,
      this.height,
      this.padding,
      this.color,
      this.onPressedAt,
      this.isLoading = false})
      : type = ButtonType.text;

  const Button.normal(
      {super.key,
      required this.child,
      required this.onPressed,
      this.width,
      this.height,
      this.padding,
      this.color,
      this.onPressedAt,
      this.isLoading = false})
      : type = ButtonType.normal;

  static Widget icon(
      {Key? key,
        required Widget icon,
        required VoidCallback onPressed,
        double? size,
        Color? color,
        String? tooltip,
        bool isLoading = false,
        HitTestBehavior behavior = HitTestBehavior.deferToChild}) {
    return _IconButton(
      key: key,
      icon: icon,
      onPressed: onPressed,
      size: size,
      color: color,
      tooltip: tooltip,
      behavior: behavior,
      isLoading: isLoading,
    );
  }

  final ButtonType type;

  final Widget child;

  final bool isLoading;

  final void Function() onPressed;

  final void Function(Offset location)? onPressedAt;

  final double? width;

  final double? height;

  final EdgeInsets? padding;

  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final normal = type == ButtonType.normal;
    final filled = type == ButtonType.filled || normal;
    final foreground = switch (type) {
      ButtonType.normal => colors.onSurface,
      ButtonType.filled => colors.onPrimary,
      ButtonType.outlined || ButtonType.text => color,
    };
    final style = prism.ButtonStyle.from(
      padding: padding,
      foregroundColor: foreground,
      backgroundColor: filled
          ? color ?? (normal ? Theme.of(context).cardColor : colors.primary)
          : null,
    );
    void activate() {
      final location = onPressedAt == null
          ? null
          : (context.findRenderObject() as RenderBox).localToGlobal(Offset.zero);
      onPressed();
      if (location != null) onPressedAt!(location);
    }
    final action = isLoading ? null : activate;
    final content = isLoading
        ? prism.ActivityIndicator(size: 16, color: foreground ?? colors.primary)
        : child;
    final button = switch (type) {
      ButtonType.filled || ButtonType.normal =>
        prism.FilledButton(onPressed: action, style: style, child: content),
      ButtonType.outlined =>
        prism.OutlinedButton(onPressed: action, style: style, child: content),
      ButtonType.text =>
        prism.TextButton(onPressed: action, style: style, child: content),
    };
    return SizedBox(width: width, height: height, child: button);
  }
}

class _IconButton extends StatefulWidget {
  const _IconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.size,
    this.color,
    this.tooltip,
    this.isLoading = false,
    this.behavior = HitTestBehavior.deferToChild,
  });

  final Widget icon;

  final VoidCallback onPressed;

  final double? size;

  final String? tooltip;

  final Color? color;

  final HitTestBehavior behavior;

  final bool isLoading;

  @override
  State<_IconButton> createState() => _IconButtonState();
}

class _IconButtonState extends State<_IconButton> {
  bool isHover = false;

  @override
  Widget build(BuildContext context) {
    var iconSize = widget.size ?? 24;
    Widget icon = IconTheme(
      data: IconThemeData(
        size: iconSize,
        color: widget.color ?? context.colorScheme.primary,
      ),
      child: widget.icon,
    );
    if (widget.isLoading) {
      icon = const CircularProgressIndicator(
        strokeWidth: 1.5,
      ).paddingAll(2).fixWidth(iconSize).fixHeight(iconSize);
    }
    return MouseRegion(
      onEnter: (_) => setState(() => isHover = true),
      onExit: (_) => setState(() => isHover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: widget.behavior,
        onTap: () {
          if (widget.isLoading) return;
          widget.onPressed();
        },
        child: Tooltip(
          message: widget.tooltip ?? "",
          child: Container(
            decoration: BoxDecoration(
              color: isHover
                  ? Theme.of(context)
                  .colorScheme
                  .outlineVariant
                  .toOpacity(0.4)
                  : null,
              borderRadius: BorderRadius.circular((iconSize + 12) / 2),
            ),
            padding: const EdgeInsets.all(6),
            child: icon,
          ),
        ),
      ),
    );
  }
}

class MenuButton extends StatefulWidget {
  const MenuButton({super.key, required this.entries});

  final List<MenuEntry> entries;

  @override
  State<MenuButton> createState() => _MenuButtonState();
}

class _MenuButtonState extends State<MenuButton> {
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'more'.tl,
      child: Button.icon(
        icon: const Icon(Icons.more_horiz),
        onPressed: () {
          var renderBox = context.findRenderObject() as RenderBox;
          var offset = renderBox.localToGlobal(Offset.zero);
          showMenuX(
            context,
            offset,
            widget.entries,
          );
        },
      ),
    );
  }
}
