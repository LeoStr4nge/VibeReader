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
  late List<Book> _recent;

  @override
  void initState() {
    super.initState();
    _recent = widget.db.listRecentBooks();
  }

  void _refresh() {
    setState(() {
      _recent = widget.db.listRecentBooks();
    });
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
        ],
      ),
      body: _recent.isEmpty
          ? const Center(child: Text('暂无最近阅读'))
          : ListView.separated(
              itemCount: _recent.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final book = _recent[index];
                return ListTile(
                  title: Text(book.title),
                  subtitle: Text(book.filePath),
                  trailing: Text(_formatLabel(book.format)),
                  onTap: () {
                    Navigator.of(context).pushNamed(
                      ReaderRoute.name,
                      arguments: ReaderRouteArgs(
                        bookId: book.id,
                        filePath: book.filePath,
                        format: book.format,
                      ),
                    );
                  },
                );
              },
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

