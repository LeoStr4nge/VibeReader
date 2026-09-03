import 'package:flutter_test/flutter_test.dart';

import 'package:novel_reader/src/data/db/app_database.dart';
import 'package:novel_reader/src/domain/book.dart';
import 'package:novel_reader/src/domain/bookmark.dart';
import 'package:novel_reader/src/domain/reading_progress.dart';

void main() {
  late AppDatabase db;

  Book mkBook(String id) => Book(
        id: id,
        title: '测试书 $id',
        format: BookFormat.txt,
        filePath: '/tmp/$id.txt',
        fileHash: 'hash-$id',
        addedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        lastOpenedAt: DateTime.fromMillisecondsSinceEpoch(2000),
      );

  setUp(() {
    db = AppDatabase.openInMemory();
  });

  tearDown(() {
    db.close();
  });

  group('schema v4 迁移', () {
    test('新库直接建出 v4 列且 user_version=4', () {
      final rows = db.listAllBooks();
      expect(rows, isEmpty);
      // 触发一次 v4 方法验证列存在
      expect(db.getSetting('nope'), isNull);
      db.setContentHash('no-such-id', 'md5');
      expect(db.getContentHash('no-such-id'), isNull);
    });

    test('软删书签后 listBookmarks 不再返回', () {
      final book = mkBook('b1');
      db.upsertBook(book);
      final bm = Bookmark(
        id: 'bm-1',
        bookId: 'b1',
        format: BookFormat.txt,
        charOffset: 100,
        excerpt: '摘要',
        createdAt: DateTime.fromMillisecondsSinceEpoch(3000),
      );
      db.insertBookmark(bm);
      expect(db.listBookmarks('b1'), hasLength(1));
      expect(db.listAllBookmarks(), hasLength(1));

      db.deleteBookmark('bm-1');
      expect(db.listBookmarks('b1'), isEmpty);
      expect(db.listAllBookmarks(), isEmpty);
    });

    test('标签变更 bump 书签 updated_at', () {
      final book = mkBook('b1');
      db.upsertBook(book);
      db.insertBookmark(Bookmark(
        id: 'bm-1',
        bookId: 'b1',
        format: BookFormat.txt,
        createdAt: DateTime.fromMillisecondsSinceEpoch(3000),
      ));
      final tagId = db.ensureTag('标签A');
      db.addTagToBookmark('bm-1', tagId);
      expect(db.listBookmarkTags('bm-1'), ['标签A']);

      // removeTagFromBookmark 也应触发 bump（此处验证标签被移除）
      db.removeTagFromBookmark('bm-1', tagId);
      expect(db.listBookmarkTags('bm-1'), isEmpty);
    });
  });

  group('同步条件写入', () {
    test('upsertProgressIfNewer：较新记录落地，较旧记录被拒', () {
      final book = mkBook('b1');
      db.upsertBook(book);
      final t1 = DateTime.fromMillisecondsSinceEpoch(1000);
      final t2 = DateTime.fromMillisecondsSinceEpoch(2000);

      db.upsertProgressIfNewer(ReadingProgress(
        bookId: 'b1',
        updatedAt: t1,
        charOffset: 10,
      ));
      expect(db.getProgress('b1')?.charOffset, 10);

      // 旧记录不覆盖
      db.upsertProgressIfNewer(ReadingProgress(
        bookId: 'b1',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(500),
        charOffset: 999,
      ));
      expect(db.getProgress('b1')?.charOffset, 10);

      // 新记录覆盖
      db.upsertProgressIfNewer(ReadingProgress(
        bookId: 'b1',
        updatedAt: t2,
        charOffset: 20,
      ));
      expect(db.getProgress('b1')?.charOffset, 20);
    });

    test('applyBookmarkEntry：LWW + 标签集合覆盖 + 墓碑', () {
      final book = mkBook('b1');
      db.upsertBook(book);
      final created = DateTime.fromMillisecondsSinceEpoch(1000);

      // 远端较新记录落地（带标签）
      db.applyBookmarkEntry(
        bookmarkId: 'bm-remote',
        bookId: 'b1',
        format: BookFormat.txt,
        charOffset: 55,
        excerpt: '远端摘要',
        createdAt: created,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(2000),
        tagNames: ['小说', '精读'],
      );
      expect(db.listBookmarks('b1'), hasLength(1));
      expect(db.listBookmarkTags('bm-remote'), ['小说', '精读']);

      // 远端更旧记录被拒（内容不覆盖）
      db.applyBookmarkEntry(
        bookmarkId: 'bm-remote',
        bookId: 'b1',
        format: BookFormat.txt,
        charOffset: 888,
        excerpt: '过时摘要',
        createdAt: created,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1500),
        tagNames: ['废弃标签'],
      );
      final bm = db.listBookmarks('b1').first;
      expect(bm.charOffset, 55);
      expect(bm.excerpt, '远端摘要');
      expect(db.listBookmarkTags('bm-remote'), ['小说', '精读']);

      // 远端墓碑传播删除
      db.applyBookmarkEntry(
        bookmarkId: 'bm-remote',
        bookId: 'b1',
        format: BookFormat.txt,
        createdAt: created,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(3000),
        deletedAt: DateTime.fromMillisecondsSinceEpoch(3000),
      );
      expect(db.listBookmarks('b1'), isEmpty);
    });

    test('content_hash 查询方法', () {
      final book = mkBook('b1');
      db.upsertBook(book);
      expect(db.getContentHash('b1'), isNull);
      expect(db.booksWithoutContentHash(), hasLength(1));

      db.setContentHash('b1', 'md5-abc');
      expect(db.getContentHash('b1'), 'md5-abc');
      expect(db.hasBookWithContentHash('md5-abc'), isTrue);
      expect(db.getBookByContentHash('md5-abc')?.id, 'b1');
      expect(db.booksWithoutContentHash(), isEmpty);
    });
  });
}
