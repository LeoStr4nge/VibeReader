import 'package:novel_reader/src/domain/book.dart';

/// 一条书签：指向某本书内的位置（TXT 用 charOffset，PDF 用 pdfPage）。
class Bookmark {
  const Bookmark({
    required this.id,
    required this.bookId,
    required this.format,
    required this.createdAt,
    this.chapterId,
    this.charOffset,
    this.pdfPage,
    this.excerpt,
  });

  final String id;
  final String bookId;
  final BookFormat format;
  final DateTime createdAt;

  final int? chapterId;

  /// TXT：书签位置在全书中的字符偏移。
  final int? charOffset;

  /// PDF：书签所在页码（1 起）。
  final int? pdfPage;

  /// 书签摘录（当前页文本前若干字）。
  final String? excerpt;
}
