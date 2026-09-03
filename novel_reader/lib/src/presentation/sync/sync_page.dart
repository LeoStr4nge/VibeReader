import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'package:novel_reader/src/data/db/app_database.dart';
import 'package:novel_reader/src/sync/discovery.dart';
import 'package:novel_reader/src/sync/sync_service.dart';

/// 局域网同步页：本端服务开关 + 自动发现 + 手动 IP + 同步进度。
class SyncPage extends StatefulWidget {
  const SyncPage({super.key, required this.db});

  final AppDatabase db;

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  SyncService? _service;
  bool _starting = false;

  // 服务端状态
  bool _serverOn = false;
  int? _serverPort;
  List<String> _localIps = [];

  // 发现
  bool _scanning = false;
  List<DiscoveryPeer> _peers = [];

  // 手动连接
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '${SyncService.defaultPort}');

  // 同步过程
  bool _syncing = false;
  final _logs = <String>[];
  FileTransferProgress? _transfer;
  SyncResult? _lastResult;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
    _refreshLocalIps();
  }

  /// 本机局域网 IPv4（排除回环，只留常见私网段）。
  Future<void> _refreshLocalIps() async {
    final ips = <String>{};
    try {
      for (final nic in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      )) {
        for (final addr in nic.addresses) {
          if (_isPrivateLan(addr.address)) ips.add(addr.address);
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _localIps = ips.toList());
  }

  static bool _isPrivateLan(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    final a = int.tryParse(parts[0]) ?? -1;
    final b = int.tryParse(parts[1]) ?? -1;
    if (a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    return false; // 排除蜂窝网卡公网/内网地址与虚拟网卡
  }

  Future<void> _init() async {
    final baseDir = await getApplicationDocumentsDirectory();
    final incoming = Directory('${baseDir.path}${Platform.pathSeparator}sync_incoming');
    setState(() {
      _service = SyncService(db: widget.db, incomingDir: incoming);
    });
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _service?.dispose();
    super.dispose();
  }

  void _log(String line) {
    setState(() {
      _logs.add(line);
      if (_logs.length > 200) _logs.removeRange(0, _logs.length - 200);
    });
  }

  // ---------------- 服务端 ----------------

  Future<void> _toggleServer() async {
    final service = _service;
    if (service == null || _starting) return;
    setState(() => _starting = true);
    try {
      if (_serverOn) {
        await service.stopServer();
        _log('本端服务已关闭');
        setState(() {
          _serverOn = false;
          _serverPort = null;
        });
      } else {
        final port = await service.startServer();
        _log('本端服务已开启（端口 $port），对端可连接本机 IP');
        setState(() {
          _serverOn = true;
          _serverPort = port;
        });
      }
    } catch (e) {
      _log('服务操作失败：$e');
    } finally {
      setState(() => _starting = false);
    }
  }

  // ---------------- 发现 ----------------

  Future<void> _scan() async {
    final service = _service;
    if (service == null || _scanning) return;
    setState(() {
      _scanning = true;
      _peers = [];
    });
    _log('扫描局域网设备…（约 2 秒）');
    try {
      final peers = await service.discoverPeers();
      setState(() => _peers = peers);
      if (peers.isEmpty) {
        _log('未发现设备。请确认对方已开启同步服务，或使用手动 IP 连接');
      } else {
        _log('发现 ${peers.length} 台设备');
      }
    } catch (e) {
      _log('扫描失败：$e');
    } finally {
      setState(() => _scanning = false);
    }
  }

  // ---------------- 同步 ----------------

  Future<void> _sync(DiscoveryPeer peer) => _syncTo(peer.address.address, peer.httpPort);

  Future<void> _syncManual() async {
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim());
    if (host.isEmpty || port == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入有效的 IP 和端口')),
      );
      return;
    }
    await _syncTo(host, port);
  }

  Future<void> _syncTo(String host, int port) async {
    final service = _service;
    if (service == null || _syncing) return;
    setState(() {
      _syncing = true;
      _error = null;
      _lastResult = null;
      _transfer = null;
    });
    _log('开始同步 → $host:$port');
    try {
      final result = await service.syncWith(host, port, onEvent: _onEvent);
      setState(() => _lastResult = result);
    } catch (e) {
      setState(() => _error = '$e');
      _log('同步失败：$e');
    } finally {
      setState(() {
        _syncing = false;
        _transfer = null;
      });
    }
  }

  void _onEvent(SyncEvent event) {
    switch (event.kind) {
      case SyncEventKind.status:
        _log(event.message ?? '');
        setState(() => _transfer = null);
      case SyncEventKind.clockSkew:
        _log('⚠ ${event.message}');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(event.message ?? '')),
          );
        }
      case SyncEventKind.fileTransfer:
        setState(() => _transfer = event.transfer);
      case SyncEventKind.done:
        final r = event.result!;
        _log(
          '同步完成：'
          '上传书 ${r.booksUploaded} / 下载书 ${r.booksDownloaded}，'
          '进度推送 ${r.progressPushed} / 应用 ${r.progressApplied}，'
          '书签推送 ${r.bookmarksPushed} / 应用 ${r.bookmarksApplied}',
        );
    }
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    if (_service == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('局域网同步'),
        actions: [
          IconButton(
            icon: const Icon(Icons.badge_outlined),
            tooltip: '修改设备名',
            onPressed: _editDeviceName,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _serverCard(),
          const SizedBox(height: 12),
          _peersCard(),
          const SizedBox(height: 12),
          _manualCard(),
          const SizedBox(height: 12),
          if (_syncing || _transfer != null || _error != null || _lastResult != null)
            _progressCard(),
          const SizedBox(height: 12),
          _logCard(),
        ],
      ),
    );
  }

  Widget _serverCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _serverOn ? '本端服务运行中（端口 $_serverPort）' : '本端服务未开启',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                _starting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Switch(value: _serverOn, onChanged: (_) => _toggleServer()),
              ],
            ),
            Text(
              '开启后，其他设备可在同一局域网内发现并连接本机。'
              '两台设备任一台开启即可（另一台作为客户端连接）。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_serverOn) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _localIps.isEmpty
                    ? const Text('未获取到本机 IP，请检查 WiFi 连接')
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final ip in _localIps)
                            Text(
                              '本机 IP：$ip（端口 $_serverPort）',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          const SizedBox(height: 4),
                          Text(
                            '在对方设备的「手动连接」中输入以上地址即可连接本机',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _peersCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('发现设备', style: Theme.of(context).textTheme.titleMedium),
                ),
                TextButton.icon(
                  onPressed: _scanning ? null : _scan,
                  icon: _scanning
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_find),
                  label: const Text('扫描'),
                ),
              ],
            ),
            if (_peers.isEmpty)
              const Text('暂未发现设备。对方开启本端服务后，点扫描即可找到。')
            else
              ..._peers.map(
                (peer) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.devices),
                  title: Text(peer.deviceName),
                  subtitle: Text('${peer.address.address}:${peer.httpPort}'),
                  trailing: FilledButton(
                    onPressed: _syncing ? null : () => _sync(peer),
                    child: const Text('同步'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _manualCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('手动连接', style: Theme.of(context).textTheme.titleMedium),
            Text(
                '自动发现失败时，可直接输入对方 IP。'
                '对方开启本端服务后，服务卡片中会显示「本机 IP」和端口',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _hostCtrl,
                    enabled: !_syncing,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'IP 地址',
                      hintText: '如 192.168.1.100',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _portCtrl,
                    enabled: !_syncing,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '端口',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _syncing ? null : _syncManual,
                  child: const Text('同步'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _progressCard() {
    final transfer = _transfer;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (transfer != null) ...[
              Text(
                '${transfer.direction == TransferDirection.upload ? '↑ 上传' : '↓ 下载'} '
                '${transfer.title}（${transfer.index}/${transfer.count}）',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: transfer.fraction,
                minHeight: 6,
              ),
              const SizedBox(height: 4),
              Text(
                '${_fmtBytes(transfer.sent)}'
                '${transfer.total != null ? ' / ${_fmtBytes(transfer.total!)}' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ] else if (_syncing) ...[
              const Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('同步进行中…'),
                ],
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '同步失败：$_error',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_lastResult != null && !_syncing)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '✓ 与 ${_lastResult!.peerName} 同步完成',
                  style: TextStyle(color: Theme.of(context).colorScheme.primary),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _logCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('同步日志', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_logs.isEmpty)
              const Text('暂无日志', style: TextStyle(color: Colors.grey))
            else
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final line in _logs.reversed)
                      Text(
                        line,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _editDeviceName() async {
    final service = _service;
    if (service == null) return;
    final ctrl = TextEditingController(text: service.deviceName());
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设备名'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '如 Leo 的手机'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty) return;
    await service.setDeviceName(name);
    _log('设备名已改为「$name」');
  }

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
  }
}
