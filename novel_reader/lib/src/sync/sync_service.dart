import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:novel_reader/src/data/db/app_database.dart';
import 'package:novel_reader/src/domain/book.dart';
import 'package:novel_reader/src/sync/discovery.dart';
import 'package:novel_reader/src/sync/sync_client.dart';
import 'package:novel_reader/src/sync/sync_merger.dart';
import 'package:novel_reader/src/sync/sync_models.dart';
import 'package:novel_reader/src/sync/sync_server.dart';
import 'package:novel_reader/src/utils/hash.dart';

/// 同步编排：一次 syncWith = 拉清单 → 计划 → 推记录 → 传文件 → 落地。
/// 通过 [syncWith] 返回的事件流驱动 UI 进度。
class SyncService {
  SyncService({required this.db, required this.incomingDir})
      : merger = SyncMerger(db);

  static const _deviceIdKey = 'sync.deviceId';
  static const _deviceNameKey = 'sync.deviceName';

  /// 默认 HTTP 同步端口（透传 [SyncServer.defaultPort]，供 UI 展示）。
  static const int defaultPort = SyncServer.defaultPort;

  final AppDatabase db;
  final SyncMerger merger;
  final Directory incomingDir;

  SyncServer? _server;
  DiscoveryResponder? _discovery;
  final SyncClient _client = SyncClient();

  bool get isServerRunning => _server?.isRunning ?? false;
  int? get serverPort => _server?.port;

  /// 稳定设备 id（首次生成后持久化）。
  String deviceId() {
    var id = db.getSetting(_deviceIdKey);
    if (id == null) {
      id = sha1OfString(
        '${DateTime.now().millisecondsSinceEpoch}-'
        '${Platform.operatingSystem}-${Platform.localHostname}',
      ).substring(0, 12);
      db.setSetting(_deviceIdKey, id);
    }
    return id;
  }

  /// 设备显示名（可被用户覆盖，默认 平台-主机名）。
  String deviceName() {
    var name = db.getSetting(_deviceNameKey);
    if (name == null) {
      final os = Platform.operatingSystem;
      final host = Platform.localHostname;
      name = host.isEmpty ? os : '$os-$host';
      db.setSetting(_deviceNameKey, name);
    }
    return name;
  }

  Future<void> setDeviceName(String name) async {
    db.setSetting(_deviceNameKey, name);
    // 重启服务端让 /api/info 返回新名字
    if (_server != null) {
      final port = _server!.port;
      await stopServer();
      await startServer(port: port ?? SyncServer.defaultPort);
    }
  }

  /// 启动本端服务端（供对端连接），同时启动 UDP 发现应答。
  Future<int> startServer({int port = SyncServer.defaultPort}) async {
    await stopServer();
    _server = SyncServer(
      db: db,
      merger: merger,
      incomingDir: incomingDir,
      deviceId: deviceId(),
      deviceName: deviceName(),
    );
    final actualPort = await _server!.start(port: port);
    _discovery = DiscoveryResponder(
      deviceId: deviceId(),
      deviceName: deviceName(),
      httpPort: actualPort,
    );
    try {
      await _discovery!.start();
    } catch (_) {
      // UDP 端口被占用（如本机双开）：服务端仍可用，仅自动发现失效
    }
    return actualPort;
  }

  Future<void> stopServer() async {
    await _discovery?.stop();
    _discovery = null;
    await _server?.stop();
    _server = null;
  }

  /// 扫描局域网内开启了同步服务的设备。
  Future<List<DiscoveryPeer>> discoverPeers() {
    return DiscoveryClient().scan(selfId: deviceId());
  }

  /// 与对端执行一次完整同步。事件经 [onEvent] 上报（含文件传输进度回调），
  /// 完成后返回汇总；出错抛出 [SyncNetworkException] 等。
  Future<SyncResult> syncWith(
    String host,
    int port, {
    void Function(SyncEvent event)? onEvent,
  }) async {
    void emit(SyncEvent e) => onEvent?.call(e);

    emit(const SyncEvent.status('连接对端…'));
    final info = await _client.fetchInfo(host, port);
    final peerName = (info['deviceName'] as String?) ?? host;
    emit(SyncEvent.status('已连接：$peerName'));

    // 时钟偏差检测（>5 分钟警告，LWW 依赖时钟大致同步）
    final serverTime = (info['serverTime'] as num?)?.toInt() ?? 0;
    final skew = (DateTime.now().millisecondsSinceEpoch - serverTime).abs();
    if (serverTime > 0 && skew > const Duration(minutes: 5).inMilliseconds) {
      emit(SyncEvent.clockSkewWarning(Duration(milliseconds: skew), peerName));
    }

    emit(const SyncEvent.status('计算本地图书指纹…'));
    await merger.backfillContentHash(
      onProgress: (done, total) =>
          emit(SyncEvent.status('计算图书指纹 $done/$total')),
    );

    emit(const SyncEvent.status('获取对端清单…'));
    final remoteManifest = await _client.fetchManifest(host, port);
    final localManifest = merger.exportManifest();
    final plan = SyncMerger.planMerge(localManifest, remoteManifest);
    emit(SyncEvent.status(
      '比对完成：上传 ${plan.filesToUpload.length} 本 / '
      '下载 ${plan.filesToDownload.length} 本 / '
      '记录 ${plan.recordCount} 条',
    ));

    // 1. 推送较新记录
    if (plan.recordCount > 0) {
      emit(const SyncEvent.status('推送较新记录…'));
      await _client.pushRecords(host, port, SyncMerger.toRecordSet(plan));
    }

    // 2. 上传对端缺失的书
    for (var i = 0; i < plan.filesToUpload.length; i++) {
      final entry = plan.filesToUpload[i];
      final local = db.getBookByContentHash(entry.contentHash);
      if (local == null) continue;
      FileTransferProgress progressOf(int sent, int? total) =>
          FileTransferProgress(
            direction: TransferDirection.upload,
            title: entry.title,
            sent: sent,
            total: total,
            index: i + 1,
            count: plan.filesToUpload.length,
          );
      emit(SyncEvent.fileTransfer(progressOf(0, entry.size)));
      await _client.uploadFile(
        host,
        port,
        filePath: local.filePath,
        title: entry.title,
        format: entry.format.name,
        contentHash: entry.contentHash,
        onProgress: (sent, total) =>
            emit(SyncEvent.fileTransfer(progressOf(sent, total))),
      );
    }

    // 3. 下载本端缺失的书
    final downloaded = <(BookEntry, String)>[];
    if (!incomingDir.existsSync()) incomingDir.createSync(recursive: true);
    for (var i = 0; i < plan.filesToDownload.length; i++) {
      final entry = plan.filesToDownload[i];
      final ext = entry.format == BookFormat.pdf ? 'pdf' : 'txt';
      final safeTitle = _safeFileName(entry.title);
      var dest = p.join(incomingDir.path, '$safeTitle.$ext');
      var n = 2;
      while (File(dest).existsSync()) {
        dest = p.join(incomingDir.path, '$safeTitle ($n).$ext');
        n++;
      }
      FileTransferProgress progressOf(int sent, int? total) =>
          FileTransferProgress(
            direction: TransferDirection.download,
            title: entry.title,
            sent: sent,
            total: total,
            index: i + 1,
            count: plan.filesToDownload.length,
          );
      emit(SyncEvent.fileTransfer(progressOf(0, entry.size)));
      await _client.downloadFile(
        host,
        port,
        entry.contentHash,
        dest,
        onProgress: (received, total) =>
            emit(SyncEvent.fileTransfer(progressOf(received, total))),
      );
      downloaded.add((entry, dest));
    }

    // 4. 远端较新记录落地（含新书）
    if (plan.progressToApply.isNotEmpty ||
        plan.bookmarksToApply.isNotEmpty ||
        downloaded.isNotEmpty) {
      emit(const SyncEvent.status('应用对端数据…'));
      merger.applyRemoteRecords(plan, downloadedBooks: downloaded);
    }

    final result = SyncResult(
      booksUploaded: plan.filesToUpload.length,
      booksDownloaded: downloaded.length,
      progressApplied: plan.progressToApply.length,
      bookmarksApplied: plan.bookmarksToApply.length,
      progressPushed: plan.progressToPush.length,
      bookmarksPushed: plan.bookmarksToPush.length,
      peerName: peerName,
    );
    emit(SyncEvent.done(result));
    return result;
  }

  /// 文件名去除路径分隔符等危险字符。
  static String _safeFileName(String name) {
    return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  }

  void dispose() {
    _client.close();
    _discovery?.stop();
    _discovery = null;
    _server?.stop();
    _server = null;
  }
}

/// 一次同步过程的事件。
class SyncEvent {
  const SyncEvent.status(String this.message)
      : kind = SyncEventKind.status,
        transfer = null,
        result = null;

  SyncEvent.clockSkewWarning(Duration skew, String peer)
      : kind = SyncEventKind.clockSkew,
        message = '与 $peer 的时钟相差约 ${skew.inMinutes.abs()} 分钟，'
            '时间戳合并可能不准，建议校准设备时间后重新同步',
        transfer = null,
        result = null;

  const SyncEvent.fileTransfer(FileTransferProgress this.transfer)
      : kind = SyncEventKind.fileTransfer,
        message = null,
        result = null;

  const SyncEvent.done(SyncResult this.result)
      : kind = SyncEventKind.done,
        message = null,
        transfer = null;

  final SyncEventKind kind;
  final String? message;
  final FileTransferProgress? transfer;
  final SyncResult? result;
}

enum SyncEventKind { status, clockSkew, fileTransfer, done }

class FileTransferProgress {
  const FileTransferProgress({
    required this.direction,
    required this.title,
    required this.sent,
    required this.total,
    required this.index,
    required this.count,
  });

  final TransferDirection direction;
  final String title;
  final int sent;
  final int? total;
  final int index;
  final int count;

  double? get fraction =>
      total == null || total == 0 ? null : sent / total!;
}

enum TransferDirection { upload, download }

class SyncResult {
  const SyncResult({
    required this.booksUploaded,
    required this.booksDownloaded,
    required this.progressApplied,
    required this.bookmarksApplied,
    required this.progressPushed,
    required this.bookmarksPushed,
    required this.peerName,
  });

  final int booksUploaded;
  final int booksDownloaded;
  final int progressApplied;
  final int bookmarksApplied;
  final int progressPushed;
  final int bookmarksPushed;
  final String peerName;
}
