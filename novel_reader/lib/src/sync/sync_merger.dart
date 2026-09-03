import 'dart:io';

import 'package:novel_reader/src/data/db/app_database.dart';
import 'package:novel_reader/src/domain/book.dart';
import 'package:novel_reader/src/domain/reading_progress.dart';
import 'package:novel_reader/src/sync/sync_models.dart';
import 'package:novel_reader/src/utils/hash.dart' show computeContentHash, sha1OfString;

/// 双端共用的记录级 LWW 合并器。
/// 计划（planMerge）为纯函数；导出与应用直接操作 AppDatabase。
class SyncMerger {
  SyncMerger(this.db);

  final AppDatabase db;

  /// 导出本端完整清单（调用前应先 [backfillContentHash]）。
  SyncManifest exportManifest() {
    final books = <BookEntry>[];
    final progressByBook = <String, ProgressEntry>{};
    final bookmarks = <BookmarkEntry>[];

    // bookId → contentHash 映射（progress/bookmark 都以它换算 bookHash）
    final hashByBookId = <String, String>{};

    for (final book in db.listAllBooks()) {
      final hash = db.getContentHash(book.id);
      if (hash == null) continue; // 无哈希的书（文件缺失等）不参与同步
      hashByBookId[book.id] = hash;
      books.add(BookEntry(
        contentHash: hash,
        title: book.title,
        format: book.format,
        size: _fileSize(book.filePath),
        addedAt: book.addedAt.millisecondsSinceEpoch,
        lastOpenedAt: book.lastOpenedAt.millisecondsSinceEpoch,
        updatedAt: book.lastOpenedAt.millisecondsSinceEpoch,
        hasFile: File(book.filePath).existsSync(),
      ));
    }

    for (final p in db.listAllProgress()) {
      final hash = hashByBookId[p.bookId];
      if (hash == null) continue;
      progressByBook[hash] = ProgressEntry(
        bookHash: hash,
        chapterId: p.chapterId,
        charOffset: p.charOffset,
        segmentIndex: p.segmentIndex,
        pdfPage: p.pdfPage,
        updatedAt: p.updatedAt.millisecondsSinceEpoch,
      );
    }

    final tagNamesByBookmark = db.listAllBookmarkTags();
    // listAllBookmarks 已过滤软删；墓碑记录需单独查询
    final tombstones = _listTombstoneEntries(hashByBookId);
    for (final r in db.listAllBookmarks()) {
      final hash = hashByBookId[r.book.id];
      if (hash == null) continue;
      // 读取 updated_at
      final updatedAt = _bookmarkUpdatedAt(r.bookmark.id);
      bookmarks.add(BookmarkEntry(
        bookmarkUid: r.bookmark.id,
        bookHash: hash,
        chapterId: r.bookmark.chapterId,
        charOffset: r.bookmark.charOffset,
        pdfPage: r.bookmark.pdfPage,
        excerpt: r.bookmark.excerpt,
        createdAt: r.bookmark.createdAt.millisecondsSinceEpoch,
        updatedAt: updatedAt,
        tagNames: tagNamesByBookmark[r.bookmark.id] ?? const [],
      ));
    }
    bookmarks.addAll(tombstones);

    return SyncManifest(
      books: books,
      progress: progressByBook.values.toList(growable: false),
      bookmarks: bookmarks,
    );
  }

  int _fileSize(String path) {
    try {
      return File(path).lengthSync();
    } catch (_) {
      return 0;
    }
  }

  int _bookmarkUpdatedAt(String bookmarkId) {
    return db.bookmarkUpdatedAt(bookmarkId);
  }

  /// 软删书签的墓碑条目。
  List<BookmarkEntry> _listTombstoneEntries(
      Map<String, String> hashByBookId) {
    final rows = db.listDeletedBookmarks();
    final result = <BookmarkEntry>[];
    for (final r in rows) {
      final hash = hashByBookId[r['book_id'] as String];
      if (hash == null) continue;
      result.add(BookmarkEntry(
        bookmarkUid: r['id'] as String,
        bookHash: hash,
        chapterId: r['chapter_id'] as int?,
        charOffset: r['char_offset'] as int?,
        pdfPage: r['pdf_page'] as int?,
        excerpt: r['excerpt'] as String?,
        createdAt: r['created_at'] as int,
        updatedAt: r['updated_at'] as int,
        deletedAt: r['deleted_at'] as int?,
        tagNames: const [],
      ));
    }
    return result;
  }

  /// 惰性补算：为没有 content_hash 的书计算并写入 MD5。
  /// [onProgress] 可选进度回调（已完成数/总数）。
  Future<void> backfillContentHash({
    void Function(int done, int total)? onProgress,
  }) async {
    final pending = db.booksWithoutContentHash();
    var done = 0;
    for (final book in pending) {
      try {
        final hash = await computeContentHash(book.filePath);
        db.setContentHash(book.id, hash);
      } catch (_) {
        // 文件缺失/不可读：跳过，该书不参与同步
      }
      done++;
      onProgress?.call(done, pending.length);
    }
  }

  /// 纯函数：比对两端清单，产出合并计划。
  static MergePlan planMerge(SyncManifest local, SyncManifest remote) {
    final localBooks = {
      for (final b in local.books) b.contentHash: b,
    };
    final remoteBooks = {
      for (final b in remote.books) b.contentHash: b,
    };
    final localProgress = {
      for (final p in local.progress) p.bookHash: p,
    };
    final remoteProgress = {
      for (final p in remote.progress) p.bookHash: p,
    };
    final localBookmarks = {
      for (final b in local.bookmarks) b.bookmarkUid: b,
    };
    final remoteBookmarks = {
      for (final b in remote.bookmarks) b.bookmarkUid: b,
    };

    // ---- 书文件互传：对方没有（或对方标记无文件）而我方有文件 ----
    final filesToUpload = <BookEntry>[];
    remoteBooks.forEach((hash, rb) {
      final lb = localBooks[hash];
      if (lb == null) {
        // 我方没有此书文件 → 需要下载（在 filesToDownload 中处理）
      }
    });
    localBooks.forEach((hash, lb) {
      if (!lb.hasFile) return;
      final rb = remoteBooks[hash];
      if (rb == null || !rb.hasFile) {
        filesToUpload.add(lb);
      }
    });

    final filesToDownload = <BookEntry>[];
    remoteBooks.forEach((hash, rb) {
      if (!rb.hasFile) return;
      final lb = localBooks[hash];
      if (lb == null || !lb.hasFile) {
        filesToDownload.add(rb);
      }
    });

    // ---- 进度：双向 LWW ----
    final progressToPush = <ProgressEntry>[]; // 本端新 → 推给对方
    final progressToApply = <ProgressEntry>[]; // 对端新 → 本地落地
    localProgress.forEach((hash, lp) {
      final rp = remoteProgress[hash];
      if (rp == null || lp.updatedAt > rp.updatedAt) {
        progressToPush.add(lp);
      }
    });
    remoteProgress.forEach((hash, rp) {
      final lp = localProgress[hash];
      if (lp == null || rp.updatedAt > lp.updatedAt) {
        progressToApply.add(rp);
      }
    });

    // ---- 书签：双向 LWW（墓碑胜出即删除）----
    final bookmarksToPush = <BookmarkEntry>[];
    final bookmarksToApply = <BookmarkEntry>[];
    localBookmarks.forEach((uid, lb) {
      final rb = remoteBookmarks[uid];
      if (rb == null || lb.updatedAt > rb.updatedAt) {
        bookmarksToPush.add(lb);
      }
    });
    remoteBookmarks.forEach((uid, rb) {
      final lb = localBookmarks[uid];
      if (lb == null || rb.updatedAt > lb.updatedAt) {
        bookmarksToApply.add(rb);
      }
    });

    return MergePlan(
      filesToUpload: filesToUpload,
      filesToDownload: filesToDownload,
      progressToPush: progressToPush,
      progressToApply: progressToApply,
      bookmarksToPush: bookmarksToPush,
      bookmarksToApply: bookmarksToApply,
    );
  }

  /// 本端较新记录集合（推送给对方）。
  static RecordSet toRecordSet(MergePlan plan) => RecordSet(
        progress: plan.progressToPush,
        bookmarks: plan.bookmarksToPush,
      );

  /// 应用远端较新记录（含下载完成的新书落地 [downloadedBooks]）。
  void applyRemoteRecords(
    MergePlan plan, {
    List<(BookEntry, String localFilePath)> downloadedBooks = const [],
  }) {
    // 1. 新下载的书落地（本地路径版 Book 行 + content_hash）
    for (final (entry, localPath) in downloadedBooks) {
      final existing = db.getBookByContentHash(entry.contentHash);
      if (existing != null) {
        db.setContentHash(existing.id, entry.contentHash);
        continue;
      }
      final bookId = sha1OfString(localPath);
      db.applyBookMeta(
        book: Book(
          id: bookId,
          title: entry.title,
          format: entry.format,
          filePath: localPath,
          fileHash: bookId,
          addedAt: DateTime.fromMillisecondsSinceEpoch(entry.addedAt),
          lastOpenedAt:
              DateTime.fromMillisecondsSinceEpoch(entry.lastOpenedAt),
        ),
        contentHash: entry.contentHash,
      );
    }

    // 2. 进度/书签落地（contentHash → 本地 bookId）
    for (final p in plan.progressToApply) {
      final book = db.getBookByContentHash(p.bookHash);
      if (book == null) continue; // 本地没有此书（文件同步失败等），跳过
      db.upsertProgressIfNewer(ReadingProgress(
        bookId: book.id,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(p.updatedAt),
        chapterId: p.chapterId,
        charOffset: p.charOffset,
        segmentIndex: p.segmentIndex,
        pdfPage: p.pdfPage,
      ));
    }

    for (final b in plan.bookmarksToApply) {
      final book = db.getBookByContentHash(b.bookHash);
      if (book == null) continue;
      db.applyBookmarkEntry(
        bookmarkId: b.bookmarkUid,
        bookId: book.id,
        format: book.format,
        chapterId: b.chapterId,
        charOffset: b.charOffset,
        pdfPage: b.pdfPage,
        excerpt: b.excerpt,
        createdAt: DateTime.fromMillisecondsSinceEpoch(b.createdAt),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(b.updatedAt),
        deletedAt:
            b.deletedAt == null ? null : DateTime.fromMillisecondsSinceEpoch(b.deletedAt!),
        tagNames: b.tagNames,
      );
    }
  }
}

/// 合并计划。
class MergePlan {
  const MergePlan({
    required this.filesToUpload,
    required this.filesToDownload,
    required this.progressToPush,
    required this.progressToApply,
    required this.bookmarksToPush,
    required this.bookmarksToApply,
  });

  final List<BookEntry> filesToUpload;
  final List<BookEntry> filesToDownload;
  final List<ProgressEntry> progressToPush;
  final List<ProgressEntry> progressToApply;
  final List<BookmarkEntry> bookmarksToPush;
  final List<BookmarkEntry> bookmarksToApply;

  int get recordCount =>
      progressToPush.length +
      progressToApply.length +
      bookmarksToPush.length +
      bookmarksToApply.length;
}
