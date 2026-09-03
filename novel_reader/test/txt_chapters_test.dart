import 'package:flutter_test/flutter_test.dart';

import 'package:novel_reader/src/data/parsers/txt_chapters.dart';

void main() {
  group('detectTxtChapters', () {
    test('识别“第X章”并生成目录', () {
      const text = '这是开头的引言部分。\n\n'
          '第一章 起点\n这是第一章的内容。\n'
          '第二章 转折\n这是第二章的内容。\n'
          '第三章 结局\n这是第三章的内容。\n';
      final chapters = detectTxtChapters(text);

      expect(chapters.length, 4); // 开头 + 3 章
      expect(chapters[0].title, '开头');
      expect(chapters[0].start, 0);
      expect(chapters[1].title, '第一章 起点');
      expect(chapters[1].end, chapters[2].start);
      expect(chapters[3].end, text.length);
    });

    test('中文数字章节', () {
      const text = '第十二章 大战\n内容甲。\n第一百零三章 终点\n内容乙。\n';
      final chapters = detectTxtChapters(text);

      expect(chapters.length, 2);
      expect(chapters[0].title, '第十二章 大战');
      expect(chapters[1].title, '第一百零三章 终点');
    });

    test('标题含空格/前导零也能识别', () {
      const text = '第001章 fgo奥菲利亚无惨\n内容甲。\n'
          '第004章 fgo 赌场\n内容乙。\n'
          '第055章 最终决战\n内容丙。\n';
      final chapters = detectTxtChapters(text);

      expect(chapters.length, 3);
      expect(chapters[0].title, '第001章 fgo奥菲利亚无惨');
      expect(chapters[1].title, '第004章 fgo 赌场');
      expect(chapters[2].title, '第055章 最终决战');
    });

    test('全角数字章节', () {
      const text = '第０１章 起\n内容。\n第０２章 承\n内容。\n';
      final chapters = detectTxtChapters(text);

      expect(chapters.length, 2);
      expect(chapters[0].title, '第０１章 起');
    });

    test('命中过少时返回空目录', () {
      const text = '只有一段普通正文，提到了第一章这个词但不成目录。\n正文继续。\n';
      expect(detectTxtChapters(text), isEmpty);
    });

    test('长行不误判为章节标题', () {
      final longLine = '第' * 40; // 超长行
      final text = '第一章 甲\n内容。\n$longLine\n第二章 乙\n内容。\n';
      final chapters = detectTxtChapters(text);

      expect(chapters.length, 2);
      expect(chapters[0].title, '第一章 甲');
    });
  });
}
