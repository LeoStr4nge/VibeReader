import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import 'package:novel_reader/src/data/db/app_database.dart';
import 'package:novel_reader/src/domain/book.dart';
import 'package:novel_reader/src/presentation/reader/reader_page.dart';
import 'package:novel_reader/src/utils/book_format.dart';
import 'package:novel_reader/src/utils/hash.dart';

class FilesPage extends StatefulWidget {
  const FilesPage({super.key, required this.db});

  final AppDatabase db;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> with WidgetsBindingObserver {
  /// Android 内部存储根目录，直接浏览（配合“所有文件访问”权限）。
  static const _androidRoot = '/storage/emulated/0';

  String? _dirPath;
  bool _permissionGranted = false;
  bool _checkingPermission = true;

  bool get _isAndroid => Platform.isAndroid;

  /// 是否还能返回上级（Android 目录浏览用）。
  bool get _canGoUp =>
      _dirPath != null && p.dirname(_dirPath!) != _dirPath!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_isAndroid) {
      _dirPath = _androidRoot;
      _checkPermission();
    } else {
      _checkingPermission = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从系统“所有文件访问”设置页返回时重新检查并刷新。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _isAndroid &&
        !_permissionGranted) {
      _checkPermission();
    }
  }

  Future<void> _checkPermission() async {
    final status = await Permission.manageExternalStorage.status;
    if (!mounted) return;
    setState(() {
      _permissionGranted = status.isGranted;
      _checkingPermission = false;
    });
  }

  Future<void> _requestPermission() async {
    // Android 11+ 不弹对话框，而是跳转系统设置里的
    // “所有文件访问”开关页；授权后返回应用由 resumed 回调刷新。
    await Permission.manageExternalStorage.request();
    await _checkPermission();
  }

  void _goUp() {
    if (!_canGoUp) return;
    setState(() => _dirPath = p.dirname(_dirPath!));
  }

  Future<void> _pickDirectory() async {
    final dirPath = await getDirectoryPath();
    if (!mounted) return;
    if (dirPath == null) return;
    setState(() {
      _dirPath = dirPath;
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Android 目录浏览时：有上级目录则返回键先上翻，到根才退出页面。
      canPop: !_canGoUp,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goUp();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isAndroid
              ? (_dirPath == _androidRoot || _dirPath == null
                  ? '内部存储'
                  : p.basename(_dirPath!))
              : '文件'),
          leading: _canGoUp
              ? IconButton(
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: _goUp,
                  tooltip: '返回上级',
                )
              : null,
          actions: [
            // 一键导入当前文件夹内的所有书籍（不含子文件夹）
            if (_dirPath != null)
              IconButton(
                onPressed: _importAllInFolder,
                icon: const Icon(Icons.library_add),
                tooltip: '导入本文件夹全部书籍',
              ),
            // Windows 保持原有目录选择器
            if (!_isAndroid)
              IconButton(
                onPressed: _pickDirectory,
                icon: const Icon(Icons.drive_folder_upload),
              ),
          ],
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isAndroid && _checkingPermission) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_isAndroid && !_permissionGranted) {
      return _buildPermissionGate();
    }
    return _dirPath == null ? _buildEmpty() : _buildDirectory(_dirPath!);
  }

  Widget _buildEmpty() {
    return Center(
      child: FilledButton.tonal(
        onPressed: _pickDirectory,
        child: const Text('选择文件夹'),
      ),
    );
  }

  /// Android 未授权“所有文件访问”时的引导界面。
  Widget _buildPermissionGate() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder_shared, size: 64),
            const SizedBox(height: 16),
            const Text(
              '需要“所有文件访问”权限',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              '用于直接浏览手机存储中的小说文件（txt / pdf）',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _requestPermission,
              child: const Text('授予权限'),
            ),
            TextButton(
              onPressed: openAppSettings,
              child: const Text('打开应用设置'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDirectory(String dirPath) {
    final dir = Directory(dirPath);
    List<FileSystemEntity> entities;
    try {
      entities = dir.listSync();
    } catch (_) {
      return Center(child: Text('无法读取：$dirPath'));
    }

    final children = entities.where((e) {
      if (e is Directory) return true;
      if (e is File) {
        final format = bookFormatFromPath(e.path);
        return format == BookFormat.txt || format == BookFormat.pdf;
      }
      return false;
    }).toList()
      ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));

    return Scrollbar(
      interactive: true,
      child: ListView.separated(
      itemCount: children.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entity = children[index];
        final name = p.basename(entity.path);
        if (entity is Directory) {
          return ListTile(
            leading: const Icon(Icons.folder),
            title: Text(name),
            onTap: () {
              setState(() {
                _dirPath = entity.path;
              });
            },
          );
        }

        final format = bookFormatFromPath(entity.path);
        return ListTile(
          leading: const Icon(Icons.description),
          title: Text(name),
          subtitle: Text(entity.path),
          trailing: Text(_formatLabel(format)),
          onTap: () => _openBook(entity.path, format),
        );
      },
      ),
    );
  }

  String _formatLabel(BookFormat format) {
    switch (format) {
      case BookFormat.txt:
        return 'TXT';
      case BookFormat.pdf:
        return 'PDF';
      case BookFormat.unknown:
        return '未知';
    }
  }

  Book _makeBook(String filePath, BookFormat format) {
    final now = DateTime.now();
    final id = sha1OfString(filePath);
    return Book(
      id: id,
      title: p.basenameWithoutExtension(filePath),
      format: format,
      filePath: filePath,
      fileHash: id,
      addedAt: now,
      lastOpenedAt: now,
    );
  }

  /// 把当前文件夹内的所有书籍文件（txt/pdf，不含子文件夹）加入书架。
  Future<void> _importAllInFolder() async {
    final dirPath = _dirPath;
    if (dirPath == null) return;

    final files = Directory(dirPath).listSync().whereType<File>().where((f) {
      final format = bookFormatFromPath(f.path);
      return format == BookFormat.txt || format == BookFormat.pdf;
    }).toList();

    if (files.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('本文件夹内没有 txt / pdf 书籍')),
        );
      }
      return;
    }

    // 逐本入库；数量多时避免卡 UI，放到微任务间隙让出主线程。
    for (final f in files) {
      widget.db.upsertBook(_makeBook(f.path, bookFormatFromPath(f.path)));
      await Future<void>.delayed(Duration.zero);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已将 ${files.length} 本书加入书架')),
      );
    }
  }

  void _openBook(String filePath, BookFormat format) {
    final book = _makeBook(filePath, format);
    widget.db.upsertBook(book);

    Navigator.of(context).pushNamed(
      ReaderRoute.name,
      arguments: ReaderRouteArgs(
        bookId: book.id,
        filePath: filePath,
        format: format,
      ),
    );
  }
}
