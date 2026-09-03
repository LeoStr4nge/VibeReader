import 'dart:convert';
import 'dart:io';

import 'package:charset/charset.dart' show gbk, utf16;

/// 读取文本文件并自动识别编码：BOM 检测 → UTF-8 严格解码 → GBK 回退。
///
/// 必须保持为顶层函数：阅读页的 Isolate.run 闭包只捕获路径字符串，
/// 不能连带捕获 UI 对象（否则 isolate 消息非法）。
String readTextFileSync(String path) {
  final bytes = File(path).readAsBytesSync();
  return decodeTextBytes(bytes);
}

/// 解码字节：UTF-8 BOM / UTF-16 LE·BE BOM 检测，
/// 无 BOM 先按 UTF-8 严格试，失败回退 GBK（中文 TXT 常见编码）。
String decodeTextBytes(List<int> bytes) {
  if (bytes.length >= 2) {
    // UTF-16 LE BOM
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return utf16.decode(bytes);
    }
    // UTF-16 BE BOM
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return utf16.decode(bytes);
    }
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    // UTF-8 BOM
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  // 无 BOM：GBK 中文文件几乎必然包含非法 UTF-8 序列，可据此区分
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return gbk.decode(bytes, allowMalformed: true);
  }
}
