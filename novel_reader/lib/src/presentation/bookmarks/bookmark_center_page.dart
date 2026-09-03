import 'package:flutter/material.dart';

import 'package:novel_reader/src/data/db/app_database.dart';
import 'package:novel_reader/src/domain/book.dart';
import 'package:novel_reader/src/domain/bookmark.dart';
import 'package:novel_reader/src/presentation/bookmarks/bookmark_sheet.dart';
import 'package:novel_reader/src/presentation/reader/reader_page.dart';

class BookmarkCenterRoute {
  static const name = '/bookmarks';
}

/// 书签 + 标签中心：跨书查看全部书签，按标签筛选，
/// 点击跳转到对应书籍位置，支持删除书签、编辑标签、删除标签。
class BookmarkCenterPage extends StatefulWidget {
  const BookmarkCenterPage({super.key, required this.db});

  final AppDatabase db;

  @override
  State<BookmarkCenterPage> createState() => _BookmarkCenterPageState();
}

class _BookmarkCenterPageState extends State<BookmarkCenterPage> {
  List<({Bookmark bookmark, Book book})> _items = const [];
  Map<String, List<String>> _tagMap = {};
  List<({String id, String name})> _tags = const [];
  String? _filterTag;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final items = widget.db.listAllBookmarks();
    final tags = widget.db.listTagEntries();
    setState(() {
      _items = items;
      _tags = tags;
      _tagMap = widget.db.listAllBookmarkTags();
      if (_filterTag != null && !tags.any((t) => t.name == _filterTag)) {
        _filterTag = null;
      }
    });
  }

  void _open(Bookmark bookmark, Book book) {
    Navigator.of(context).pushNamed(
      ReaderRoute.name,
      arguments: ReaderRouteArgs(
        bookId: book.id,
        filePath: book.filePath,
        format: book.format,
        initialOffset: bookmark.charOffset,
        initialPdfPage: bookmark.pdfPage,
      ),
    );
  }

  void _delete(Bookmark bookmark) {
    widget.db.deleteBookmark(bookmark.id);
    _load();
  }

  Future<void> _editTags(Bookmark bookmark) async {
    await showBookmarkTagEditor(context, widget.db, bookmark);
    _load();
  }

  Future<void> _confirmDeleteTag(String tagId, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除标签'),
        content: Text('确定删除标签“$name”吗？标签与其书签的关联会一并移除。'),
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
    if (ok == true) {
      widget.db.deleteTag(tagId);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _filterTag == null
        ? _items
        : _items
            .where((e) => (_tagMap[e.bookmark.id] ?? const []).contains(_filterTag))
            .toList(growable: false);

    return Scaffold(
      appBar: AppBar(
        title: const Text('书签与标签'),
        actions: [
          IconButton(
            onPressed: () async {
              await showTagManager(context, widget.db);
              _load();
            },
            icon: const Icon(Icons.sell_outlined),
            tooltip: '管理标签',
          ),
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
        ],
      ),
      body: Column(
        children: [
          if (_tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        label: const Text('全部'),
                        visualDensity: VisualDensity.compact,
                        selected: _filterTag == null,
                        onSelected: (_) =>
                            setState(() => _filterTag = null),
                      ),
                    ),
                    for (final t in _tags)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: GestureDetector(
                          onLongPress: () => _confirmDeleteTag(t.id, t.name),
                          child: FilterChip(
                            label: Text(t.name),
                            visualDensity: VisualDensity.compact,
                            selected: _filterTag == t.name,
                            onSelected: (_) =>
                                setState(() => _filterTag = t.name),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          const Divider(height: 1),
          Expanded(
              child: filtered.isEmpty
                ? Center(
                    child: Text(
                      _filterTag == null ? '暂无书签' : '该标签下暂无书签',
                      style: theme.textTheme.bodySmall,
                    ),
                  )
                : ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final e = filtered[index];
                      final bookmark = e.bookmark;
                      final tags = _tagMap[bookmark.id] ?? const [];
                      return ListTile(
                        title: Text(
                          e.book.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (bookmark.excerpt != null)
                              Text(
                                bookmark.excerpt!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
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
                                            horizontal: 6, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: theme.colorScheme.primary
                                              .withValues(alpha: 0.12),
                                          borderRadius:
                                              BorderRadius.circular(6),
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
                          ],
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) {
                            switch (value) {
                              case 'edit_tags':
                                _editTags(bookmark);
                              case 'delete':
                                _delete(bookmark);
                            }
                          },
                          itemBuilder: (context) => const [
                            PopupMenuItem(
                              value: 'edit_tags',
                              child: Text('编辑标签'),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text('删除书签'),
                            ),
                          ],
                        ),
                        onTap: () => _open(bookmark, e.book),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
