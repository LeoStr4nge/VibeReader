import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'package:novel_reader/src/data/db/app_database.dart';
import 'package:novel_reader/src/domain/book.dart';
import 'package:novel_reader/src/sync/sync_merger.dart';
import 'package:novel_reader/src/sync/sync_models.dart';
import 'package:novel_reader/src/utils/hash.dart';

/// 局域网同步服务端（shelf）。
/// 任一端开启后，另一端作为客户端连接拉取/推送。
class SyncServer {
  SyncServer({
    required this.db,
    required this.merger,
    required this.incomingDir,
    required this.deviceId,
    required this.deviceName,
    this.appVersion = '1.0.0',
  });

  static const int defaultPort = 45231;

  final AppDatabase db;
  final SyncMerger merger;
  final Directory incomingDir;
  final String deviceId;
  final String deviceName;
  final String appVersion;

  HttpServer? _server;

  bool get isRunning => _server != null;
  int? get port => _server?.port;

  /// 启动服务（0.0.0.0），默认端口被占时 +1 重试至 +10。
  /// 返回实际监听端口。
  Future<int> start({int port = defaultPort}) async {
    final router = Router()
      ..get('/api/info', _handleInfo)
      ..get('/api/manifest', _handleManifest)
      ..post('/api/records', _handleRecords)
      ..get('/api/file/<contentHash>', _handleFileDownload)
      ..post('/api/file', _handleFileUpload);

    var attempt = 0;
    Object? lastError;
    while (attempt <= 10) {
      try {
        _server = await shelf_io.serve(
          const Pipeline().addMiddleware(_log()).addHandler(router.call),
          InternetAddress.anyIPv4,
          port + attempt,
        );
        return _server!.port;
      } catch (e) {
        lastError = e;
        attempt++;
      }
    }
    throw StateException('端口 $port~${port + 10} 均被占用: $lastError');
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Middleware _log() => (inner) => (req) async {
        try {
          return await inner(req);
        } catch (e) {
          return Response(500, body: 'server error: $e');
        }
      };

  // ---------------- 端点 ----------------

  /// GET /api/info：设备信息 + 服务时间（客户端时钟偏差检测）。
  Future<Response> _handleInfo(Request req) async {
    return Response.ok(
      jsonEncode({
        'deviceId': deviceId,
        'deviceName': deviceName,
        'platform': Platform.operatingSystem,
        'appVersion': appVersion,
        'protocolVersion': 1,
        'serverTime': DateTime.now().millisecondsSinceEpoch,
        'httpPort': _server?.port,
      }),
      headers: _jsonHeaders,
    );
  }

  /// GET /api/manifest：全量元数据清单。
  Future<Response> _handleManifest(Request req) async {
    await merger.backfillContentHash();
    final manifest = merger.exportManifest();
    return Response.ok(manifest.encode(), headers: _jsonHeaders);
  }

  /// POST /api/records：接收对方较新记录，条件落地。
  Future<Response> _handleRecords(Request req) async {
    final body = await req.readAsString();
    final recordSet =
        RecordSet.fromJson(jsonDecode(body) as Map<String, dynamic>);

    var appliedProgress = 0;
    var appliedBookmarks = 0;
    // 构造一个只含 apply 部分的计划复用落地逻辑
    final plan = MergePlan(
      filesToUpload: const [],
      filesToDownload: const [],
      progressToPush: const [],
      progressToApply: recordSet.progress,
      bookmarksToPush: const [],
      bookmarksToApply: recordSet.bookmarks,
    );
    final beforeProgress = db.listAllProgress().length;
    final beforeBookmarks =
        db.listAllBookmarks().length + db.listDeletedBookmarks().length;
    merger.applyRemoteRecords(plan);
    appliedProgress =
        db.listAllProgress().length - beforeProgress;
    appliedBookmarks = db.listAllBookmarks().length +
        db.listDeletedBookmarks().length -
        beforeBookmarks;

    return Response.ok(
      jsonEncode({
        'appliedProgress': appliedProgress,
        'appliedBookmarks': appliedBookmarks,
      }),
      headers: _jsonHeaders,
    );
  }

  /// GET `/api/file/<contentHash>`：下载书文件流。
  Future<Response> _handleFileDownload(Request req, String contentHash) async {
    final book = db.getBookByContentHash(contentHash);
    if (book == null || !File(book.filePath).existsSync()) {
      return Response(404, body: 'book not found');
    }
    final file = File(book.filePath);
    return Response(
      200,
      body: file.openRead(),
      headers: {
        'content-type': 'application/octet-stream',
        'content-length': '${await file.length()}',
        'x-title': _headerSafe(book.title),
        'x-format': book.format.name,
      },
    );
  }

  /// POST /api/file：上传书文件（header 元数据 + raw body 文件流）。
  Future<Response> _handleFileUpload(Request req) async {
    final title = _headerDecode(req.headers['x-title'] ?? '未命名');
    final formatName = req.headers['x-format'] ?? 'txt';
    final contentHash = req.headers['x-hash'] ?? '';
    if (contentHash.isEmpty) {
      return Response(400, body: 'missing x-hash');
    }

    // 已存在同内容的书：只补 content_hash，不重复落盘
    if (db.hasBookWithContentHash(contentHash)) {
      return Response.ok('{"ok":true,"dedup":true}',
          headers: _jsonHeaders);
    }

    if (!incomingDir.existsSync()) {
      incomingDir.createSync(recursive: true);
    }
    final partPath =
        p.join(incomingDir.path, '$contentHash.part');
    final partFile = File(partPath);
    try {
      final sink = partFile.openWrite();
      await req.read().pipe(sink);
    } catch (e) {
      if (partFile.existsSync()) partFile.deleteSync();
      return Response(500, body: 'write failed: $e');
    }

    // 校验 MD5
    final actual = await computeContentHash(partPath);
    if (actual != contentHash) {
      partFile.deleteSync();
      return Response(422, body: 'hash mismatch');
    }

    // 原子落盘：去重文件名后 rename
    final ext = formatName == 'pdf' ? 'pdf' : 'txt';
    var finalPath = p.join(incomingDir.path, '$title.$ext');
    var n = 2;
    while (File(finalPath).existsSync()) {
      finalPath = p.join(incomingDir.path, '$title ($n).$ext');
      n++;
    }
    partFile.renameSync(finalPath);

    // 落地 Book 行（id 沿用路径哈希惯例）
    final bookId = sha1OfString(finalPath);
    db.applyBookMeta(
      book: Book(
        id: bookId,
        title: title,
        format: formatName == 'pdf' ? BookFormat.pdf : BookFormat.txt,
        filePath: finalPath,
        fileHash: bookId,
        addedAt: DateTime.now(),
        lastOpenedAt: DateTime.now(),
      ),
      contentHash: contentHash,
    );
    return Response.ok('{"ok":true}', headers: _jsonHeaders);
  }

  // ---------------- 工具 ----------------

  static const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

  /// header 值仅允许 ASCII：Base64 包装非 ASCII 标题。
  static String _headerSafe(String s) {
    if (s.codeUnits.every((c) => c >= 32 && c < 127)) return s;
    return base64Encode(utf8.encode(s));
  }

  static String _headerDecode(String s) {
    final decoded = base64TryDecode(s);
    return decoded ?? s;
  }
}

String? base64TryDecode(String s) {
  try {
    return utf8.decode(base64Decode(s));
  } catch (_) {
    return null;
  }
}

class StateException implements Exception {
  StateException(this.message);
  final String message;

  @override
  String toString() => message;
}
