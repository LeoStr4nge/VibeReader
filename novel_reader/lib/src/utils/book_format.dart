import 'package:novel_reader/src/domain/book.dart';

BookFormat bookFormatFromPath(String filePath) {
  final lower = filePath.toLowerCase();
  if (lower.endsWith('.txt')) return BookFormat.txt;
  if (lower.endsWith('.pdf')) return BookFormat.pdf;
  return BookFormat.unknown;
}

