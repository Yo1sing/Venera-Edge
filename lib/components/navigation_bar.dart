part of 'components.dart';

class PaneItemEntry {
  final String label;
  final Glyph glyph;

  PaneItemEntry({required this.label, required this.glyph});
}

class PaneActionEntry {
  String label;

  IconData icon;

  VoidCallback onTap;

  PaneActionEntry({
    required this.label,
    required this.icon,
    required this.onTap,
  });
}

class NaviPane extends StatefulWidget {
  const NaviPane({
    required this.paneItems,
    required this.paneActions,
    required this.pageBuilder,
    this.initialPage = 0,
    this.onPageChanged,
    required this.observer,
    required this.navigatorKey,
    super.key,
  });

  final List<PaneItemEntry> paneItems;

  final List<PaneActionEntry> paneActions;

  final Widget Function(int page) pageBuilder;

  final void Function(int index)? onPageChanged;

  final int initialPage;

  final NaviObserver observer;

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<NaviPane> createState() => NaviPaneState();

  static NaviPaneState of(BuildContext context) {
    return context.findAncestorStateOfType<NaviPaneState>()!;
  }

  static double floatingBottomInsetOf(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final state = context.findAncestorStateOfType<NaviPaneState>();
    return state != null &&
            state._floatingBottomBar &&
            state.controller.value < 2
        ? padding.bottom
        : 0;
  }
}

typedef NaviItemTapListener = void Function(int);

class NaviPaneState extends State<NaviPane>
    with SingleTickerProviderStateMixin {
  bool _canPop = true;

  late int _currentPage = widget.initialPage;

  int get currentPage => _currentPage;

  set currentPage(int value) {
    if (value == _currentPage) return;
    _currentPage = value;
    widget.onPageChanged?.call(value);
  }

  void Function()? mainViewUpdateHandler;

  late AnimationController controller;

  final _naviItemTapListeners = <NaviItemTapListener>[];

  void addNaviItemTapListener(NaviItemTapListener listener) {
    _naviItemTapListeners.add(listener);
  }

  void removeNaviItemTapListener(NaviItemTapListener listener) {
    _naviItemTapListeners.remove(listener);
  }

  static const _kBottomBarHeight = 80.0;

  static const _kFoldedSideBarWidth = 72.0;

  static const _kSideBarWidth = 224.0;

  static const _kTopBarHeight = 48.0;

  double get bottomBarHeight => _floatingBottomBar
      ? prism.NavigationDock.insetOf(context)
      : _kBottomBarHeight + MediaQuery.paddingOf(context).bottom;

  bool get _floatingBottomBar =>
      appdata.settings['bottomNavigationStyle'] == 'floating';

  void onNavigatorStateChange() {
    onRebuild(context);
  }

  void updatePage(int index) {
    for (var listener in _naviItemTapListeners) {
      listener(index);
    }
    if (widget.observer.routes.length > 1) {
      widget.navigatorKey.currentState!.popUntil((route) => route.isFirst);
    }
    if (currentPage == index) {
      return;
    }
    setState(() {
      currentPage = index;
    });
    mainViewUpdateHandler?.call();
  }

  @override
  void initState() {
    controller = AnimationController(
      duration: const Duration(milliseconds: 250),
      lowerBound: 0,
      upperBound: 3,
      vsync: this,
    );
    widget.observer.addListener(onNavigatorStateChange);
    super.initState();
  }

  @override
  void dispose() {
    controller.dispose();
    widget.observer.removeListener(onNavigatorStateChange);
    super.dispose();
  }

  double targetFormContext(BuildContext context) {
    var width = MediaQuery.of(context).size.width;
    double target = 0;
    if (width > changePoint) {
      target = 2;
    }
    if (width > changePoint2) {
      target = 3;
    }
    return target;
  }

  double? animationTarget;

  void onRebuild(BuildContext context) {
    double target = targetFormContext(context);
    if (controller.value != target || animationTarget != target) {
      if (controller.isAnimating) {
        if (animationTarget == target) {
          return;
        } else {
          controller.stop();
        }
      }
      controller.animateTo(target);
      animationTarget = target;
    }
  }

  @override
  Widget build(BuildContext context) {
    onRebuild(context);
    final mq = MediaQuery.of(context);
    final sideInsets = (App.isMobile && mq.orientation == Orientation.landscape)
        ? EdgeInsets.only(
            left: math.max(mq.viewPadding.left, mq.systemGestureInsets.left),
            right: math.max(mq.viewPadding.right, mq.systemGestureInsets.right),
          )
        : EdgeInsets.zero;
    return _NaviPopScope(
      action: () {
        if (App.mainNavigatorKey!.currentState!.canPop()) {
          App.mainNavigatorKey!.currentState!.maybePop();
        } else {
          SystemNavigator.pop();
        }
      },
      popGesture: App.isIOS && context.width >= changePoint,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, child) {
          final value = controller.value;
          Widget content = Stack(
            children: [
              Positioned(
                left: _kFoldedSideBarWidth * ((value - 2.0).clamp(-1.0, 0.0)),
                top: 0,
                bottom: 0,
                child: buildLeft(),
              ),
              Positioned.fill(
                left:
                    _kFoldedSideBarWidth * ((value - 1).clamp(0, 1)) +
                    (_kSideBarWidth - _kFoldedSideBarWidth) *
                        ((value - 2).clamp(0, 1)),
                child: buildMainView(),
              ),
            ],
          );
          if (sideInsets != EdgeInsets.zero) {
            content = Padding(padding: sideInsets, child: content);
          }
          return content;
        },
      ),
    );
  }

  Widget buildMainView() {
    return HeroControllerScope(
      controller: MaterialApp.createMaterialHeroController(),
      child: PopScope(
        canPop: _canPop,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) {
            return;
          }
          widget.navigatorKey.currentState?.maybePop(result);
        },
        child: NotificationListener<NavigationNotification>(
          onNotification: (NavigationNotification notification) {
            final bool nextCanPop = !notification.canHandlePop;
            if (nextCanPop != _canPop) {
              setState(() {
                _canPop = nextCanPop;
              });
            }
            return false;
          },
          child: Navigator(
            observers: [widget.observer],
            key: widget.navigatorKey,
            onGenerateRoute: (settings) => AppPageRoute(
              preventRebuild: false,
              builder: (context) {
                return _NaviMainView(state: this);
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget buildMainViewContent() {
    return widget.pageBuilder(currentPage);
  }

  Widget buildTop() {
    return Material(
      child: Container(
        padding: const EdgeInsets.only(left: 16, right: 16),
        height: _kTopBarHeight,
        width: double.infinity,
        child: Row(
          children: [
            Text(
              widget.paneItems[currentPage].label,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const Spacer(),
            for (var action in widget.paneActions)
              Tooltip(
                message: action.label,
                child: IconButton(
                  icon: Icon(action.icon),
                  onPressed: action.onTap,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget buildBottom() {
    return prism.NavigationBar(
      selectedIndex: currentPage,
      onDestinationSelected: updatePage,
      destinations: [
        for (final (index, entry) in widget.paneItems.indexed)
          prism.NavigationDestination(
            icon: prism.AnimatedGlyph(
              glyph: entry.glyph,
              filled: index == currentPage,
            ),
            label: entry.label,
          ),
      ],
    );
  }

  Widget _buildFloatingBottom() {
    final selected = currentPage;
    return GestureDetector(
      excludeFromSemantics: true,
      // The dock commits a changed destination on pointer-up. Forward a tap
      // on the current destination as well, e.g. to scroll Explore to the top.
      onTap: () {
        if (selected == currentPage) updatePage(selected);
      },
      child: prism.NavigationDock(
        selectedIndex: selected,
        destinations: [
          for (final item in widget.paneItems)
            prism.NavigationDockDestination(
              glyph: item.glyph,
              label: item.label,
            ),
        ],
        onSelected: updatePage,
      ),
    );
  }

  Widget buildLeft() {
    final value = controller.value;
    const paddingHorizontal = 12.0;
    return Material(
      color: prism.ChromeSurfaceExt(prism.Theme.of(context).colorScheme).chromeSurface,
      child: Container(
        width:
            _kFoldedSideBarWidth +
            (_kSideBarWidth - _kFoldedSideBarWidth) * ((value - 2).clamp(0, 1)),
        height: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: paddingHorizontal),
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
              width: 1.0,
            ),
          ),
        ),
        child: Column(
          children: [
            const SizedBox(height: 16),
            SizedBox(height: MediaQuery.of(context).padding.top),
            Stack(
              children: [
                Column(
                  children: [
                    for (
                      var index = 0;
                      index < widget.paneItems.length;
                      index++
                    )
                      _SideNaviWidget(
                        key: ValueKey(index),
                        enabled: currentPage == index,
                        entry: widget.paneItems[index],
                        showTitle: value == 3,
                        onTap: () => updatePage(index),
                      ),
                  ],
                ),
                AnimatedPositionedDirectional(
                  duration: const Duration(milliseconds: 320),
                  curve: prism.Easing.standard,
                  start: 0,
                  top: currentPage * 44.0 + 14,
                  child: IgnorePointer(
                    child: Container(
                      width: 3,
                      height: 16,
                      decoration: BoxDecoration(
                        color: context.colorScheme.primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const Spacer(),
            ...List<Widget>.generate(
              widget.paneActions.length,
              (index) => _PaneActionWidget(
                entry: widget.paneActions[index],
                showTitle: value == 3,
                key: ValueKey(index + widget.paneItems.length),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _SideNaviWidget extends StatelessWidget {
  const _SideNaviWidget({
    required this.enabled,
    required this.entry,
    required this.onTap,
    required this.showTitle,
    super.key,
  });

  final bool enabled;

  final PaneItemEntry entry;

  final VoidCallback onTap;

  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final icon = IconTheme.merge(
      data: IconThemeData(
        color: enabled ? colorScheme.primary : colorScheme.onSurfaceVariant,
      ),
      child: prism.AnimatedGlyph(glyph: entry.glyph, filled: enabled),
    );
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        height: 40,
        decoration: BoxDecoration(
          color: enabled ? colorScheme.onSurface.withValues(alpha: 0.08) : null,
          borderRadius: BorderRadius.circular(10),
        ),
        child: showTitle
            ? Row(
                children: [
                  icon,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      entry.label,
                      style: Theme.of(context).textTheme.labelLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              )
            : Align(alignment: Alignment.centerLeft, child: icon),
      ),
    ).paddingVertical(2);
  }
}

class _PaneActionWidget extends StatelessWidget {
  const _PaneActionWidget({
    required this.entry,
    required this.showTitle,
    super.key,
  });

  final PaneActionEntry entry;

  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(entry.icon);
    return InkWell(
      onTap: entry.onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        height: 40,
        child: showTitle
            ? Row(
                children: [
                  icon,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      entry.label,
                      style: Theme.of(context).textTheme.labelLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              )
            : Align(alignment: Alignment.centerLeft, child: icon),
      ),
    ).paddingVertical(2);
  }
}

class NaviObserver extends NavigatorObserver implements Listenable {
  var routes = Queue<Route>();

  int get pageCount {
    int count = 0;
    for (var route in routes) {
      if (route is AppPageRoute) {
        count++;
      }
    }
    return count;
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    routes.removeLast();
    notifyListeners();
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    routes.addLast(route);
    notifyListeners();
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    routes.remove(route);
    notifyListeners();
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    routes.remove(oldRoute);
    if (newRoute != null) {
      routes.add(newRoute);
    }
    notifyListeners();
  }

  List<VoidCallback> listeners = [];

  @override
  void addListener(VoidCallback listener) {
    listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners.remove(listener);
  }

  void notifyListeners() {
    for (var listener in listeners) {
      listener();
    }
  }
}

class _NaviPopScope extends StatelessWidget {
  const _NaviPopScope({
    required this.child,
    this.popGesture = false,
    required this.action,
  });

  final Widget child;
  final bool popGesture;
  final VoidCallback action;

  static bool panStartAtEdge = false;

  @override
  Widget build(BuildContext context) {
    Widget res = child;
    if (popGesture) {
      res = GestureDetector(
        onPanStart: (details) {
          if (details.globalPosition.dx < 64) {
            panStartAtEdge = true;
          }
        },
        onPanEnd: (details) {
          if (details.velocity.pixelsPerSecond.dx < 0 ||
              details.velocity.pixelsPerSecond.dx > 0) {
            if (panStartAtEdge) {
              action();
            }
          }
          panStartAtEdge = false;
        },
        child: res,
      );
    }
    return res;
  }
}

class _NaviMainView extends StatefulWidget {
  const _NaviMainView({required this.state});

  final NaviPaneState state;

  @override
  State<_NaviMainView> createState() => _NaviMainViewState();
}

class _NaviMainViewState extends State<_NaviMainView> {
  NaviPaneState get state => widget.state;

  @override
  void initState() {
    state.mainViewUpdateHandler = () {
      setState(() {});
    };
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([state.controller, appdata.settings]),
      child: state.buildMainViewContent(),
      builder: (context, page) {
        final showBottomBar = state.controller.value < 2;
        final floating = showBottomBar && state._floatingBottomBar;
        final pageMedia = media.removePadding(removeTop: showBottomBar);
        return Column(
          children: [
            if (showBottomBar) state.buildTop().paddingTop(media.padding.top),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: showBottomBar && !floating
                          ? state.bottomBarHeight
                          : 0,
                    ),
                    child: MediaQuery(
                      data: floating
                          ? pageMedia.copyWith(
                              padding: pageMedia.padding.copyWith(
                                bottom: state.bottomBarHeight,
                              ),
                            )
                          : pageMedia,
                      child: AnimatedSwitcher(
                        duration: floating
                            ? prism.fadeTabDuration
                            : _fastAnimationDuration,
                        switchInCurve: floating
                            ? prism.fadeTabCurve
                            : Curves.linear,
                        switchOutCurve: floating
                            ? prism.fadeTabCurve
                            : Curves.linear,
                        child: page,
                      ),
                    ),
                  ),
                  if (showBottomBar && !floating)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: MediaQuery.removePadding(
                        context: context,
                        removeTop: true,
                        child: state.buildBottom(),
                      ),
                    ),
                  Positioned(
                    key: const ValueKey('floatingNavigationDock'),
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: prism.AnimatedVisibility.bottomNavigation(
                      visible: floating,
                      child: state._buildFloatingBottom(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
