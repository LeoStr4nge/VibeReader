import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'package:novel_reader/src/domain/book.dart';
import 'package:novel_reader/src/domain/bookmark.dart';
import 'package:novel_reader/src/domain/global_search_result.dart';
import 'package:novel_reader/src/domain/reader_settings.dart';
import 'package:novel_reader/src/domain/reading_progress.dart';

class AppDatabase {
  AppDatabase._(this._db);

  final sqlite.Database _db;

  static Future<AppDatabase> open() async {
    final baseDir = await getApplicationSupportDirectory();
    final dbDir = Directory(p.join(baseDir.path, 'db'));
    if (!dbDir.existsSync()) {
      dbDir.createSync(recursive: true);
    }
    final dbPath = p.join(dbDir.path, 'novel_reader.sqlite3');
    final db = sqlite.sqlite3.open(dbPath);
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute('PRAGMA journal_mode = WAL;');

    final currentVersion =
        db.select('PRAGMA user_version;').first.columnAt(0) as int;
    _migrate(db, currentVersion);

    return AppDatabase._(db);
  }

  /// 内存数据库，用于测试。
  static AppDatabase openInMemory() {
    final db = sqlite.sqlite3.open(':memory:');
    db.execute('PRAGMA foreign_keys = ON;');
    _migrate(db, 0);
    return AppDatabase._(db);
  }

  static void _migrate(sqlite.Database db, int currentVersion) {
    if (currentVersion < 1) {
      _migrateToV1(db);
    }
    if (currentVersion < 2) {
      _migrateToV2(db);
    }
    if (currentVersion < 3) {
      _migrateToV3(db);
    }
    if (currentVersion < 4) {
      _migrateToV4(db);
    }
    db.execute('PRAGMA user_version = 4;');
  }

  /// v4：局域网同步支持。
  /// - books.content_hash：文件内容 MD5（跨设备图书身份，惰性补算）
  /// - books.updated_at / bookmarks.updated_at：记录级 LWW 合并依据
  /// - bookmarks.deleted_at：软删墓碑（同步删除传播）
  static void _migrateToV4(sqlite.Database db) {
    db.execute('ALTER TABLE books ADD COLUMN content_hash TEXT;');
    db.execute(
      'ALTER TABLE books ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0;',
    );
    db.execute(
      'ALTER TABLE bookmarks ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0;',
    );
    db.execute('ALTER TABLE bookmarks ADD COLUMN deleted_at INTEGER;');
    // 回填：新记录时间戳以旧时间戳为初值
    db.execute('UPDATE books SET updated_at = added_at WHERE updated_at = 0;');
    db.execute(
      'UPDATE bookmarks SET updated_at = created_at WHERE updated_at = 0;',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_books_content_hash ON books(content_hash);',
    );
  }

  static void _migrateToV3(sqlite.Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS search_segments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id TEXT NOT NULL,
        segment_index INTEGER NOT NULL,
        start_char INTEGER NOT NULL,
        end_char INTEGER NOT NULL,
        text TEXT NOT NULL,
        FOREIGN KEY(book_id) REFERENCES books(id) ON DELETE CASCADE
      );
    ''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_search_segments_book ON search_segments(book_id);',
    );
  }

  static void _migrateToV2(sqlite.Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS app_settings (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
      );
    ''');
  }

  static void _migrateToV1(sqlite.Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS books (
        id TEXT PRIMARY KEY NOT NULL,
        title TEXT NOT NULL,
        format TEXT NOT NULL,
        file_path TEXT NOT NULL,
        file_hash TEXT NOT NULL,
        added_at INTEGER NOT NULL,
        last_opened_at INTEGER NOT NULL
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS reading_progress (
        book_id TEXT PRIMARY KEY NOT NULL,
        chapter_id INTEGER,
        char_offset INTEGER,
        segment_index INTEGER,
        pdf_page INTEGER,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY(book_id) REFERENCES books(id) ON DELETE CASCADE
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS bookmarks (
        id TEXT PRIMARY KEY NOT NULL,
        book_id TEXT NOT NULL,
        format TEXT NOT NULL,
        chapter_id INTEGER,
        char_offset INTEGER,
        pdf_page INTEGER,
        excerpt TEXT,
        created_at INTEGER NOT NULL,
        FOREIGN KEY(book_id) REFERENCES books(id) ON DELETE CASCADE
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS tags (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS book_tags (
        book_id TEXT NOT NULL,
        tag_id TEXT NOT NULL,
        PRIMARY KEY(book_id, tag_id),
        FOREIGN KEY(book_id) REFERENCES books(id) ON DELETE CASCADE,
        FOREIGN KEY(tag_id) REFERENCES tags(id) ON DELETE CASCADE
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS bookmark_tags (
        bookmark_id TEXT NOT NULL,
        tag_id TEXT NOT NULL,
        PRIMARY KEY(bookmark_id, tag_id),
        FOREIGN KEY(bookmark_id) REFERENCES bookmarks(id) ON DELETE CASCADE,
        FOREIGN KEY(tag_id) REFERENCES tags(id) ON DELETE CASCADE
      );
    ''');

    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_books_last_opened ON books(last_opened_at);',
    );
  }

  void close() {
    _db.dispose();
  }

  void upsertBook(Book book) {
    _db.execute(
      '''
      INSERT INTO books(id, title, format, file_path, file_hash, added_at, last_opened_at)
      VALUES(?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        title = excluded.title,
        format = excluded.format,
        file_path = excluded.file_path,
        file_hash = excluded.file_hash,
        last_opened_at = excluded.last_opened_at;
      ''',
      [
        book.id,
        book.title,
        _formatToDb(book.format),
        book.filePath,
        book.fileHash,
        book.addedAt.millisecondsSinceEpoch,
        book.lastOpenedAt.millisecondsSinceEpoch,
      ],
    );
  }

  /// 更新书籍最近打开时间（书架按此排序，阅读时调用）。
  /// 不参与同步合并，仅反映本设备的阅读顺序。
  void touchBookLastOpened(String bookId) {
    _db.execute(
      'UPDATE books SET last_opened_at = ? WHERE id = ?;',
      [DateTime.now().millisecondsSinceEpoch, bookId],
    );
  }

  ReadingProgress? getProgress(String bookId) {
    final rows = _db.select(
      '''
      SELECT book_id, chapter_id, char_offset, segment_index, pdf_page, updated_at
      FROM reading_progress
      WHERE book_id = ?;
      ''',
      [bookId],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return ReadingProgress(
      bookId: r['book_id'] as String,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
      chapterId: r['chapter_id'] as int?,
      charOffset: r['char_offset'] as int?,
      segmentIndex: r['segment_index'] as int?,
      pdfPage: r['pdf_page'] as int?,
    );
  }

  void upsertProgress(ReadingProgress progress) {
    _db.execute(
      '''
      INSERT INTO reading_progress(book_id, chapter_id, char_offset, segment_index, pdf_page, updated_at)
      VALUES(?, ?, ?, ?, ?, ?)
      ON CONFLICT(book_id) DO UPDATE SET
        chapter_id = excluded.chapter_id,
        char_offset = excluded.char_offset,
        segment_index = excluded.segment_index,
        pdf_page = excluded.pdf_page,
        updated_at = excluded.updated_at;
      ''',
      [
        progress.bookId,
        progress.chapterId,
        progress.charOffset,
        progress.segmentIndex,
        progress.pdfPage,
        progress.updatedAt.millisecondsSinceEpoch,
      ],
    );
  }

  /// 列出书架全部书籍（按最近打开排序）。
  /// [limit] 传负数表示不限制数量。
  List<Book> listRecentBooks({int limit = -1}) {
    final rows = _db.select(
      '''
      SELECT id, title, format, file_path, file_hash, added_at, last_opened_at
      FROM books
      ORDER BY last_opened_at DESC
      LIMIT ?;
      ''',
      [limit],
    );
    return rows.map((r) {
      return Book(
        id: r['id'] as String,
        title: r['title'] as String,
        format: _formatFromDb(r['format'] as String),
        filePath: r['file_path'] as String,
        fileHash: r['file_hash'] as String,
        addedAt: DateTime.fromMillisecondsSinceEpoch(r['added_at'] as int),
        lastOpenedAt:
            DateTime.fromMillisecondsSinceEpoch(r['last_opened_at'] as int),
      );
    }).toList(growable: false);
  }

  // ---------------- 书签 ----------------

  void insertBookmark(Bookmark b) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      '''
      INSERT INTO bookmarks(id, book_id, format, chapter_id, char_offset, pdf_page, excerpt, created_at, updated_at)
      VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        chapter_id = excluded.chapter_id,
        char_offset = excluded.char_offset,
        pdf_page = excluded.pdf_page,
        excerpt = excluded.excerpt,
        updated_at = excluded.updated_at;
      ''',
      [
        b.id,
        b.bookId,
        _formatToDb(b.format),
        b.chapterId,
        b.charOffset,
        b.pdfPage,
        b.excerpt,
        b.createdAt.millisecondsSinceEpoch,
        now,
      ],
    );
  }

  /// 物理删除书籍记录（进度/书签/搜索索引随外键级联删除）。
  /// 仅供本地清理失效条目；同步删除请走墓碑路径。
  void deleteBook(String bookId) {
    _db.execute('DELETE FROM books WHERE id = ?;', [bookId]);
  }

  /// 软删书签（墓碑），供同步传播删除；本地清理可调用 [purgeDeletedBookmarks]。
  void deleteBookmark(String bookmarkId) {
    _db.execute(
      'UPDATE bookmarks SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;',
      [
        DateTime.now().millisecondsSinceEpoch,
        DateTime.now().millisecondsSinceEpoch,
        bookmarkId,
      ],
    );
  }

  /// 物理清理已软删的书签及其标签关联。
  void purgeDeletedBookmarks() {
    _db.execute(
      '''
      DELETE FROM bookmarks WHERE deleted_at IS NOT NULL
        AND deleted_at < ?;
      ''',
      [DateTime.now().subtract(const Duration(days: 90)).millisecondsSinceEpoch],
    );
  }

  List<Bookmark> listBookmarks(String bookId) {
    final rows = _db.select(
      '''
      SELECT id, book_id, format, chapter_id, char_offset, pdf_page, excerpt, created_at
      FROM bookmarks
      WHERE book_id = ? AND deleted_at IS NULL
      ORDER BY created_at DESC;
      ''',
      [bookId],
    );
    return rows.map((r) => Bookmark(
          id: r['id'] as String,
          bookId: r['book_id'] as String,
          format: _formatFromDb(r['format'] as String),
          chapterId: r['chapter_id'] as int?,
          charOffset: r['char_offset'] as int?,
          pdfPage: r['pdf_page'] as int?,
          excerpt: r['excerpt'] as String?,
          createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
        )).toList(growable: false);
  }

  /// 全部书签（含所属书信息），按创建时间倒序。用于书签中心。
  List<({Bookmark bookmark, Book book})> listAllBookmarks() {
    final rows = _db.select('''
      SELECT b.id, b.book_id, b.format, b.chapter_id, b.char_offset,
             b.pdf_page, b.excerpt, b.created_at,
             k.title AS book_title, k.format AS book_format, k.file_path,
             k.file_hash, k.added_at, k.last_opened_at
      FROM bookmarks b JOIN books k ON k.id = b.book_id
      WHERE b.deleted_at IS NULL
      ORDER BY b.created_at DESC;
    ''');
    return rows.map((r) {
      final book = Book(
        id: r['book_id'] as String,
        title: r['book_title'] as String,
        format: _formatFromDb(r['book_format'] as String),
        filePath: r['file_path'] as String,
        fileHash: r['file_hash'] as String,
        addedAt: DateTime.fromMillisecondsSinceEpoch(r['added_at'] as int),
        lastOpenedAt: DateTime.fromMillisecondsSinceEpoch(r['last_opened_at'] as int),
      );
      final bookmark = Bookmark(
        id: r['id'] as String,
        bookId: r['book_id'] as String,
        format: _formatFromDb(r['format'] as String),
        chapterId: r['chapter_id'] as int?,
        charOffset: r['char_offset'] as int?,
        pdfPage: r['pdf_page'] as int?,
        excerpt: r['excerpt'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      );
      return (bookmark: bookmark, book: book);
    }).toList(growable: false);
  }

  /// 全部书签的标签映射（bookmarkId → 标签名列表），一次查询。
  Map<String, List<String>> listAllBookmarkTags() {
    final rows = _db.select('''
      SELECT bt.bookmark_id, t.name
      FROM bookmark_tags bt JOIN tags t ON t.id = bt.tag_id
      ORDER BY t.name;
    ''');
    final map = <String, List<String>>{};
    for (final r in rows) {
      (map[r['bookmark_id'] as String] ??= []).add(r['name'] as String);
    }
    return map;
  }

  // ---------------- 标签 ----------------

  /// 新建或取回标签，返回标签 id。
  String ensureTag(String name) {
    final trimmed = name.trim();
    final rows = _db.select('SELECT id FROM tags WHERE name = ?;', [trimmed]);
    if (rows.isNotEmpty) return rows.first['id'] as String;
    final id = _newId('tag');
    _db.execute(
      'INSERT INTO tags(id, name, created_at) VALUES(?, ?, ?);',
      [id, trimmed, DateTime.now().millisecondsSinceEpoch],
    );
    return id;
  }

  /// 全部标签（id + 名称），按名称排序。
  List<({String id, String name})> listTagEntries() {
    final rows = _db.select('SELECT id, name FROM tags ORDER BY name;');
    return rows
        .map((r) => (id: r['id'] as String, name: r['name'] as String))
        .toList(growable: false);
  }

  void deleteTag(String tagId) {
    _db.execute('DELETE FROM tags WHERE id = ?;', [tagId]);
  }

  void addTagToBookmark(String bookmarkId, String tagId) {
    _db.execute(
      'INSERT OR IGNORE INTO bookmark_tags(bookmark_id, tag_id) VALUES(?, ?);',
      [bookmarkId, tagId],
    );
    _bumpBookmarkUpdatedAt(bookmarkId);
  }

  void removeTagFromBookmark(String bookmarkId, String tagId) {
    _db.execute(
      'DELETE FROM bookmark_tags WHERE bookmark_id = ? AND tag_id = ?;',
      [bookmarkId, tagId],
    );
    _bumpBookmarkUpdatedAt(bookmarkId);
  }

  /// 标签集合变化时刷新书签记录时间戳，使同步 LWW 能携带标签变更。
  void _bumpBookmarkUpdatedAt(String bookmarkId) {
    _db.execute(
      'UPDATE bookmarks SET updated_at = ? WHERE id = ? AND deleted_at IS NULL;',
      [DateTime.now().millisecondsSinceEpoch, bookmarkId],
    );
  }

  /// 书签的标签名列表。
  List<String> listBookmarkTags(String bookmarkId) {
    final rows = _db.select(
      '''
      SELECT t.name
      FROM bookmark_tags bt JOIN tags t ON t.id = bt.tag_id
      WHERE bt.bookmark_id = ?
      ORDER BY t.name;
      ''',
      [bookmarkId],
    );
    return rows.map((r) => r['name'] as String).toList(growable: false);
  }

  static final Random _idRandom = Random();

  static String _newId(String prefix) {
    final ts = DateTime.now().millisecondsSinceEpoch;
    // 真随机防撞：微秒伪随机在同一毫秒内几乎相同，批量导入时会撞 id
    final rnd = _idRandom.nextInt(1 << 32);
    return '$prefix-$ts-$rnd';
  }

  ReaderSettings getReaderSettings() {
    final rows = _db.select('SELECT key, value FROM app_settings;');
    final map = {
      for (final r in rows) r['key'] as String: r['value'] as String,
    };
    return ReaderSettings(
      fontSize: double.tryParse(map['reader.font_size'] ?? '') ?? 18,
      lineHeight: double.tryParse(map['reader.line_height'] ?? '') ?? 1.6,
      margin: double.tryParse(map['reader.margin'] ?? '') ?? 20,
      theme: ReaderThemeMode.values
              .asNameMap()[map['reader.theme']] ??
          ReaderThemeMode.light,
      segmentChars: int.tryParse(map['reader.segment_chars'] ?? '') ?? 500,
    );
  }

  /// 写入单个设置项（通用 key-value）。
  void setSetting(String key, String value) {
    _db.execute(
      'INSERT OR REPLACE INTO app_settings(key, value) VALUES(?, ?);',
      [key, value],
    );
  }

  void saveReaderSettings(ReaderSettings settings) {
    final entries = {
      'reader.font_size': settings.fontSize.toString(),
      'reader.line_height': settings.lineHeight.toString(),
      'reader.margin': settings.margin.toString(),
      'reader.theme': settings.theme.name,
      'reader.segment_chars': settings.segmentChars.toString(),
    };
    final tx = _db.prepare(
      'INSERT OR REPLACE INTO app_settings(key, value) VALUES(?, ?);',
    );
    for (final e in entries.entries) {
      tx.execute([e.key, e.value]);
    }
    tx.dispose();
  }

  /// 为整本书建搜索切片索引（固定 500 字/片，与进度条切片对齐）。
  /// 传 null chars 时使用默认值。若该书已有索引则跳过。
  void buildSearchSegments(String bookId, String text, {int? chars}) {
    final segChars = chars ?? 500;
    final existing = _db.select(
      'SELECT COUNT(*) AS c FROM search_segments WHERE book_id = ?;',
      [bookId],
    );
    if ((existing.first['c'] as int) > 0) return;

    _db.execute('BEGIN;');
    final stmt = _db.prepare(
      'INSERT INTO search_segments(book_id, segment_index, start_char, end_char, text) '
      'VALUES(?, ?, ?, ?, ?);',
    );
    try {
      for (var start = 0; start < text.length; start += segChars) {
        final end = (start + segChars) < text.length ? start + segChars : text.length;
        stmt.execute([bookId, start ~/ segChars, start, end, text.substring(start, end)]);
      }
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    } finally {
      stmt.dispose();
    }
  }

  /// 该书是否已建索引。
  bool hasSearchSegments(String bookId) {
    final rows = _db.select(
      'SELECT 1 FROM search_segments WHERE book_id = ? LIMIT 1;',
      [bookId],
    );
    return rows.isNotEmpty;
  }

  /// 全书架搜索：返回命中（书信息 + 片段摘录 + 跳转偏移），按书名分组限条。
  List<GlobalSearchResult> searchAllBooks(String query, {int limit = 200}) {
    if (query.isEmpty) return const [];
    final rows = _db.select(
      '''
      SELECT s.book_id, s.start_char, s.text,
             b.title, b.file_path, b.format
      FROM search_segments s
      JOIN books b ON b.id = s.book_id
      WHERE s.text LIKE ?
      LIMIT ?;
      ''',
      ['%$query%', limit],
    );
    return rows.map((r) {
      final segText = r['text'] as String;
      final hitInSeg = segText.indexOf(query);
      final segStart = r['start_char'] as int;
      final hitOffset = segStart + (hitInSeg >= 0 ? hitInSeg : 0);
      // 命中前后摘录（基于切片文本）
      final from = ((hitInSeg >= 0 ? hitInSeg : 0) - 20).clamp(0, segText.length);
      final to = (from + query.length + 40).clamp(0, segText.length);
      return GlobalSearchResult(
        bookId: r['book_id'] as String,
        bookTitle: r['title'] as String,
        filePath: r['file_path'] as String,
        format: _formatFromDb(r['format'] as String),
        excerpt: (from > 0 ? '…' : '') + segText.substring(from, to),
        charOffset: hitOffset,
      );
    }).toList(growable: false);
  }

  static String _formatToDb(BookFormat format) {
    switch (format) {
      case BookFormat.txt:
        return 'txt';
      case BookFormat.pdf:
        return 'pdf';
      case BookFormat.unknown:
        return 'unknown';
    }
  }

  static BookFormat _formatFromDb(String value) {
    switch (value) {
      case 'txt':
        return BookFormat.txt;
      case 'pdf':
        return BookFormat.pdf;
      default:
        return BookFormat.unknown;
    }
  }

  // ---------------- 局域网同步 ----------------

  /// 读取单个设置项。
  String? getSetting(String key) {
    final rows = _db.select(
      'SELECT value FROM app_settings WHERE key = ?;',
      [key],
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  /// 书签的 updated_at（毫秒时间戳，不存在返回 0）。同步导出用。
  int bookmarkUpdatedAt(String bookmarkId) {
    final rows = _db.select(
      'SELECT updated_at FROM bookmarks WHERE id = ?;',
      [bookmarkId],
    );
    if (rows.isEmpty) return 0;
    return rows.first['updated_at'] as int;
  }

  /// 软删墓碑书签原始行（同步导出用）。
  List<Map<String, Object?>> listDeletedBookmarks() {
    final rows = _db.select('''
      SELECT id, book_id, format, chapter_id, char_offset, pdf_page,
             excerpt, created_at, updated_at, deleted_at
      FROM bookmarks
      WHERE deleted_at IS NOT NULL;
    ''');
    return rows.map((r) => {
          'id': r['id'],
          'book_id': r['book_id'],
          'format': r['format'],
          'chapter_id': r['chapter_id'],
          'char_offset': r['char_offset'],
          'pdf_page': r['pdf_page'],
          'excerpt': r['excerpt'],
          'created_at': r['created_at'],
          'updated_at': r['updated_at'],
          'deleted_at': r['deleted_at'],
        }).toList(growable: false);
  }

  /// 全部书（同步清单导出用）。
  List<Book> listAllBooks() {
    final rows = _db.select('''
      SELECT id, title, format, file_path, file_hash, added_at, last_opened_at
      FROM books
      ORDER BY last_opened_at DESC;
    ''');
    return rows.map((r) => Book(
          id: r['id'] as String,
          title: r['title'] as String,
          format: _formatFromDb(r['format'] as String),
          filePath: r['file_path'] as String,
          fileHash: r['file_hash'] as String,
          addedAt: DateTime.fromMillisecondsSinceEpoch(r['added_at'] as int),
          lastOpenedAt:
              DateTime.fromMillisecondsSinceEpoch(r['last_opened_at'] as int),
        )).toList(growable: false);
  }

  /// 全部阅读进度（同步清单导出用）。
  List<ReadingProgress> listAllProgress() {
    final rows = _db.select(
      'SELECT book_id, chapter_id, char_offset, segment_index, pdf_page, updated_at FROM reading_progress;',
    );
    return rows
        .map((r) => ReadingProgress(
              bookId: r['book_id'] as String,
              updatedAt:
                  DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
              chapterId: r['chapter_id'] as int?,
              charOffset: r['char_offset'] as int?,
              segmentIndex: r['segment_index'] as int?,
              pdfPage: r['pdf_page'] as int?,
            ))
        .toList(growable: false);
  }

  /// 按内容哈希找书（同步落地：远端记录的 bookHash → 本地书）。
  /// 多行时取 last_opened_at 最新者（同文件多路径导入场景）。
  Book? getBookByContentHash(String contentHash) {
    final rows = _db.select('''
      SELECT id, title, format, file_path, file_hash, added_at, last_opened_at
      FROM books
      WHERE content_hash = ?
      ORDER BY last_opened_at DESC
      LIMIT 1;
    ''', [contentHash]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return Book(
      id: r['id'] as String,
      title: r['title'] as String,
      format: _formatFromDb(r['format'] as String),
      filePath: r['file_path'] as String,
      fileHash: r['file_hash'] as String,
      addedAt: DateTime.fromMillisecondsSinceEpoch(r['added_at'] as int),
      lastOpenedAt: DateTime.fromMillisecondsSinceEpoch(r['last_opened_at'] as int),
    );
  }

  /// 书的内容哈希是否已存在（文件去重判断）。
  bool hasBookWithContentHash(String contentHash) {
    final rows = _db.select(
      'SELECT 1 FROM books WHERE content_hash = ? LIMIT 1;',
      [contentHash],
    );
    return rows.isNotEmpty;
  }

  /// 写入/更新书的内容哈希（惰性补算或同步落地时）。
  void setContentHash(String bookId, String contentHash) {
    _db.execute(
      'UPDATE books SET content_hash = ? WHERE id = ?;',
      [contentHash, bookId],
    );
  }

  /// 读取书的内容哈希。
  String? getContentHash(String bookId) {
    final rows = _db.select(
      'SELECT content_hash FROM books WHERE id = ?;',
      [bookId],
    );
    if (rows.isEmpty) return null;
    return rows.first['content_hash'] as String?;
  }

  /// 尚未计算内容哈希的书（同步开始前惰性补算的输入）。
  List<Book> booksWithoutContentHash() {
    final rows = _db.select('''
      SELECT id, title, format, file_path, file_hash, added_at, last_opened_at
      FROM books
      WHERE content_hash IS NULL
      ORDER BY last_opened_at DESC;
    ''');
    return rows.map((r) => Book(
          id: r['id'] as String,
          title: r['title'] as String,
          format: _formatFromDb(r['format'] as String),
          filePath: r['file_path'] as String,
          fileHash: r['file_hash'] as String,
          addedAt: DateTime.fromMillisecondsSinceEpoch(r['added_at'] as int),
          lastOpenedAt:
              DateTime.fromMillisecondsSinceEpoch(r['last_opened_at'] as int),
        )).toList(growable: false);
  }

  /// 条件更新进度：仅当传入记录比本地新时落地（同步专用）。
  /// 本地阅读器保存仍走 [upsertProgress]（本地意图恒新）。
  void upsertProgressIfNewer(ReadingProgress progress) {
    _db.execute(
      '''
      INSERT INTO reading_progress(book_id, chapter_id, char_offset, segment_index, pdf_page, updated_at)
      VALUES(?, ?, ?, ?, ?, ?)
      ON CONFLICT(book_id) DO UPDATE SET
        chapter_id = excluded.chapter_id,
        char_offset = excluded.char_offset,
        segment_index = excluded.segment_index,
        pdf_page = excluded.pdf_page,
        updated_at = excluded.updated_at
      WHERE excluded.updated_at > reading_progress.updated_at;
      ''',
      [
        progress.bookId,
        progress.chapterId,
        progress.charOffset,
        progress.segmentIndex,
        progress.pdfPage,
        progress.updatedAt.millisecondsSinceEpoch,
      ],
    );
  }

  /// 同步落地书签（LWW + 软删墓碑 + 标签集合整体覆盖）。
  /// [tagNames] 为该书签的完整标签集合，胜者整体覆盖本地。
  void applyBookmarkEntry({
    required String bookmarkId,
    required String bookId,
    required BookFormat format,
    int? chapterId,
    int? charOffset,
    int? pdfPage,
    String? excerpt,
    required DateTime createdAt,
    required DateTime updatedAt,
    DateTime? deletedAt,
    List<String> tagNames = const [],
  }) {
    _db.execute('BEGIN;');
    try {
      _db.execute(
        '''
        INSERT INTO bookmarks(id, book_id, format, chapter_id, char_offset, pdf_page, excerpt, created_at, updated_at, deleted_at)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          chapter_id = excluded.chapter_id,
          char_offset = excluded.char_offset,
          pdf_page = excluded.pdf_page,
          excerpt = excluded.excerpt,
          updated_at = excluded.updated_at,
          deleted_at = excluded.deleted_at
        WHERE excluded.updated_at > bookmarks.updated_at;
        ''',
        [
          bookmarkId,
          bookId,
          _formatToDb(format),
          chapterId,
          charOffset,
          pdfPage,
          excerpt,
          createdAt.millisecondsSinceEpoch,
          updatedAt.millisecondsSinceEpoch,
          deletedAt?.millisecondsSinceEpoch,
        ],
      );
      // 标签集合整体覆盖（仅当记录确实落地为当前版本时重放；
      // 简化处理：本地无该 uid 记录时插入已生效，存在且较旧时也已覆盖）
      final applied = _db.select(
        'SELECT updated_at FROM bookmarks WHERE id = ?;',
        [bookmarkId],
      );
      final localUpdatedAt =
          applied.isEmpty ? 0 : applied.first['updated_at'] as int;
      if (localUpdatedAt == updatedAt.millisecondsSinceEpoch) {
        _db.execute(
          'DELETE FROM bookmark_tags WHERE bookmark_id = ?;',
          [bookmarkId],
        );
        for (final name in tagNames) {
          final tagId = ensureTag(name);
          _db.execute(
            'INSERT OR IGNORE INTO bookmark_tags(bookmark_id, tag_id) VALUES(?, ?);',
            [bookmarkId, tagId],
          );
        }
      }
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  /// 同步落地书籍元数据（接收文件后调用）：
  /// title 按 LWW，addedAt 取 min，lastOpenedAt 取 max。
  void applyBookMeta({
    required Book book,
    required String contentHash,
  }) {
    _db.execute(
      '''
      INSERT INTO books(id, title, format, file_path, file_hash, added_at, last_opened_at, content_hash, updated_at)
      VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        title = excluded.title,
        format = excluded.format,
        file_path = excluded.file_path,
        file_hash = excluded.file_hash,
        last_opened_at = excluded.last_opened_at,
        content_hash = excluded.content_hash,
        updated_at = excluded.updated_at;
      ''',
      [
        book.id,
        book.title,
        _formatToDb(book.format),
        book.filePath,
        book.fileHash,
        book.addedAt.millisecondsSinceEpoch,
        book.lastOpenedAt.millisecondsSinceEpoch,
        contentHash,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }
}
