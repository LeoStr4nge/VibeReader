import 'dart:convert';

import 'package:novel_reader/src/domain/book.dart';

/// 同步协议线格式（v1）。
/// 所有时均为毫秒时间戳；图书以 contentHash（文件内容 MD5）为跨设备身份。

class SyncManifest {
  const SyncManifest({
    required this.books,
    required this.progress,
    required this.bookmarks,
  });

  final List<BookEntry> books;
  final List<ProgressEntry> progress;
  final List<BookmarkEntry> bookmarks;

  Map<String, dynamic> toJson() => {
        'books': [for (final b in books) b.toJson()],
        'progress': [for (final p in progress) p.toJson()],
        'bookmarks': [for (final b in bookmarks) b.toJson()],
      };

  static SyncManifest fromJson(Map<String, dynamic> json) => SyncManifest(
        books: [
          for (final b in (json['books'] as List))
            BookEntry.fromJson(b as Map<String, dynamic>),
        ],
        progress: [
          for (final p in (json['progress'] as List))
            ProgressEntry.fromJson(p as Map<String, dynamic>),
        ],
        bookmarks: [
          for (final b in (json['bookmarks'] as List))
            BookmarkEntry.fromJson(b as Map<String, dynamic>),
        ],
      );

  String encode() => jsonEncode(toJson());

  static SyncManifest decode(String body) =>
      fromJson(jsonDecode(body) as Map<String, dynamic>);
}

class BookEntry {
  const BookEntry({
    required this.contentHash,
    required this.title,
    required this.format,
    required this.size,
    required this.addedAt,
    required this.lastOpenedAt,
    required this.updatedAt,
    required this.hasFile,
    this.tagNames = const [],
  });

  final String contentHash;
  final String title;
  final BookFormat format;
  final int size;
  final int addedAt;
  final int lastOpenedAt;
  final int updatedAt;
  final bool hasFile;

  /// 书签标签以外的书籍级别信息（v1 预留，当前为空集合）。
  final List<String> tagNames;

  Map<String, dynamic> toJson() => {
        'contentHash': contentHash,
        'title': title,
        'format': format.name,
        'size': size,
        'addedAt': addedAt,
        'lastOpenedAt': lastOpenedAt,
        'updatedAt': updatedAt,
        'hasFile': hasFile,
        'tagNames': tagNames,
      };

  static BookEntry fromJson(Map<String, dynamic> json) => BookEntry(
        contentHash: json['contentHash'] as String,
        title: json['title'] as String,
        format: BookFormat.values.asNameMap()[json['format']] ??
            BookFormat.unknown,
        size: (json['size'] as num?)?.toInt() ?? 0,
        addedAt: (json['addedAt'] as num).toInt(),
        lastOpenedAt: (json['lastOpenedAt'] as num).toInt(),
        updatedAt: (json['updatedAt'] as num).toInt(),
        hasFile: json['hasFile'] as bool? ?? false,
        tagNames: [
          for (final t in (json['tagNames'] as List? ?? [])) t as String,
        ],
      );
}

class ProgressEntry {
  const ProgressEntry({
    required this.bookHash,
    required this.updatedAt,
    this.chapterId,
    this.charOffset,
    this.segmentIndex,
    this.pdfPage,
  });

  final String bookHash;
  final int? chapterId;
  final int? charOffset;
  final int? segmentIndex;
  final int? pdfPage;
  final int updatedAt;

  Map<String, dynamic> toJson() => {
        'bookHash': bookHash,
        'chapterId': chapterId,
        'charOffset': charOffset,
        'segmentIndex': segmentIndex,
        'pdfPage': pdfPage,
        'updatedAt': updatedAt,
      };

  static ProgressEntry fromJson(Map<String, dynamic> json) => ProgressEntry(
        bookHash: json['bookHash'] as String,
        chapterId: (json['chapterId'] as num?)?.toInt(),
        charOffset: (json['charOffset'] as num?)?.toInt(),
        segmentIndex: (json['segmentIndex'] as num?)?.toInt(),
        pdfPage: (json['pdfPage'] as num?)?.toInt(),
        updatedAt: (json['updatedAt'] as num).toInt(),
      );
}

class BookmarkEntry {
  const BookmarkEntry({
    required this.bookmarkUid,
    required this.bookHash,
    required this.createdAt,
    required this.updatedAt,
    this.chapterId,
    this.charOffset,
    this.pdfPage,
    this.excerpt,
    this.deletedAt,
    this.tagNames = const [],
  });

  /// 创建时生成的书签 id（时间戳+随机数），跨设备保持不变。
  final String bookmarkUid;
  final String bookHash;
  final int? chapterId;
  final int? charOffset;
  final int? pdfPage;
  final String? excerpt;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final List<String> tagNames;

  Map<String, dynamic> toJson() => {
        'bookmarkUid': bookmarkUid,
        'bookHash': bookHash,
        'chapterId': chapterId,
        'charOffset': charOffset,
        'pdfPage': pdfPage,
        'excerpt': excerpt,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'deletedAt': deletedAt,
        'tagNames': tagNames,
      };

  static BookmarkEntry fromJson(Map<String, dynamic> json) => BookmarkEntry(
        bookmarkUid: json['bookmarkUid'] as String,
        bookHash: json['bookHash'] as String,
        chapterId: (json['chapterId'] as num?)?.toInt(),
        charOffset: (json['charOffset'] as num?)?.toInt(),
        pdfPage: (json['pdfPage'] as num?)?.toInt(),
        excerpt: json['excerpt'] as String?,
        createdAt: (json['createdAt'] as num).toInt(),
        updatedAt: (json['updatedAt'] as num).toInt(),
        deletedAt: (json['deletedAt'] as num?)?.toInt(),
        tagNames: [
          for (final t in (json['tagNames'] as List? ?? [])) t as String,
        ],
      );
}

/// 客户端推送到服务端的"本端较新记录"集合。
class RecordSet {
  const RecordSet({
    required this.progress,
    required this.bookmarks,
  });

  final List<ProgressEntry> progress;
  final List<BookmarkEntry> bookmarks;

  Map<String, dynamic> toJson() => {
        'progress': [for (final p in progress) p.toJson()],
        'bookmarks': [for (final b in bookmarks) b.toJson()],
      };

  static RecordSet fromJson(Map<String, dynamic> json) => RecordSet(
        progress: [
          for (final p in (json['progress'] as List))
            ProgressEntry.fromJson(p as Map<String, dynamic>),
        ],
        bookmarks: [
          for (final b in (json['bookmarks'] as List))
            BookmarkEntry.fromJson(b as Map<String, dynamic>),
        ],
      );

  String encode() => jsonEncode(toJson());
}
