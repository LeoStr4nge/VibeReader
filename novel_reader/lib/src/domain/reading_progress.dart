class ReadingProgress {
  const ReadingProgress({
    required this.bookId,
    required this.updatedAt,
    this.chapterId,
    this.charOffset,
    this.segmentIndex,
    this.pdfPage,
  });

  final String bookId;
  final DateTime updatedAt;

  final int? chapterId;
  final int? charOffset;
  final int? segmentIndex;

  final int? pdfPage;
}

