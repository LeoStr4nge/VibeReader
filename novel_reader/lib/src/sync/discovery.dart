import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:novel_reader/src/sync/sync_client.dart';
import 'package:novel_reader/src/sync/sync_server.dart';

/// 局域网设备发现。
/// - 服务端（[DiscoveryResponder]）：随 SyncServer 启动，应答探测包
/// - 客户端（[DiscoveryClient]）：UDP 广播探测 + TCP 子网扫描兜底，收集在线设备
///
/// UDP 协议：客户端广播 `VIBEREADER_PROBE 1`；服务端单播回 JSON：
/// `{"deviceId":..., "deviceName":..., "httpPort":...}`
///
/// Android 上接收 UDP 广播需持有 MulticastLock（见 MainActivity 平台通道），
/// 部分 ROM/路由器仍会丢弃广播，故 TCP 扫描同一 /24 子网作兜底。
class DiscoveryPeer {
  const DiscoveryPeer({
    required this.deviceId,
    required this.deviceName,
    required this.address,
    required this.httpPort,
  });

  final String deviceId;
  final String deviceName;
  final InternetAddress address;
  final int httpPort;

  static DiscoveryPeer? tryParse(String body, InternetAddress from) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final id = json['deviceId'] as String?;
      final name = json['deviceName'] as String?;
      final port = (json['httpPort'] as num?)?.toInt();
      if (id == null || name == null || port == null) return null;
      return DiscoveryPeer(
        deviceId: id,
        deviceName: name,
        address: from,
        httpPort: port,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'httpPort': httpPort,
      };

  @override
  bool operator ==(Object other) =>
      other is DiscoveryPeer && other.deviceId == deviceId;

  @override
  int get hashCode => deviceId.hashCode;
}

/// Android MulticastLock 平台通道。
const MethodChannel _multicastChannel = MethodChannel('vibereader/sync');

Future<void> acquireMulticastLock() async {
  if (!Platform.isAndroid) return;
  try {
    await _multicastChannel.invokeMethod<void>('acquireMulticastLock');
  } catch (_) {
    // 平台通道不可用（桌面端/测试环境）：忽略
  }
}

Future<void> releaseMulticastLock() async {
  if (!Platform.isAndroid) return;
  try {
    await _multicastChannel.invokeMethod<void>('releaseMulticastLock');
  } catch (_) {}
}

/// 服务端应答器：监听发现端口，回应探测。
class DiscoveryResponder {
  DiscoveryResponder({
    required this.deviceId,
    required this.deviceName,
    required this.httpPort,
  });

  static const int discoveryPort = 45232;
  static const String _probePrefix = 'VIBEREADER_PROBE';

  final String deviceId;
  final String deviceName;
  final int httpPort;

  RawDatagramSocket? _socket;

  Future<void> start() async {
    if (_socket != null) return;
    // Android：持有组播锁，否则 WiFi 驱动过滤广播包收不到探测
    await acquireMulticastLock();
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: true,
    );
    _socket = socket;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      final message = utf8.decode(datagram.data, allowMalformed: true);
      if (!message.startsWith(_probePrefix)) return;
      // 单播回复本端信息
      final reply = utf8.encode(jsonEncode(DiscoveryPeer(
        deviceId: deviceId,
        deviceName: deviceName,
        address: InternetAddress.anyIPv4,
        httpPort: httpPort,
      ).toJson()));
      socket.send(reply, datagram.address, datagram.port);
    });
  }

  Future<void> stop() async {
    _socket?.close();
    _socket = null;
    await releaseMulticastLock();
  }
}

/// 客户端扫描器：UDP 广播探测 + TCP 子网扫描兜底。
class DiscoveryClient {
  DiscoveryClient({this.timeout = const Duration(seconds: 2)});

  /// UDP 扫描窗口时长（TCP 兜底扫描另计）。
  final Duration timeout;

  /// 扫描局域网内开启了同步服务的设备（按 deviceId 去重，排除 [selfId]）。
  Future<List<DiscoveryPeer>> scan({String? selfId}) async {
    final results = await Future.wait([
      _udpScan(selfId: selfId),
      _tcpScan(selfId: selfId),
    ]);
    final merged = <String, DiscoveryPeer>{};
    for (final peer in results.expand((list) => list)) {
      if (peer.deviceId == selfId) continue;
      merged.putIfAbsent(peer.deviceId, () => peer);
    }
    return merged.values.toList(growable: false);
  }

  /// UDP 广播探测并收集应答。
  Future<List<DiscoveryPeer>> _udpScan({String? selfId}) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      0, // 临时端口
      reuseAddress: true,
    );
    final peers = <String, DiscoveryPeer>{};

    final completer = Completer<void>();
    final doneTimer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete();
    });

    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      final peer = DiscoveryPeer.tryParse(
        utf8.decode(datagram.data, allowMalformed: true),
        datagram.address,
      );
      if (peer == null || peer.deviceId == selfId) return;
      // 同一设备多网卡/多响应：保留第一个
      peers.putIfAbsent(peer.deviceId, () => peer);
    });

    try {
      final probe = utf8.encode('VIBEREADER_PROBE 1');
      // 全局广播 + 各网卡的定向广播，提升不同路由器下的命中率
      final targets = <InternetAddress>[
        InternetAddress('255.255.255.255'),
      ];
      try {
        for (final nic in await NetworkInterface.list()) {
          for (final addr in nic.addresses) {
            if (addr.type != InternetAddressType.IPv4) continue;
            final parts = addr.address.split('.');
            if (parts.length == 4) {
              targets.add(
                InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'),
              );
            }
          }
        }
      } catch (_) {
        // 枚举失败不影响全局广播
      }
      for (final target in targets) {
        try {
          socket.send(probe, target, DiscoveryResponder.discoveryPort);
        } catch (_) {
          // 某些网卡禁止广播：跳过
        }
      }

      await completer.future;
      return peers.values.toList(growable: false);
    } finally {
      await sub.cancel();
      socket.close();
      doneTimer.cancel();
    }
  }

  /// TCP 兜底：对本机各 IPv4 网卡的 /24 子网逐 IP 连接同步端口。
  /// 不依赖 UDP 广播（部分路由器/ROM 会丢弃广播包）。
  /// 注意：仅探测默认端口，服务端端口被挤占偏移的场景由 UDP 发现覆盖。
  Future<List<DiscoveryPeer>> _tcpScan({String? selfId}) async {
    final prefixes = <String>{};
    try {
      for (final nic in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      )) {
        for (final addr in nic.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4) {
            prefixes.add(parts.sublist(0, 3).join('.'));
          }
        }
      }
    } catch (_) {
      return const [];
    }
    if (prefixes.isEmpty) return const [];

    final probes = <Future<DiscoveryPeer?>>[];
    for (final prefix in prefixes) {
      for (var i = 1; i <= 254; i++) {
        probes.add(_probeHost('$prefix.$i'));
      }
    }
    final found = await Future.wait(probes);
    return [
      for (final p in found)
        if (p != null && p.deviceId != selfId) p,
    ];
  }

  Future<DiscoveryPeer?> _probeHost(String host) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        host,
        SyncServer.defaultPort,
        timeout: const Duration(milliseconds: 500),
      );
    } catch (_) {
      return null;
    } finally {
      socket?.destroy();
    }
    // 端口可达：确认为本应用同步服务并读取设备信息
    final client = SyncClient();
    try {
      final info = await client.fetchInfo(host, SyncServer.defaultPort);
      final id = info['deviceId'] as String?;
      final name = info['deviceName'] as String?;
      if (id == null || name == null) return null;
      return DiscoveryPeer(
        deviceId: id,
        deviceName: name,
        address: InternetAddress(host),
        httpPort:
            (info['httpPort'] as num?)?.toInt() ?? SyncServer.defaultPort,
      );
    } catch (_) {
      return null; // 非 VibeReader 服务
    } finally {
      client.close();
    }
  }
}
