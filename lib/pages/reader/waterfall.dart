part of 'reader.dart';

class _WaterfallMode extends _ContinuousMode {
  const _WaterfallMode();

  @override
  State<_ContinuousMode> createState() => _WaterfallModeState();
}

class _WaterfallChapter {
  const _WaterfallChapter(this.number, this.images);

  final int number;
  final List<String> images;

  int get itemCount => images.length + 1;
}

class _WaterfallModeState extends _ContinuousModeState {
  final _chapters = <_WaterfallChapter>[];
  final _errors = <bool, String>{};
  bool _loadingChapter = false;
  bool _restoringAnchor = false;
  bool _positionScheduled = false;

  @override
  void initState() {
    super.initState();
    _chapters.add(_WaterfallChapter(reader.chapter, reader.images!));
  }

  // Each chapter has a divider followed by its images. The two outer rows load
  // more chapters, while ScrollablePositionedList builds only nearby widgets.
  @override
  int get itemCount => _chapters.fold(2, (count, c) => count + c.itemCount);

  (_WaterfallChapter, int)? _row(int index) {
    if (index < 1) return null;
    var offset = index - 1;
    for (final chapter in _chapters) {
      if (offset < chapter.itemCount) return (chapter, offset);
      offset -= chapter.itemCount;
    }
    return null;
  }

  @override
  int listIndex(int page) {
    var index = 1;
    for (final chapter in _chapters) {
      if (chapter.number == reader.chapter) return index + page;
      index += chapter.itemCount;
    }
    return 1;
  }

  int? _adjacentChapter(bool forward) => reader.adjacentChapterInGroup(
    (forward ? _chapters.last : _chapters.first).number,
    forward: forward,
  );

  List<ItemPosition> _visibleRows() =>
      itemPositionsListener.itemPositions.value
          .where(
            (item) => item.itemTrailingEdge > 0 && item.itemLeadingEdge < 1,
          )
          .toList()
        ..sort((a, b) => a.index.compareTo(b.index));

  Future<void> _loadAdjacent(bool forward) async {
    if (_loadingChapter || _restoringAnchor || _errors.containsKey(forward)) {
      return;
    }
    final number = _adjacentChapter(forward);
    if (number == null) return;

    _loadingChapter = true;
    final session = reader._chapterSession;
    try {
      final images = await _loadChapterImages(reader, number);
      if (!mounted || session != reader._chapterSession) return;
      if (images.isEmpty) throw StateError('No pages in this chapter'.tl);

      final chapter = _WaterfallChapter(number, images);
      final anchor = forward
          ? null
          : _visibleRows()
                .where((item) => _row(item.index) != null)
                .firstOrNull;
      setState(() {
        if (forward) {
          _chapters.add(chapter);
        } else {
          _chapters.insert(0, chapter);
          _restoringAnchor = anchor != null;
        }
      });
      if (anchor != null) _restoreAnchor(anchor, chapter.itemCount);
    } catch (error) {
      if (!mounted || session != reader._chapterSession) return;
      setState(() {
        _errors[forward] = error is StateError
            ? error.message.toString()
            : error.toString();
      });
    } finally {
      _loadingChapter = false;
    }
    onPositionChanged();
  }

  void _restoreAnchor(ItemPosition anchor, int addedRows) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final alignment = anchor.itemLeadingEdge;
      if (itemScrollController.isAttached) {
        itemScrollController.jumpTo(
          index: anchor.index + addedRows,
          alignment: math.max(0, alignment),
        );
        _futurePosition = null;
      }
      // The positioned list only accepts a non-negative alignment. Restore any
      // part of a tall image that was already above the viewport after layout.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (alignment < 0 && _scrollController?.hasClients == true) {
          final position = scrollController.position;
          final offset =
              position.pixels - alignment * position.viewportDimension;
          position.jumpTo(
            offset.clamp(position.minScrollExtent, position.maxScrollExtent),
          );
        }
        _restoringAnchor = false;
        onPositionChanged();
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    });
  }

  @override
  Widget? boundaryItem(int index) {
    final row = _row(index);
    if (row == null) {
      final forward = index != 0;
      if (_adjacentChapter(forward) == null) return const SizedBox(height: 16);
      final error = _errors[forward];
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: error == null
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(),
                )
              : TextButton(
                  onPressed: () {
                    setState(() => _errors.remove(forward));
                    _loadAdjacent(forward);
                  },
                  child: Text(
                    '$error\n${'Retry'.tl}',
                    textAlign: TextAlign.center,
                  ),
                ),
        ),
      );
    }

    final (chapter, page) = row;
    if (page != 0) return null;
    final title = reader.widget.chapters?.titles.elementAtOrNull(
      chapter.number - 1,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          const SizedBox(width: 12),
          Flexible(
            flex: 3,
            child: Text(
              title ?? 'Chapter @ep'.tlParams({'ep': chapter.number}),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }

  @override
  ImageProvider imageAt(int index) {
    final (chapter, page) = _row(index)!;
    return ReaderImageProvider(
      chapter.images[page - 1],
      reader.type.comicSource?.key,
      reader.cid,
      reader.widget.chapters?.ids.elementAtOrNull(chapter.number - 1) ?? '0',
      page,
      enableResize: true,
    );
  }

  @override
  void onPositionChanged() {
    if (!mounted || _restoringAnchor || _positionScheduled) return;
    _positionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _positionScheduled = false;
      if (!mounted || _restoringAnchor || reader.isPageAnimating) return;

      final visible = _visibleRows();
      if (visible.isEmpty) return;
      (_WaterfallChapter, int)? current;
      for (final item in visible) {
        final row = _row(item.index);
        if (row == null || row.$2 == 0) continue;
        current ??= row;
        // Ignore small tails above the next image when updating progress.
        if (item.itemTrailingEdge > 0.2) {
          current = row;
          break;
        }
      }

      if (current case (final chapter, final page)) {
        if (reader.chapter != chapter.number || reader.page != page) {
          reader.chapter = chapter.number;
          reader.images = chapter.images;
          reader.setPage(page);
          context.readerScaffold.update();
        }
      }

      if (visible.first.index <= 2) _loadAdjacent(false);
      if (visible.last.index >= itemCount - 3) _loadAdjacent(true);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool get isAtEnd =>
      _adjacentChapter(true) == null &&
      _scrollController?.hasClients == true &&
      scrollController.position.extentAfter <= 0.5;

  bool scrollByViewport({required bool forward}) {
    if (_restoringAnchor || _scrollController?.hasClients != true) return false;
    final position = scrollController.position;
    final delta = position.viewportDimension * 0.9 * (forward ? 1 : -1);
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() <= 0.5) return false;
    _futurePosition = null;
    if (reader.enablePageAnimation(reader.cid, reader.type)) {
      position.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
      );
    } else {
      position.jumpTo(target);
    }
    return true;
  }

  @override
  bool get swipeToChangeChapter => false;

  @override
  void cacheImages(int current) {}
}
