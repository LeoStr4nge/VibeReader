enum BookFormat {
  txt,
  pdf,
  unknown,
}

class Book {
  const Book({
    required this.id,
    required this.title,
    required this.format,
    required this.filePath,
    required this.fileHash,
    required this.addedAt,
    required this.lastOpenedAt,
  });

  final String id;
  final String title;
  final BookFormat format;
  final String filePath;
  final String fileHash;
  final DateTime addedAt;
  final DateTime lastOpenedAt;
}

