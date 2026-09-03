/// TXT 章节自动识别（中文小说常见规则）。
class TxtChapter {
  const TxtChapter({
    required this.index,
    required this.title,
    required this.start,
    required this.end,
  });

  final int index;
  final String title;
  final int start;
  final int end;

  bool contains(int offset) => offset >= start && offset < end;
}

// 形如“第X章/卷/节/回/部…”或“序章/楔子/番外…”的标题行
// 标题部分允许含空格（如“第004章 fgo 赌场”），故用 . 而非 \S；
// 误判由外层的行长上限兜底。
final RegExp _chapterTitlePattern = RegExp(
  r'^(第[0-9０-９零一二三四五六七八九十百千万〇两]+[章节卷回部集篇话幕]|'
  r'序章|序言|楔子|引子|前言|自序|后记|尾声|终章|番外)'
  r'\s*[:：、．.\-—－]?\s*.{0,35}$',
);

/// 识别章节。返回按出现顺序排列的章节列表；识别不到时返回空列表。
List<TxtChapter> detectTxtChapters(String text) {
  // 行起始偏移 + 该行 trim 后内容
  final lines = <int, String>{}; // offset -> trimmed line
  var offset = 0;
  for (final raw in text.split('\n')) {
    final trimmed = raw.trim();
    if (trimmed.isNotEmpty) {
      lines[offset] = trimmed;
    }
    offset += raw.length + 1;
  }

  final starts = <int>[]; // 章节标题所在字符偏移
  String? firstTitle;
  for (final entry in lines.entries) {
    final line = entry.value;
    if (line.length > 40) continue; // 标题行不应过长
    if (_chapterTitlePattern.hasMatch(line)) {
      starts.add(entry.key);
      firstTitle ??= line;
    }
  }

  // 命中太少视为无目录（避免把正文的偶发匹配当成目录）
  if (starts.length < 2) return const [];

  final chapters = <TxtChapter>[];
  // 第一章之前的内容作为“开头”
  if (starts.first > 0) {
    chapters.add(TxtChapter(
      index: 0,
      title: '开头',
      start: 0,
      end: starts.first,
    ));
  }
  for (var i = 0; i < starts.length; i++) {
    final start = starts[i];
    final end = i + 1 < starts.length ? starts[i + 1] : text.length;
    final title = lines[start] ?? '第${i + 1}节';
    chapters.add(TxtChapter(
      index: chapters.length,
      title: title,
      start: start,
      end: end,
    ));
  }
  return chapters;
}
