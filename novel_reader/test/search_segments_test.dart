import 'package:flutter_test/flutter_test.dart';

import 'package:novel_reader/src/data/db/app_database.dart';
import 'package:novel_reader/src/domain/book.dart';

void main() {
  late AppDatabase db;

  Book makeBook(String id, String title) => Book(
        id: id,
        title: title,
        format: BookFormat.txt,
        filePath: 'C:/books/$id.txt',
        fileHash: id,
        addedAt: DateTime.now(),
        lastOpenedAt: DateTime.now(),
      );

  setUp(() {
    db = AppDatabase.openInMemory();
  });

  test('建索引后可跨书搜索并返回正确偏移', () {
    final bookA = makeBook('a', '书甲');
    final bookB = makeBook('b', '书乙');
    db.upsertBook(bookA);
    db.upsertBook(bookB);

    // 书甲：500 字后出现关键词
    final textA = '${'甲' * 520}关键词出现在这里${'甲' * 100}';
    // 书乙：开头即关键词
    final textB = '关键词在开头${'乙' * 30}';
    db.buildSearchSegments('a', textA);
    db.buildSearchSegments('b', textB);

    final hits = db.searchAllBooks('关键词');
    expect(hits.length, 2);

    final hitA = hits.firstWhere((h) => h.bookId == 'a');
    expect(hitA.charOffset, textA.indexOf('关键词'));
    expect(hitA.excerpt.contains('关键词'), isTrue);
    final hitB = hits.firstWhere((h) => h.bookId == 'b');
    expect(hitB.charOffset, 0);
  });

  test('重复建索引会跳过（不产生重复行）', () {
    db.upsertBook(makeBook('a', '书甲'));
    final text = 'x' * 1200; // 3 片
    db.buildSearchSegments('a', text);
    db.buildSearchSegments('a', text); // 第二次应跳过

    final hits = db.searchAllBooks('x');
    expect(hits.length, 3);
  });

  test('未建索引的书不出现在结果中', () {
    db.upsertBook(makeBook('a', '书甲'));
    final hits = db.searchAllBooks('任意词');
    expect(hits, isEmpty);
  });
}
