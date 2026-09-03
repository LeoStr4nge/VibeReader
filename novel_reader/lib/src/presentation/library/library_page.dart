import 'dart:io';

import 'package:flutter/material.dart';
import 'package:novel_reader/src/data/db/app_database.dart';
import 'package:novel_reader/src/domain/book.dart';
import 'package:novel_reader/src/presentation/reader/reader_page.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.db});

  final AppDatabase db;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  List<Book> _recent = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// Android FUSE 文件系统上 stat 调用偶发失败（文件刚写入或系统繁忙时），
  /// 单次 exists() 可能误报“文件不存在”。重试确认，
  /// 避免点刷新后书架误过滤、清理失效书籍时误删记录。
  static Future<bool> _fileExists(String path) async {
    for (var i = 0; i < 3; i++) {
      try {
        if (await File(path).exists()) return true;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return false;
  }

  /// 读取书架并过滤掉源文件已不存在的书。
  ///
  /// 只做显示层过滤、不删数据库记录：进度/书签/同步数据保留，
  /// 文件移回原位置后重新刷新即可恢复显示。
  Future<void> _refresh() async {
    final visible = <Book>[];
    for (final b in widget.db.listRecentBooks()) {
      if (await _fileExists(b.filePath)) visible.add(b);
    }
    if (!mounted) return;
    setState(() => _recent = visible);
  }

  /// 清理源文件已不存在的书籍记录（含其进度/书签/搜索索引，级联删除）。
  Future<void> _cleanMissingBooks() async {
    final missing = <Book>[];
    for (final b in widget.db.listRecentBooks()) {
      if (!await _fileExists(b.filePath)) missing.add(b);
    }

    if (missing.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有需要清理的失效书籍')),
        );
      }
      return;
    }

    final titles = missing.take(5).map((b) => '· ${b.title}').join('\n');
    final suffix = missing.length > 5 ? '\n… 等共 ${missing.length} 本' : '';
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理失效书籍'),
        content: Text(
          '以下书籍的源文件已不存在，将删除其书架记录和进度/书签：\n\n'
          '$titles$suffix',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    for (final b in missing) {
      widget.db.deleteBook(b.id);
    }
    _refresh();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已清理 ${missing.length} 本失效书籍')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书架'),
        actions: [
          IconButton(
            onPressed: () =>
                Navigator.of(context).pushNamed('/bookmarks'),
            icon: const Icon(Icons.bookmarks_outlined),
            tooltip: '书签与标签',
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pushNamed('/sync'),
            icon: const Icon(Icons.sync),
            tooltip: '局域网同步',
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pushNamed('/search'),
            icon: const Icon(Icons.search),
            tooltip: '全书架搜索',
          ),
          IconButton(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pushNamed('/files'),
            icon: const Icon(Icons.folder_open),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (value) {
              if (value == 'clean') _cleanMissingBooks();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'clean',
                child: Row(
                  children: [
                    Icon(Icons.delete_sweep, size: 20),
                    SizedBox(width: 8),
                    Text('清理失效书籍'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: _recent.isEmpty
          ? const Center(child: Text('暂无最近阅读'))
          : Scrollbar(
              interactive: true,
              child: ListView.separated(
              itemCount: _recent.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final book = _recent[index];
                return ListTile(
                  title: Text(book.title),
                  subtitle: Text(book.filePath),
                  trailing: Text(_formatLabel(book.format)),
                  onTap: () async {
                    await Navigator.of(context).pushNamed(
                      ReaderRoute.name,
                      arguments: ReaderRouteArgs(
                        bookId: book.id,
                        filePath: book.filePath,
                        format: book.format,
                      ),
                    );
                    // 从阅读页返回时刷新：最近打开时间已变化，
                    // 书架需要重新按最近阅读排序。
                    _refresh();
                  },
                );
              },
              ),
            ),
    );
  }

  String _formatLabel(BookFormat format) {
    switch (format) {
      case BookFormat.txt:
        return 'TXT';
      case BookFormat.pdf:
        return 'PDF';
      case BookFormat.unknown:
        return '未知';
    }
  }
}

