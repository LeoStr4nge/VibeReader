import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:charset/charset.dart' show gbk;

import 'package:novel_reader/src/utils/text_decoding.dart';

void main() {
  group('decodeTextBytes', () {
    test('无 BOM 的 UTF-8 中文正常解码', () {
      final bytes = utf8.encode('第一章 初见');
      expect(decodeTextBytes(bytes), '第一章 初见');
    });

    test('UTF-8 BOM 被剥离', () {
      final bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode('第二章 重逢')];
      expect(decodeTextBytes(bytes), '第二章 重逢');
    });

    test('GBK 中文回退解码', () {
      final bytes = gbk.encode('第三章 离别');
      // GBK 字节流对 UTF-8 是非法序列，应回退 GBK 解码
      expect(decodeTextBytes(Uint8List.fromList(bytes)), '第三章 离别');
    });

    test('UTF-16 LE BOM 解码', () {
      const text = '第四章 归来';
      final units = text.codeUnits;
      final bytes = <int>[0xFF, 0xFE];
      for (final u in units) {
        bytes.add(u & 0xFF);
        bytes.add((u >> 8) & 0xFF);
      }
      expect(decodeTextBytes(bytes), text);
    });

    test('纯 ASCII 内容', () {
      expect(decodeTextBytes(ascii.encode('hello world')), 'hello world');
    });
  });
}
