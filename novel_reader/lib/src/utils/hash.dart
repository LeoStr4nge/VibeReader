import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

String sha1OfString(String input) {
  final bytes = utf8.encode(input);
  return sha1.convert(bytes).toString();
}

/// 文件内容的流式 MD5（局域网同步的跨设备图书身份）。
/// 在后台 Isolate 中执行；闭包只捕获路径字符串（项目隔离约定）。
Future<String> computeContentHash(String filePath) {
  return Isolate.run(() async {
    final digest = await md5.bind(File(filePath).openRead()).first;
    return digest.toString();
  });
}

/// 同步版：直接在调用线程对流式计算（供 Isolate 内部或测试使用）。
Future<String> computeContentHashInline(String filePath) async {
  final digest = await md5.bind(File(filePath).openRead()).first;
  return digest.toString();
}

