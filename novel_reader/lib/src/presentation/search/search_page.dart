import 'package:flutter/material.dart';

import 'package:novel_reader/src/data/db/app_database.dart';
import 'package:novel_reader/src/domain/global_search_result.dart';
import 'package:novel_reader/src/presentation/reader/reader_page.dart';

class SearchRoute {
  static const name = '/search';
}

class GlobalSearchPage extends StatefulWidget {
  const GlobalSearchPage({super.key, required this.db});

  final AppDatabase db;

  @override
  State<GlobalSearchPage> createState() => _GlobalSearchPageState();
}

class _GlobalSearchPageState extends State<GlobalSearchPage> {
  final _controller = TextEditingController();
  List<GlobalSearchResult> _results = const [];
  bool _searched = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _doSearch(String query) {
    setState(() {
      _results = widget.db.searchAllBooks(query);
      _searched = true;
    });
  }

  void _openResult(GlobalSearchResult r) {
    Navigator.of(context).pushNamed(
      ReaderRoute.name,
      arguments: ReaderRouteArgs(
        bookId: r.bookId,
        filePath: r.filePath,
        format: r.format,
        initialOffset: r.charOffset,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 按书分组计数
    final bookCounts = <String, int>{};
    for (final r in _results) {
      bookCounts[r.bookTitle] = (bookCounts[r.bookTitle] ?? 0) + 1;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('全书架搜索')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8,  16, 8),
            child: TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText: '搜索所有已打开过的书…',
                isDense: true,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _controller.clear();
                          setState(() {
                            _results = const [];
                            _searched = false;
                          });
                        },
                      ),
                border: const OutlineInputBorder(),
              ),
              onSubmitted: _doSearch,
              onChanged: (_) => setState(() {}),
            ),
          ),
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: Text(
                      _searched ? '没有找到相关内容' : '输入关键词搜索所有书的内容',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  )
                : ListView.separated(
                    itemCount: _results.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final r = _results[index];
                      return ListTile(
                        dense: true,
                        title: Text(
                          r.excerpt,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${r.bookTitle} · ${bookCounts[r.bookTitle]} 处命中',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _openResult(r),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
