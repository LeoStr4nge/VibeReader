import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:novel_reader/src/sync/sync_models.dart';

/// 同步客户端：连接对端 SyncServer 的 HTTP 操作。
class SyncClient {
  SyncClient({http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;

  String _base(String host, int port) => 'http://$host:$port';

  /// GET /api/info：返回设备信息（含 serverTime 用于时钟偏差检测）。
  Future<Map<String, dynamic>> fetchInfo(String host, int port) async {
    final resp = await _client
        .get(Uri.parse('${_base(host, port)}/api/info'))
        .timeout(const Duration(seconds: 5));
    if (resp.statusCode != 200) {
      throw SyncNetworkException('info 请求失败: HTTP ${resp.statusCode}');
    }
    return jsonDecode(utf8.decode(resp.bodyBytes))
        as Map<String, dynamic>;
  }

  /// GET /api/manifest：拉取对端元数据清单。
  Future<SyncManifest> fetchManifest(String host, int port) async {
    final resp = await _client
        .get(Uri.parse('${_base(host, port)}/api/manifest'))
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw SyncNetworkException('manifest 请求失败: HTTP ${resp.statusCode}');
    }
    return SyncManifest.decode(utf8.decode(resp.bodyBytes));
  }

  /// POST /api/records：推送本端较新记录。
  Future<void> pushRecords(String host, int port, RecordSet records) async {
    final resp = await _client
        .post(
          Uri.parse('${_base(host, port)}/api/records'),
          headers: {'content-type': 'application/json; charset=utf-8'},
          body: records.encode(),
        )
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw SyncNetworkException('records 推送失败: HTTP ${resp.statusCode}');
    }
  }

  /// GET `/api/file/<contentHash>`：下载书文件到 [destPath]。
  /// [onProgress] 已接收字节/总字节。
  Future<void> downloadFile(
    String host,
    int port,
    String contentHash,
    String destPath, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final request = http.Request(
      'GET',
      Uri.parse('${_base(host, port)}/api/file/$contentHash'),
    );
    final response = await _client.send(request).timeout(
      const Duration(seconds: 5),
    );
    if (response.statusCode != 200) {
      throw SyncNetworkException(
          '文件下载失败: HTTP ${response.statusCode}');
    }
    final total = (response.contentLength ?? -1) < 0
        ? null
        : response.contentLength;
    final sink = File(destPath).openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
    } catch (e) {
      await sink.close();
      File(destPath).deleteSync(); // 清理残留
      rethrow;
    }
    await sink.close();
  }

  /// POST /api/file：流式上传书文件。
  /// [onProgress] 已发送字节/总字节。
  ///
  /// 使用 dart:io HttpClient 原生流式上传（http 包的 StreamedRequest
  /// 在部分平台存在 IOSink 类型冲突，报 500 "_IOSinkImpl is not a
  /// subtype of StreamConsumer&lt;Uint8List&gt;"）。
  Future<void> uploadFile(
    String host,
    int port, {
    required String filePath,
    required String title,
    required String format,
    required String contentHash,
    void Function(int sent, int total)? onProgress,
  }) async {
    final file = File(filePath);
    final total = await file.length();
    var sent = 0;

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.openUrl(
        'POST',
        Uri.parse('${_base(host, port)}/api/file'),
      );
      req.headers.set('x-title', _headerSafe(title));
      req.headers.set('x-format', format);
      req.headers.set('x-hash', contentHash);
      req.headers.contentType = ContentType.binary;
      req.contentLength = total;

      await req.addStream(
        file.openRead().map((chunk) {
          sent += chunk.length;
          onProgress?.call(sent, total);
          return chunk;
        }),
      );
      final response = await req.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw SyncNetworkException('文件上传失败: HTTP ${response.statusCode} $body');
      }
    } finally {
      client.close();
    }
  }

  void close() => _client.close();

  /// header 值仅允许 ASCII：Base64 包装非 ASCII 标题。
  static String _headerSafe(String s) {
    if (s.codeUnits.every((c) => c >= 32 && c < 127)) return s;
    return base64Encode(utf8.encode(s));
  }
}

class SyncNetworkException implements Exception {
  SyncNetworkException(this.message);
  final String message;

  @override
  String toString() => message;
}
