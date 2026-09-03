import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:novel_reader/src/utils/hash.dart';

void main() {
  test('computeContentHash 对同一内容稳定、对不同内容不同', () async {
    final dir = await Directory.systemTemp.createTemp('hash_test');
    addTearDown(() => dir.deleteSync(recursive: true));

    final a1 = File('${dir.path}${Platform.pathSeparator}a1.txt')
      ..writeAsStringSync('第一章 内容相同的文本');
    final a2 = File('${dir.path}${Platform.pathSeparator}a2.txt')
      ..writeAsStringSync('第一章 内容相同的文本');
    final b = File('${dir.path}${Platform.pathSeparator}b.txt')
      ..writeAsStringSync('完全不同的内容');

    final h1 = await computeContentHash(a1.path);
    final h2 = await computeContentHash(a2.path);
    final hb = await computeContentHash(b.path);

    expect(h1, h2);
    expect(h1, isNot(hb));
    expect(h1, hasLength(32)); // MD5 hex
  });
}
