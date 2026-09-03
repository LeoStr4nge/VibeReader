import 'package:novel_reader/src/domain/book.dart';

/// 全书架搜索的一条命中。
class GlobalSearchResult {
  const GlobalSearchResult({
    required this.bookId,
    required this.bookTitle,
    required this.filePath,
    required this.format,
    required this.excerpt,
    required this.charOffset,
  });

  final String bookId;
  final String bookTitle;
  final String filePath;
  final BookFormat format;

  /// 命中前后摘录（含 … 省略标记）。
  final String excerpt;

  /// 命中位置在全书中的字符偏移（用于跳转）。
  final int charOffset;
}
