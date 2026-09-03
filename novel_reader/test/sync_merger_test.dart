import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:novel_reader/src/data/db/app_database.dart';
import 'package:novel_reader/src/domain/book.dart';
import 'package:novel_reader/src/domain/bookmark.dart';
import 'package:novel_reader/src/domain/reading_progress.dart';
import 'package:novel_reader/src/sync/sync_merger.dart';
import 'package:novel_reader/src/sync/sync_models.dart';
import 'package:novel_reader/src/utils/hash.dart';

void main() {
  late Directory tmpDir;
  late AppDatabase dbA;
  late AppDatabase dbB;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('sync_test');
    dbA = AppDatabase.openInMemory();
    dbB = AppDatabase.openInMemory();
  });

  tearDown(() async {
    dbA.close();
    dbB.close();
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}
  });

  /// 建一本带真实文件的书（内容决定 contentHash）。
  Future<Book> addBook(AppDatabase db, String fileName, String content,
      {DateTime? addedAt}) async {
    final path = '${tmpDir.path}${Platform.pathSeparator}$fileName';
    File(path).writeAsStringSync(content);
    final book = Book(
      id: sha1OfString(path),
      title: fileName,
      format: BookFormat.txt,
      filePath: path,
      fileHash: sha1OfString(path),
      addedAt: addedAt ?? DateTime.now(),
      lastOpenedAt: DateTime.now(),
    );
    db.upsertBook(book);
    db.setContentHash(book.id, await computeContentHashInline(path));
    return book;
  }

  test('planMerge：进度/书签双向按时间戳分流', () async {
    final bookA = await addBook(dbA, 'same.txt', '相同内容');
    // dbB 也有一份相同内容的书（不同路径）
    final bookB = await addBook(dbB, 'other_name.txt', '相同内容');

    // 进度：A 较新
    dbA.upsertProgress(ReadingProgress(
      bookId: bookA.id,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(2000),
      charOffset: 100,
    ));
    // 进度：B 较旧
    dbB.upsertProgress(ReadingProgress(
      bookId: bookB.id,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
      charOffset: 50,
    ));

    // 书签：B 较新（带标签）
    dbA.insertBookmark(Bookmark(
      id: 'bm-shared',
      bookId: bookA.id,
      format: BookFormat.txt,
      charOffset: 10,
      createdAt: DateTime.fromMillisecondsSinceEpoch(500),
    ));
    dbB.insertBookmark(Bookmark(
      id: 'bm-shared',
      bookId: bookB.id,
      format: BookFormat.txt,
      charOffset: 20,
      createdAt: DateTime.fromMillisecondsSinceEpoch(500),
    ));
    // B 侧给书签加标签（bump updated_at，确保 B 版本较新）
    final tagId = dbB.ensureTag('重要');
    dbB.addTagToBookmark('bm-shared', tagId);

    final mergerA = SyncMerger(dbA);
    final mergerB = SyncMerger(dbB);
    final manifestA = mergerA.exportManifest();
    final manifestB = mergerB.exportManifest();

    final planFromA = SyncMerger.planMerge(manifestA, manifestB);

    // A 视角：进度 A 新 → push；书签 B 新（标签 bump）→ apply
    expect(planFromA.progressToPush, hasLength(1));
    expect(planFromA.progressToApply, isEmpty);
    expect(planFromA.bookmarksToApply, hasLength(1));
    expect(planFromA.bookmarksToPush, isEmpty);

    // B 视角对称
    final planFromB = SyncMerger.planMerge(manifestB, manifestA);
    expect(planFromB.progressToPush, isEmpty);
    expect(planFromB.progressToApply, hasLength(1));
    expect(planFromB.bookmarksToPush, hasLength(1));
    expect(planFromB.bookmarksToApply, isEmpty);
  });

  test('planMerge：墓碑胜出传播删除', () async {
    final bookA = await addBook(dbA, 'same.txt', '内容');
    await addBook(dbB, 'renamed.txt', '内容');

    dbA.insertBookmark(Bookmark(
      id: 'bm-del',
      bookId: bookA.id,
      format: BookFormat.txt,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
    ));
    dbA.deleteBookmark('bm-del'); // 软删 → 墓碑

    final plan = SyncMerger.planMerge(
      SyncMerger(dbA).exportManifest(),
      SyncMerger(dbB).exportManifest(),
    );
    expect(plan.bookmarksToPush, hasLength(1));
    expect(plan.bookmarksToPush.first.deletedAt, isNotNull);
  });

  test('planMerge：对方没有的书文件 → 上传/下载计划', () async {
    final bookOnlyInA = await addBook(dbA, 'only_a.txt', 'A 独有');

    final plan = SyncMerger.planMerge(
      SyncMerger(dbA).exportManifest(),
      SyncMerger(dbB).exportManifest(),
    );
    expect(plan.filesToUpload, hasLength(1));
    expect(plan.filesToUpload.first.contentHash,
        dbA.getContentHash(bookOnlyInA.id));

    final reversePlan = SyncMerger.planMerge(
      SyncMerger(dbB).exportManifest(),
      SyncMerger(dbA).exportManifest(),
    );
    expect(reversePlan.filesToDownload, hasLength(1));
  });

  test('收敛性：双向应用后两端清单一致', () async {
    final bookA1 = await addBook(dbA, 'book1.txt', '第一本书');
    final bookA2 = await addBook(dbA, 'book2.txt', '第二本书');
    final bookB2 = await addBook(dbB, 'b2copy.txt', '第二本书'); // B 也有 book2

    // A: book1 进度较新；B: book2 进度较新
    dbA.upsertProgress(ReadingProgress(
      bookId: bookA1.id,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(3000),
      charOffset: 111,
    ));
    dbB.upsertProgress(ReadingProgress(
      bookId: bookB2.id,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(4000),
      charOffset: 222,
    ));

    // A: bm-x 新；B: bm-y 新；A: bm-z 被删
    dbA.insertBookmark(Bookmark(
      id: 'bm-x',
      bookId: bookA1.id,
      format: BookFormat.txt,
      createdAt: DateTime.fromMillisecondsSinceEpoch(100),
    ));
    dbB.insertBookmark(Bookmark(
      id: 'bm-y',
      bookId: bookB2.id,
      format: BookFormat.txt,
      createdAt: DateTime.fromMillisecondsSinceEpoch(100),
    ));
    dbA.insertBookmark(Bookmark(
      id: 'bm-z',
      bookId: bookA2.id,
      format: BookFormat.txt,
      createdAt: DateTime.fromMillisecondsSinceEpoch(100),
    ));
    dbA.deleteBookmark('bm-z');

    final mergerA = SyncMerger(dbA);
    final mergerB = SyncMerger(dbB);

    // A 视角合并并应用（模拟：A 收到 B 的记录）
    final planA = SyncMerger.planMerge(
      mergerA.exportManifest(),
      mergerB.exportManifest(),
    );
    mergerA.applyRemoteRecords(planA, downloadedBooks: const []);

    // B 视角合并并应用（模拟：B 收到 A 的记录）
    final planB = SyncMerger.planMerge(
      mergerB.exportManifest(),
      mergerA.exportManifest(),
    );
    // 模拟 B 下载 A 独有的书文件（复制到本地新路径）
    final downloaded = <(BookEntry, String)>[];
    for (final entry in planB.filesToDownload) {
      final src = dbA.getBookByContentHash(entry.contentHash)!;
      final localPath =
          '${tmpDir.path}${Platform.pathSeparator}b_${entry.title}';
      File(src.filePath).copySync(localPath);
      downloaded.add((entry, localPath));
    }
    mergerB.applyRemoteRecords(planB, downloadedBooks: downloaded);

    // 再次导出比较（忽略 books.size 等本地差异，比对进度与书签）
    final outA = mergerA.exportManifest();
    final outB = mergerB.exportManifest();

    // 进度一致（B 未下载 book1 文件，自然没有其进度；比对共有部分）
    final pa = {for (final p in outA.progress) p.bookHash: p};
    final pb = {for (final p in outB.progress) p.bookHash: p};
    expect(pb.keys.toSet(), pa.keys.toSet().intersection(pb.keys.toSet()));
    for (final hash in pb.keys) {
      expect(pa[hash]!.charOffset, pb[hash]!.charOffset);
    }

    // 书签一致（bm-y 在 A 落地、bm-z 在 B 被删）
    final ba = {for (final b in outA.bookmarks) b.bookmarkUid: b};
    final bb = {for (final b in outB.bookmarks) b.bookmarkUid: b};
    expect(ba.keys.toSet(), containsAll(['bm-x', 'bm-y']));
    expect(ba['bm-z']!.deletedAt, isNotNull);
    expect(bb['bm-z']!.deletedAt, isNotNull);
    expect(ba['bm-y'], isNotNull);
    expect(bb['bm-x'], isNotNull);
  });
}
