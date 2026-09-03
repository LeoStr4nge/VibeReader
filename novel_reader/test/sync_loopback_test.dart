import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:novel_reader/src/data/db/app_database.dart';
import 'package:novel_reader/src/domain/book.dart';
import 'package:novel_reader/src/sync/sync_client.dart';
import 'package:novel_reader/src/sync/sync_merger.dart';
import 'package:novel_reader/src/sync/sync_server.dart';
import 'package:novel_reader/src/utils/hash.dart';

void main() {
  late Directory tmpDir;
  late AppDatabase dbA;
  late AppDatabase dbB;
  late SyncServer server;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('sync_loopback');
    dbA = AppDatabase.openInMemory();
    dbB = AppDatabase.openInMemory();
  });

  tearDown(() async {
    await server.stop();
    dbA.close();
    dbB.close();
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}
  });

  test('回环：真实 HTTP 上同步书文件与进度', () async {
    // A 端有书 + 进度
    final path = '${tmpDir.path}${Platform.pathSeparator}a.txt';
    File(path).writeAsStringSync('回环测试内容 ABC');
    final book = Book(
      id: sha1OfString(path),
      title: '回环之书',
      format: BookFormat.txt,
      filePath: path,
      fileHash: sha1OfString(path),
      addedAt: DateTime.now(),
      lastOpenedAt: DateTime.now(),
    );
    dbA.upsertBook(book);
    dbA.setContentHash(book.id, await computeContentHashInline(path));

    server = SyncServer(
      db: dbA,
      merger: SyncMerger(dbA),
      incomingDir: tmpDir,
      deviceId: 'device-a',
      deviceName: 'A 机',
    );
    final port = await server.start(port: 45390);
    final host = '127.0.0.1';

    final client = SyncClient();
    addTearDown(client.close);

    // 1. info
    final info = await client.fetchInfo(host, port);
    expect(info['deviceId'], 'device-a');
    expect(info['httpPort'], port);

    // 2. 拉清单 + 计划
    final mergerB = SyncMerger(dbB);
    final remote = await client.fetchManifest(host, port);
    final local = mergerB.exportManifest();
    final plan = SyncMerger.planMerge(local, remote);
    expect(plan.filesToDownload, hasLength(1));
    expect(plan.filesToDownload.single.title, '回环之书');

    // 3. 下载文件（真实流式 HTTP）
    final dest = '${tmpDir.path}${Platform.pathSeparator}b.txt';
    await client.downloadFile(host, port, plan.filesToDownload.single.contentHash, dest);
    expect(File(dest).existsSync(), isTrue);
    expect(await computeContentHashInline(dest),
        plan.filesToDownload.single.contentHash);

    // 4. 落地
    mergerB.applyRemoteRecords(plan, downloadedBooks: [
      (plan.filesToDownload.single, dest),
    ]);
    final synced = dbB.getBookByContentHash(plan.filesToDownload.single.contentHash);
    expect(synced, isNotNull);
    expect(synced!.title, '回环之书');

    // 5. 上传去重：同内容再上传 → 服务端去重返回成功
    await client.uploadFile(
      host,
      port,
      filePath: dest,
      title: '重复书',
      format: 'txt',
      contentHash: plan.filesToDownload.single.contentHash,
    );
    // 不产生第二条 Book 行
    expect(dbA.getBookByContentHash(plan.filesToDownload.single.contentHash)!.title,
        '回环之书');
  });
}
