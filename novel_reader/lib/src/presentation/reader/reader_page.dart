import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'package:novel_reader/src/data/db/app_database.dart';
import 'package:novel_reader/src/data/parsers/txt_chapters.dart';
import 'package:novel_reader/src/domain/book.dart';
import 'package:novel_reader/src/domain/bookmark.dart';
import 'package:novel_reader/src/domain/reader_settings.dart';
import 'package:novel_reader/src/domain/reading_progress.dart';
import 'package:novel_reader/src/presentation/bookmarks/bookmark_sheet.dart';
import 'package:novel_reader/src/utils/text_decoding.dart';

class ReaderRoute {
  static const name = '/reader';
}

class ReaderRouteArgs {
  const ReaderRouteArgs({
    required this.bookId,
    required this.filePath,
    required this.format,
    this.initialOffset,
    this.initialPdfPage,
  });

  final String bookId;
  final String filePath;
  final BookFormat format;

  /// 打开时直接跳到的字符偏移（如从搜索结果进入）。
  final int? initialOffset;

  /// 打开时直接跳到的 PDF 页码（如从书签进入）。
  final int? initialPdfPage;
}

class ReaderPage extends StatelessWidget {
  const ReaderPage({super.key, required this.db, required this.args});

  final AppDatabase db;
  final ReaderRouteArgs args;

  @override
  Widget build(BuildContext context) {
    return switch (args.format) {
      BookFormat.txt => _TxtReaderPage(db: db, args: args),
      BookFormat.pdf => _PdfReaderPage(db: db, args: args),
      BookFormat.unknown => _UnknownReaderPage(args: args),
    };
  }
}

class _TxtReaderPage extends StatefulWidget {
  const _TxtReaderPage({required this.db, required this.args});

  final AppDatabase db;
  final ReaderRouteArgs args;

  @override
  State<_TxtReaderPage> createState() => _TxtReaderPageState();
}

class _TxtReaderPageState extends State<_TxtReaderPage> {
  final List<_PageRange> _ranges = [];
  int? _pageCount;
  int _currentPage = 0;

  PageController? _pageController;
  String? _layoutKey;

  late final Future<({String text, List<TxtChapter> chapters})> _textFuture;
  String? _text;
  int? _pendingOffset;
  List<TxtChapter> _chapters = const [];

  // 分页基准偏移：当前 _ranges[0] 的起始位置。
  // 大书续读/章节跳转时直接以目标位置为基准重建分页，避免从第 0 页逐页补算。
  int _baseOffset = 0;

  // 最近一次布局参数，供目录跳转复用
  double? _lastMaxWidth;
  double? _lastMaxHeight;
  TextStyle? _lastStyle;

  ReaderSettings _settings = const ReaderSettings();

  // 进度条拖拽中的临时值（null 表示未在拖拽）
  double? _dragValue;

  @override
  void initState() {
    super.initState();
    _settings = widget.db.getReaderSettings();
    // 更新最近打开时间：书架按此字段排序，最近读过的排最前。
    widget.db.touchBookLastOpened(widget.args.bookId);
    // 读取与章节识别都放到后台 isolate，避免大文件卡死 UI。
    // 注意：闭包只能捕获简单值（如路径字符串），
    // 否则会连带捕获 State/Widget 对象导致 isolate 消息非法。
    final filePath = widget.args.filePath;
    _textFuture = Isolate.run(() {
      final text = readTextFileSync(filePath);
      return (text: text, chapters: detectTxtChapters(text));
    });
    _pendingOffset =
        widget.args.initialOffset ??
        widget.db.getProgress(widget.args.bookId)?.charOffset ??
        0;
  }

  @override
  void dispose() {
    _pageController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = _settings.theme;
    return Scaffold(
      backgroundColor: theme.background,
      appBar: AppBar(
        title: Text(_titleText()),
        backgroundColor: theme.background,
        foregroundColor: theme.foreground,
        actions: [
          IconButton(
            onPressed: _addBookmark,
            icon: const Icon(Icons.bookmark_add),
            tooltip: '添加书签',
          ),
          IconButton(
            onPressed: _showBookmarkPanel,
            icon: const Icon(Icons.bookmarks),
            tooltip: '书签列表',
          ),
          IconButton(
            onPressed: _showSearchPanel,
            icon: const Icon(Icons.search),
            tooltip: '搜索本书',
          ),
          IconButton(
            onPressed: _showSettingsPanel,
            icon: const Icon(Icons.text_fields),
            tooltip: '阅读设置',
          ),
          if (_chapters.isNotEmpty)
            IconButton(
              onPressed: _showToc,
              icon: const Icon(Icons.list),
              tooltip: '目录',
            ),
        ],
      ),
      body: FutureBuilder<({String text, List<TxtChapter> chapters})>(
        future: _textFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('读取失败：${snapshot.error}'));
          }
          _text = snapshot.data?.text ?? '';
          _chapters = snapshot.data?.chapters ?? const [];
          // 后台建全书架搜索索引（首次打开该书时；已建则内部直接跳过）
          final loadedText = snapshot.data?.text;
          if (loadedText != null && loadedText.isNotEmpty) {
            final bookId = widget.args.bookId;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              if (!widget.db.hasSearchSegments(bookId)) {
                Future(() => widget.db.buildSearchSegments(bookId, loadedText));
              }
            });
          }
          return LayoutBuilder(
            builder: (context, constraints) {
              return _buildWithLayout(constraints);
            },
          );
        },
      ),
    );
  }

  String _titleText() {
    final chapter = _currentChapter();
    if (chapter != null) {
      return chapter.title;
    }
    if (_pageCount != null) {
      return 'TXT 阅读 ${_currentPage + 1}/${_pageCount!}';
    }
    return 'TXT 阅读 ${_currentPage + 1}';
  }

  /// 当前页所属章节（按当前页起始字符偏移判断）。
  TxtChapter? _currentChapter() {
    if (_chapters.isEmpty) return null;
    if (_ranges.length <= _currentPage) return null;
    final offset = _ranges[_currentPage].start;
    for (final c in _chapters) {
      if (c.contains(offset)) return c;
    }
    return _chapters.last;
  }

  Widget _buildWithLayout(BoxConstraints constraints) {
    final text = _text ?? '';
    final s = _settings;
    final padding = EdgeInsets.fromLTRB(
      s.margin,
      s.margin * 0.8,
      s.margin,
      s.margin * 0.8,
    );
    final maxWidth = (constraints.maxWidth - padding.horizontal).clamp(
      1.0,
      double.infinity,
    );
    // 分页高度需扣除底部进度条区域（间距 8 + 控件行 48），
    // 否则每页最后一行文字会被进度条遮挡/裁切。
    const progressBarAreaHeight = 56.0;
    final maxHeight =
        (constraints.maxHeight - padding.vertical - progressBarAreaHeight)
            .clamp(1.0, double.infinity);

    final style = TextStyle(
      fontSize: s.fontSize,
      height: s.lineHeight,
      color: s.theme.foreground,
    );

    _lastMaxWidth = maxWidth;
    _lastMaxHeight = maxHeight;
    _lastStyle = style;

    final nextLayoutKey =
        '${text.hashCode}|${maxWidth.toStringAsFixed(1)}|${maxHeight.toStringAsFixed(1)}|${style.fontSize}|${style.height}';
    if (_layoutKey != nextLayoutKey) {
      _layoutKey = nextLayoutKey;
      // 以“续读位置或当前位置”为新基准直接重建分页，
      // 大书无需从第 0 页逐页补算到目标位置。
      final offset = _pendingOffset ?? _currentCharOffset();
      _pendingOffset = null;
      _resetPaginationAt(offset);
      _ensureRange(0, maxWidth, maxHeight, style);
    }

    _pageController ??= PageController(initialPage: _currentPage);

    return Padding(
      padding: padding,
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                PageView.builder(
                  controller: _pageController,
                  itemCount: _pageCount,
                  onPageChanged: (index) {
                    setState(() {
                      _currentPage = index;
                    });
                    _persistProgress(index);
                    _ensureRange(index + 1, maxWidth, maxHeight, style);
                  },
                  itemBuilder: (context, index) {
                    _ensureRange(index, maxWidth, maxHeight, style);
                    final range = _ranges[index];
                    final pageText = text.substring(range.start, range.end);
                    return Text(pageText, style: style);
                  },
                ),
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTapUp: (details) {
                      final box = context.findRenderObject();
                      if (box is! RenderBox) return;
                      final local = box.globalToLocal(details.globalPosition);
                      final width = box.size.width;
                      if (local.dx < width / 3) {
                        _goPrev();
                        return;
                      }
                      if (local.dx > width * 2 / 3) {
                        _goNext(maxWidth, maxHeight, style);
                        return;
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
          _buildProgressBar(maxWidth, maxHeight, style),
        ],
      ),
    );
  }

  /// 底部进度条：按固定字数切片（默认 500，可配），支持拖拽跳转与两端切片按钮。
  Widget _buildProgressBar(double maxWidth, double maxHeight, TextStyle style) {
    final text = _text ?? '';
    if (text.isEmpty) return const SizedBox.shrink();

    final segmentChars = _settings.segmentChars;
    final totalSegments = (text.length / segmentChars).ceil();
    if (totalSegments <= 0) return const SizedBox.shrink();

    final currentOffset = _currentCharOffset();
    final currentSegment = (currentOffset / segmentChars).floor() + 1;
    // 滑块值 = 全书进度比例（0~1），而非“当前偏移/切片字数”。
    final progressValue = (currentOffset / text.length).clamp(0.0, 1.0);
    // 拖拽期间显示手指位置，松手才真正跳页。
    final sliderValue = _dragValue ?? progressValue;

    void jumpToSegment(int segmentIndex) {
      final target = (segmentIndex * segmentChars).clamp(0, text.length);
      _jumpToOffset(target, maxWidth, maxHeight, style);
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      // 固定控件行高度，与分页时扣除的 48px 保持一致
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: currentSegment > 1
                  ? () => jumpToSegment(currentSegment - 2)
                  : null,
              icon: const Icon(Icons.chevron_left),
              tooltip: '上一切片',
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 12,
                  ),
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                ),
                child: Slider(
                  value: sliderValue,
                  // 拖拽中只更新滑块视觉位置，不跳页
                  onChanged: (v) => setState(() => _dragValue = v),
                  onChangeEnd: (v) {
                    setState(() => _dragValue = null);
                    // 按精确字符位置跳转（比例 × 全书长度）
                    final target = (v * text.length).round().clamp(
                      0,
                      text.length,
                    );
                    _jumpToOffset(target, maxWidth, maxHeight, style);
                  },
                ),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: currentSegment < totalSegments
                  ? () => jumpToSegment(currentSegment)
                  : null,
              icon: const Icon(Icons.chevron_right),
              tooltip: '下一切片',
            ),
            SizedBox(
              width: 72,
              child: Text(
                '$currentSegment/$totalSegments',
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontSize: 12,
                  color: _settings.theme.foreground.withValues(alpha: 0.6),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _resetPaginationAt(int base) {
    _ranges.clear();
    _pageCount = null;
    _currentPage = 0;
    _pageController?.dispose();
    _pageController = null;
    _baseOffset = base;
  }

  /// 当前页起始字符偏移。
  int _currentCharOffset() {
    if (_ranges.isEmpty) return _baseOffset;
    final i = _currentPage.clamp(0, _ranges.length - 1);
    return _ranges[i].start;
  }

  /// 估算平均每页字符数（用于向前回退时估算跳转距离）。
  int _estimatePageChars() {
    if (_ranges.isEmpty) return 600;
    final span = _ranges.last.end - _ranges.first.start;
    if (span <= 0) return 600;
    return (span ~/ _ranges.length).clamp(1, 1 << 20);
  }

  void _goPrev() {
    final controller = _pageController;
    if (controller == null) return;
    if (_currentPage <= 0) {
      // 已到当前分页基准的首页：向前回退约两页的量再重建分页
      final firstStart = _ranges.isNotEmpty ? _ranges.first.start : _baseOffset;
      if (firstStart <= 0) return;
      final w = _lastMaxWidth;
      final h = _lastMaxHeight;
      final s = _lastStyle;
      if (w == null || h == null || s == null) return;
      final target = (firstStart - _estimatePageChars() * 2).clamp(
        0,
        firstStart,
      );
      _jumpToOffset(target, w, h, s);
      return;
    }
    controller.previousPage(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
    );
  }

  void _goNext(double maxWidth, double maxHeight, TextStyle style) {
    final controller = _pageController;
    if (controller == null) return;
    if (_pageCount != null && _currentPage >= _pageCount! - 1) return;
    _ensureRange(_currentPage + 1, maxWidth, maxHeight, style);
    controller.nextPage(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
    );
  }

  /// 当前书搜索：返回所有命中（偏移 + 前后摘录），上限 500 条。
  List<_SearchHit> _searchInBook(String query) {
    final text = _text ?? '';
    if (query.isEmpty || text.isEmpty) return const [];
    final hits = <_SearchHit>[];
    var i = text.indexOf(query);
    while (i >= 0 && hits.length < 500) {
      final from = (i - 20).clamp(0, text.length);
      final to = (i + query.length + 20).clamp(0, text.length);
      hits.add(
        _SearchHit(
          offset: i,
          excerpt:
              (from > 0 ? '…' : '') +
              text.substring(from, to) +
              (to < text.length ? '…' : ''),
        ),
      );
      i = text.indexOf(query, i + query.length);
    }
    return hits;
  }

  void _showSearchPanel() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return _InBookSearchSheet(
          onSearch: _searchInBook,
          onJump: (offset) {
            final w = _lastMaxWidth;
            final h = _lastMaxHeight;
            final s = _lastStyle;
            if (w == null || h == null || s == null) return;
            _jumpToOffset(offset, w, h, s);
          },
          currentOffset: _currentCharOffset(),
        );
      },
    );
  }

  void _showSettingsPanel() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            // 同时刷新阅读页（重新分页/换色）与面板自身，并落库。
            void apply(ReaderSettings next) {
              setSheetState(() {});
              setState(() => _settings = next);
              widget.db.saveReaderSettings(next);
            }

            final s = _settings;
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '主题',
                    style: Theme.of(sheetContext).textTheme.titleSmall,
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final mode in ReaderThemeMode.values)
                        ChoiceChip(
                          label: Text(mode.label),
                          selected: s.theme == mode,
                          onSelected: (_) => apply(s.copyWith(theme: mode)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _SettingsSlider(
                    label: '字号',
                    valueLabel: s.fontSize.toStringAsFixed(0),
                    value: s.fontSize,
                    min: 12,
                    max: 32,
                    divisions: 20,
                    onChanged: (v) => apply(s.copyWith(fontSize: v)),
                  ),
                  _SettingsSlider(
                    label: '行距',
                    valueLabel: s.lineHeight.toStringAsFixed(1),
                    value: s.lineHeight,
                    min: 1.2,
                    max: 2.4,
                    divisions: 12,
                    onChanged: (v) => apply(s.copyWith(lineHeight: v)),
                  ),
                  _SettingsSlider(
                    label: '页边距',
                    valueLabel: s.margin.toStringAsFixed(0),
                    value: s.margin,
                    min: 8,
                    max: 40,
                    divisions: 16,
                    onChanged: (v) => apply(s.copyWith(margin: v)),
                  ),
                  _SegmentCharsSetting(
                    value: s.segmentChars,
                    onChanged: (v) => apply(s.copyWith(segmentChars: v)),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// 在当前位置添加书签（记录页起始偏移、章节与页首摘录）。
  void _addBookmark() {
    final text = _text ?? '';
    if (text.isEmpty) return;
    final range = _ranges.length > _currentPage ? _ranges[_currentPage] : null;
    final offset = range?.start ?? _currentCharOffset();
    var end = offset + 60;
    if (range != null && range.end < end) end = range.end;
    final excerpt = text.substring(offset, end.clamp(0, text.length));
    widget.db.insertBookmark(
      Bookmark(
        id: newBookmarkId(),
        bookId: widget.args.bookId,
        format: BookFormat.txt,
        createdAt: DateTime.now(),
        chapterId: _currentChapter()?.index,
        charOffset: offset,
        excerpt: excerpt,
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已添加书签'),
        duration: Duration(milliseconds: 800),
      ),
    );
  }

  void _showBookmarkPanel() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return BookmarkSheet(
          db: widget.db,
          bookId: widget.args.bookId,
          onJump: (bookmark) {
            final offset = bookmark.charOffset;
            if (offset == null) return;
            final w = _lastMaxWidth;
            final h = _lastMaxHeight;
            final s = _lastStyle;
            if (w == null || h == null || s == null) return;
            _jumpToOffset(offset, w, h, s);
          },
        );
      },
    );
  }

  void _showToc() {
    final current = _currentChapter();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (context, scrollController) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '目录',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      Text(
                        '${_chapters.length} 章',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: _chapters.length,
                    itemBuilder: (context, index) {
                      final chapter = _chapters[index];
                      final isCurrent =
                          current != null && chapter.index == current.index;
                      return ListTile(
                        dense: true,
                        selected: isCurrent,
                        title: Text(
                          chapter.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: isCurrent
                            ? const Icon(Icons.check, size: 18)
                            : null,
                        onTap: () {
                          Navigator.of(context).pop();
                          _jumpToChapter(chapter);
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _jumpToChapter(TxtChapter chapter) {
    final maxWidth = _lastMaxWidth;
    final maxHeight = _lastMaxHeight;
    final style = _lastStyle;
    if (maxWidth == null || maxHeight == null || style == null) return;
    _jumpToOffset(chapter.start, maxWidth, maxHeight, style);
  }

  void _persistProgress(int pageIndex) {
    if (_ranges.length <= pageIndex) return;
    final range = _ranges[pageIndex];
    int? chapterId;
    for (final c in _chapters) {
      if (c.contains(range.start)) {
        chapterId = c.index;
        break;
      }
    }
    widget.db.upsertProgress(
      ReadingProgress(
        bookId: widget.args.bookId,
        updatedAt: DateTime.now(),
        charOffset: range.start,
        segmentIndex: pageIndex,
        chapterId: chapterId,
      ),
    );
  }

  void _jumpToOffset(
    int offset,
    double maxWidth,
    double maxHeight,
    TextStyle style,
  ) {
    final text = _text ?? '';
    if (text.isEmpty) return;
    final clamped = offset.clamp(0, text.length);
    if (clamped == _baseOffset && _ranges.isNotEmpty) return;

    // 直接以目标位置为新基准重建分页：O(1) 跳转，
    // 不再从第 0 页逐页补算（大书会卡死）。
    setState(() {
      _resetPaginationAt(clamped);
      _ensureRange(0, maxWidth, maxHeight, style);
    });
  }

  void _ensureRange(
    int index,
    double maxWidth,
    double maxHeight,
    TextStyle style,
  ) {
    final text = _text ?? '';
    if (_pageCount != null) return;
    if (index < _ranges.length) return;

    while (_ranges.length <= index) {
      final start = _ranges.isEmpty ? _baseOffset : _ranges.last.end;
      if (start >= text.length) {
        _pageCount = _ranges.length;
        break;
      }
      final end = _measureEnd(text, start, maxWidth, maxHeight, style);
      _ranges.add(_PageRange(start: start, end: end));
      if (end >= text.length) {
        _pageCount = _ranges.length;
        break;
      }
    }

    // 注意：本方法可能在 build 阶段调用，不能在这里 setState。
    // 分页结果（_ranges/_pageCount）会在下一次 build 时自然生效。
  }

  int _measureEnd(
    String text,
    int start,
    double maxWidth,
    double maxHeight,
    TextStyle style,
  ) {
    final maxEnd = text.length;
    if (start + 1 >= maxEnd) return maxEnd;

    // 先用按 4 倍递增的窗口找到一个“装不下”的上界，再在窗口内二分。
    // 避免对超大文本整段测量（那是大书卡死的根源）。
    var probe = start + 512;
    while (probe < maxEnd &&
        _fits(text.substring(start, probe), maxWidth, maxHeight, style)) {
      probe = start + (probe - start) * 4;
    }
    if (probe >= maxEnd) {
      // 窗口越界：若剩余全文能整页放下则直接到书末
      if (_fits(text.substring(start, maxEnd), maxWidth, maxHeight, style)) {
        return _adjustEnd(text, start, maxEnd);
      }
      probe = maxEnd;
    }

    var low = start + 1; // 可行下界（单字符必然放得下）
    var high = probe; // 不可行上界（不含）
    while (low < high) {
      final mid = ((low + high + 1) / 2).floor();
      if (_fits(text.substring(start, mid), maxWidth, maxHeight, style)) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return _adjustEnd(text, start, low);
  }

  bool _fits(
    String candidate,
    double maxWidth,
    double maxHeight,
    TextStyle style,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: candidate, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    return painter.height <= maxHeight;
  }

  int _adjustEnd(String text, int start, int end) {
    if (end <= start + 1) return end;
    final window = 80;
    final from = (end - window).clamp(start, end);
    final slice = text.substring(from, end);
    final idx = slice.lastIndexOf('\n');
    if (idx >= 0 && idx + from > start) {
      return from + idx + 1;
    }
    final ws = RegExp(r'\s');
    for (var i = slice.length - 1; i >= 0; i -= 1) {
      if (ws.hasMatch(slice[i])) {
        final adjusted = from + i + 1;
        if (adjusted > start) return adjusted;
        break;
      }
    }
    return end;
  }
}

class _PageRange {
  const _PageRange({required this.start, required this.end});

  final int start;
  final int end;
}

class _SearchHit {
  const _SearchHit({required this.offset, required this.excerpt});

  final int offset;
  final String excerpt;
}

/// 当前书搜索面板：输入关键词 → 命中列表（就近排序）→ 点击/上下按钮跳转。
class _InBookSearchSheet extends StatefulWidget {
  const _InBookSearchSheet({
    required this.onSearch,
    required this.onJump,
    required this.currentOffset,
  });

  final List<_SearchHit> Function(String query) onSearch;
  final void Function(int offset) onJump;
  final int currentOffset;

  @override
  State<_InBookSearchSheet> createState() => _InBookSearchSheetState();
}

class _InBookSearchSheetState extends State<_InBookSearchSheet> {
  final _controller = TextEditingController();
  List<_SearchHit> _hits = const [];
  int _selected = 0;
  bool _searched = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _doSearch(String query) {
    setState(() {
      _hits = widget.onSearch(query);
      _searched = true;
      // 就近原则：从离当前位置最近的命中开始
      var best = 0;
      for (var i = 0; i < _hits.length; i++) {
        if (_hits[i].offset >= widget.currentOffset) {
          best = i;
          break;
        }
        best = i;
      }
      _selected = best;
    });
    if (_hits.isNotEmpty) {
      widget.onJump(_hits[_selected].offset);
    }
  }

  void _go(int delta) {
    if (_hits.isEmpty) return;
    setState(() {
      _selected = (_selected + delta) % _hits.length;
    });
    widget.onJump(_hits[_selected].offset);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: '搜索本书内容…',
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 20),
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: _doSearch,
                ),
              ),
              const SizedBox(width: 8),
              if (_searched)
                Text(
                  _hits.isEmpty ? '无结果' : '${_selected + 1}/${_hits.length} 处',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
          if (_hits.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: () => _go(-1),
                  icon: const Icon(Icons.keyboard_arrow_up),
                  tooltip: '上一处',
                ),
                Expanded(
                  child: Text(
                    _hits[_selected].excerpt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                IconButton(
                  onPressed: () => _go(1),
                  icon: const Icon(Icons.keyboard_arrow_down),
                  tooltip: '下一处',
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 切片字数设置：滑杆（粗调）+ 输入框（精确值，50–5000 任意数字）。
class _SegmentCharsSetting extends StatefulWidget {
  const _SegmentCharsSetting({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<_SegmentCharsSetting> createState() => _SegmentCharsSettingState();
}

class _SegmentCharsSettingState extends State<_SegmentCharsSetting> {
  late final TextEditingController _controller;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.toString());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit(String raw) {
    final parsed = int.tryParse(raw.trim());
    if (parsed == null) {
      _controller.text = widget.value.toString();
      return;
    }
    widget.onChanged(parsed.clamp(50, 5000));
  }

  @override
  Widget build(BuildContext context) {
    if (!_editing) {
      _controller.text = widget.value.toString();
    }
    return Row(
      children: [
        SizedBox(
          width: 56,
          child: Text('切片字数', style: Theme.of(context).textTheme.titleSmall),
        ),
        Expanded(
          child: Slider(
            value: widget.value.clamp(50, 5000).toDouble(),
            min: 50,
            max: 5000,
            label: widget.value.toString(),
            onChanged: (v) => widget.onChanged(v.round()),
          ),
        ),
        SizedBox(
          width: 64,
          child: TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.bodySmall,
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              border: OutlineInputBorder(),
            ),
            onTap: () => _editing = true,
            onEditingComplete: () {
              _submit(_controller.text);
              _editing = false;
              FocusScope.of(context).unfocus();
            },
            onSubmitted: (raw) {
              _submit(raw);
              _editing = false;
            },
          ),
        ),
      ],
    );
  }
}

class _SettingsSlider extends StatelessWidget {
  const _SettingsSlider({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 56,
          child: Text(label, style: Theme.of(context).textTheme.titleSmall),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            label: valueLabel,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            valueLabel,
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _PdfReaderPage extends StatefulWidget {
  const _PdfReaderPage({required this.db, required this.args});

  final AppDatabase db;
  final ReaderRouteArgs args;

  @override
  State<_PdfReaderPage> createState() => _PdfReaderPageState();
}

class _PdfReaderPageState extends State<_PdfReaderPage> {
  final _controller = PdfViewerController();
  int _page = 1;
  int _pageCount = 0;
  bool _docReady = false;
  double? _dragValue;

  @override
  void initState() {
    super.initState();
    // 书签进入时优先用书签页码，其次续读进度。
    _page =
        widget.args.initialPdfPage ??
        widget.db.getProgress(widget.args.bookId)?.pdfPage ??
        1;
  }

  void _persist(int page) {
    widget.db.upsertProgress(
      ReadingProgress(
        bookId: widget.args.bookId,
        updatedAt: DateTime.now(),
        pdfPage: page,
      ),
    );
  }

  void _goTo(int page) {
    if (!_docReady || page < 1 || (_pageCount > 0 && page > _pageCount)) return;
    _controller.goToPage(pageNumber: page);
  }

  void _addBookmark() {
    widget.db.insertBookmark(
      Bookmark(
        id: newBookmarkId(),
        bookId: widget.args.bookId,
        format: BookFormat.pdf,
        createdAt: DateTime.now(),
        pdfPage: _page,
        excerpt: '第 $_page 页',
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已添加书签'),
        duration: Duration(milliseconds: 800),
      ),
    );
  }

  void _showBookmarkPanel() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return BookmarkSheet(
          db: widget.db,
          bookId: widget.args.bookId,
          onJump: (bookmark) {
            final page = bookmark.pdfPage;
            if (page != null) _goTo(page);
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _docReady && _pageCount > 0
        ? '第 $_page/$_pageCount 页'
        : 'PDF 阅读';
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            onPressed: _addBookmark,
            icon: const Icon(Icons.bookmark_add),
            tooltip: '添加书签',
          ),
          IconButton(
            onPressed: _showBookmarkPanel,
            icon: const Icon(Icons.bookmarks),
            tooltip: '书签列表',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: PdfViewer.file(
              widget.args.filePath,
              controller: _controller,
              initialPageNumber: _page,
              params: PdfViewerParams(
                onViewerReady: (document, controller) {
                  setState(() {
                    _pageCount = document.pages.length;
                    _docReady = true;
                  });
                },
                onPageChanged: (pageNumber) {
                  if (pageNumber == null) return;
                  setState(() => _page = pageNumber);
                  _persist(pageNumber);
                },
              ),
            ),
          ),
          if (_docReady && _pageCount > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _page > 1 ? () => _goTo(_page - 1) : null,
                    icon: const Icon(Icons.chevron_left),
                    tooltip: '上一页',
                  ),
                  Expanded(
                    child: Slider(
                      value: (_dragValue ?? _page)
                          .clamp(1, _pageCount)
                          .toDouble(),
                      min: 1,
                      max: _pageCount.toDouble(),
                      onChanged: (v) => setState(() => _dragValue = v),
                      onChangeEnd: (v) {
                        _goTo(v.round());
                        setState(() => _dragValue = null);
                      },
                    ),
                  ),
                  Text('$_page/$_pageCount'),
                  IconButton(
                    onPressed: _page < _pageCount
                        ? () => _goTo(_page + 1)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                    tooltip: '下一页',
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _UnknownReaderPage extends StatelessWidget {
  const _UnknownReaderPage({required this.args});

  final ReaderRouteArgs args;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('无法打开')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Text('不支持的格式：${args.filePath}'),
      ),
    );
  }
}
