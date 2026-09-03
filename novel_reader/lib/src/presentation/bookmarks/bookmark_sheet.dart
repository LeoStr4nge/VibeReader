import 'package:flutter/material.dart';

import 'package:novel_reader/src/data/db/app_database.dart';
import 'package:novel_reader/src/domain/bookmark.dart';

/// 生成书签 id。
String newBookmarkId() {
  final now = DateTime.now();
  return 'bm-${now.millisecondsSinceEpoch}-${now.microsecondsSinceEpoch % 0xFFFF}';
}

String _formatDate(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// 当前书的书签面板：列表展示、点击跳转、删除、标签编辑。
class BookmarkSheet extends StatefulWidget {
  const BookmarkSheet({
    super.key,
    required this.db,
    required this.bookId,
    required this.onJump,
  });

  final AppDatabase db;
  final String bookId;

  /// 点击书签后的跳转回调（面板会先自行关闭再调用）。
  final void Function(Bookmark bookmark) onJump;

  @override
  State<BookmarkSheet> createState() => _BookmarkSheetState();
}

class _BookmarkSheetState extends State<BookmarkSheet> {
  List<Bookmark> _bookmarks = const [];
  final Map<String, List<String>> _tagMap = {};

  @override
  void initState() {
    super.initState();
    _bookmarks = widget.db.listBookmarks(widget.bookId);
    for (final b in _bookmarks) {
      _tagMap[b.id] = widget.db.listBookmarkTags(b.id);
    }
  }

  void _reload() {
    final bookmarks = widget.db.listBookmarks(widget.bookId);
    final tagMap = <String, List<String>>{};
    for (final b in bookmarks) {
      tagMap[b.id] = widget.db.listBookmarkTags(b.id);
    }
    setState(() {
      _bookmarks = bookmarks;
      _tagMap
        ..clear()
        ..addAll(tagMap);
    });
  }

  void _jump(Bookmark b) {
    Navigator.of(context).pop();
    widget.onJump(b);
  }

  void _delete(Bookmark b) {
    widget.db.deleteBookmark(b.id);
    _reload();
  }

  Future<void> _editTags(Bookmark b) async {
    await showBookmarkTagEditor(context, widget.db, b);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '书签',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  Text(
                    '${_bookmarks.length} 条',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _bookmarks.isEmpty
                  ? Center(
                      child: Text(
                        '暂无书签，点击顶部“添加书签”按钮收藏当前位置',
                        style: theme.textTheme.bodySmall,
                      ),
                    )
                  : ListView.builder(
                      controller: scrollController,
                      itemCount: _bookmarks.length,
                      itemBuilder: (context, index) {
                        final b = _bookmarks[index];
                        final tags = _tagMap[b.id] ?? const [];
                        return ListTile(
                          dense: true,
                          title: Text(
                            b.excerpt ??
                                (b.pdfPage != null
                                    ? '第 ${b.pdfPage} 页'
                                    : '无摘录'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (tags.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Wrap(
                                    spacing: 4,
                                    runSpacing: 2,
                                    children: [
                                      for (final t in tags)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 1,
                                          ),
                                          decoration: BoxDecoration(
                                            color: theme.colorScheme.primary
                                                .withValues(alpha: 0.12),
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                          ),
                                          child: Text(
                                            t,
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: theme.colorScheme.primary,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  _formatDate(b.createdAt),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.5),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                iconSize: 20,
                                onPressed: () => _editTags(b),
                                icon: const Icon(Icons.sell_outlined),
                                tooltip: '编辑标签',
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                iconSize: 20,
                                onPressed: () => _delete(b),
                                icon: const Icon(Icons.delete_outline),
                                tooltip: '删除书签',
                              ),
                            ],
                          ),
                          onTap: () => _jump(b),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// 书签标签编辑对话框：勾选/取消已有标签，输入新标签立即应用。
Future<void> showBookmarkTagEditor(
  BuildContext context,
  AppDatabase db,
  Bookmark bookmark,
) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => _TagEditorDialog(db: db, bookmark: bookmark),
  );
}

class _TagEditorDialog extends StatefulWidget {
  const _TagEditorDialog({required this.db, required this.bookmark});

  final AppDatabase db;
  final Bookmark bookmark;

  @override
  State<_TagEditorDialog> createState() => _TagEditorDialogState();
}

class _TagEditorDialogState extends State<_TagEditorDialog> {
  final _controller = TextEditingController();
  List<({String id, String name})> _all = const [];
  late final Set<String> _selectedIds;

  @override
  void initState() {
    super.initState();
    final bookmark = widget.bookmark;
    _all = widget.db.listTagEntries();
    final names = widget.db.listBookmarkTags(bookmark.id).toSet();
    _selectedIds = _all
        .where((t) => names.contains(t.name))
        .map((t) => t.id)
        .toSet();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggle(String tagId, bool selected) {
    if (selected) {
      widget.db.addTagToBookmark(widget.bookmark.id, tagId);
      _selectedIds.add(tagId);
    } else {
      widget.db.removeTagFromBookmark(widget.bookmark.id, tagId);
      _selectedIds.remove(tagId);
    }
    setState(() {});
  }

  void _add(String raw) {
    // 中文输入法可能仍处于组合（候选）状态，先收起键盘让文字落到输入框
    FocusScope.of(context).unfocus();
    final name = raw.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('标签名称为空'), duration: Duration(seconds: 1)),
      );
      return;
    }
    try {
      final id = widget.db.ensureTag(name);
      widget.db.addTagToBookmark(widget.bookmark.id, id);
      _controller.clear();
      setState(() {
        _all = widget.db.listTagEntries();
        _selectedIds.add(id);
      });
    } catch (e) {
      // 数据库异常时给出可见反馈，便于定位
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('添加标签失败：$e')));
    }
  }

  /// 删除标签（连带其与所有书签的关联），带确认。
  Future<void> _deleteTag(String tagId, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除标签'),
        content: Text('确定删除标签“$name”吗？标签与其所有书签的关联会一并移除，书签本身不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    widget.db.deleteTag(tagId);
    setState(() {
      _all = widget.db.listTagEntries();
      _selectedIds.remove(tagId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('编辑标签'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_all.isEmpty)
                Text(
                  '暂无标签，输入名称创建',
                  style: Theme.of(context).textTheme.bodySmall,
                )
              else ...[
                Text(
                  '点击标签选中/取消，点 × 删除标签',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final t in _all)
                      InputChip(
                        label: Text(t.name),
                        visualDensity: VisualDensity.compact,
                        selected: _selectedIds.contains(t.id),
                        onPressed: () =>
                            _toggle(t.id, !_selectedIds.contains(t.id)),
                        onDeleted: () => _deleteTag(t.id, t.name),
                        deleteIconColor: Theme.of(context).colorScheme.onSurface
                            .withValues(alpha: 0.45),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      autofocus: false,
                      textInputAction: TextInputAction.done,
                      decoration: const InputDecoration(
                        hintText: '新标签名称…',
                        isDense: true,
                      ),
                      onSubmitted: _add,
                    ),
                  ),
                  IconButton(
                    onPressed: () => _add(_controller.text),
                    icon: const Icon(Icons.add),
                    tooltip: '添加标签',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
      ],
    );
  }
}

/// 标签管理对话框：列出全部标签及书签使用数，支持删除（连带关联）。
Future<void> showTagManager(BuildContext context, AppDatabase db) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => _TagManagerDialog(db: db),
  );
}

class _TagManagerDialog extends StatefulWidget {
  const _TagManagerDialog({required this.db});

  final AppDatabase db;

  @override
  State<_TagManagerDialog> createState() => _TagManagerDialogState();
}

class _TagManagerDialogState extends State<_TagManagerDialog> {
  List<({String id, String name})> _tags = const [];
  Map<String, int> _usage = {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final tags = widget.db.listTagEntries();
    final counts = <String, int>{};
    for (final names in widget.db.listAllBookmarkTags().values) {
      for (final n in names) {
        counts[n] = (counts[n] ?? 0) + 1;
      }
    }
    setState(() {
      _tags = tags;
      _usage = counts;
    });
  }

  Future<void> _delete(String tagId, String name) async {
    final count = _usage[name] ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除标签'),
        content: Text(
          count > 0
              ? '标签“$name”正被 $count 条书签使用，删除后关联会一并移除，书签本身不受影响。'
              : '确定删除标签“$name”吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    widget.db.deleteTag(tagId);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('管理标签'),
      content: SizedBox(
        width: 380,
        child: _tags.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text('暂无标签', style: theme.textTheme.bodySmall),
                ),
              )
            : SizedBox(
                height: 320,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _tags.length,
                  itemBuilder: (context, index) {
                    final t = _tags[index];
                    final count = _usage[t.name] ?? 0;
                    return ListTile(
                      dense: true,
                      title: Text(t.name),
                      subtitle: Text(count > 0 ? '$count 条书签' : '未使用'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: '删除标签',
                        onPressed: () => _delete(t.id, t.name),
                      ),
                    );
                  },
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
