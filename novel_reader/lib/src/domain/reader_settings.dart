import 'dart:ui';

/// 阅读主题：浅色 / 护眼 / 深色 / 夜间。
enum ReaderThemeMode { light, sepia, dark, night }

extension ReaderThemeColors on ReaderThemeMode {
  String get label => switch (this) {
        ReaderThemeMode.light => '浅色',
        ReaderThemeMode.sepia => '护眼',
        ReaderThemeMode.dark => '深色',
        ReaderThemeMode.night => '夜间',
      };

  Color get background => switch (this) {
        ReaderThemeMode.light => const Color(0xFFFFFFFF),
        ReaderThemeMode.sepia => const Color(0xFFC7EDCC),
        ReaderThemeMode.dark => const Color(0xFF2B2B2F),
        ReaderThemeMode.night => const Color(0xFF000000),
      };

  Color get foreground => switch (this) {
        ReaderThemeMode.light => const Color(0xFF212121),
        ReaderThemeMode.sepia => const Color(0xFF2E3B30),
        ReaderThemeMode.dark => const Color(0xFFD6D6D6),
        ReaderThemeMode.night => const Color(0xFF8A9298),
      };
}

/// TXT 阅读排版设置。
class ReaderSettings {
  const ReaderSettings({
    this.fontSize = 18,
    this.lineHeight = 1.6,
    this.margin = 20,
    this.theme = ReaderThemeMode.light,
    this.segmentChars = 500,
  });

  final double fontSize;
  final double lineHeight;

  /// 水平页边距（垂直边距按其 0.8 倍计算）。
  final double margin;
  final ReaderThemeMode theme;

  /// 进度条切片字数。
  final int segmentChars;

  ReaderSettings copyWith({
    double? fontSize,
    double? lineHeight,
    double? margin,
    ReaderThemeMode? theme,
    int? segmentChars,
  }) {
    return ReaderSettings(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      margin: margin ?? this.margin,
      theme: theme ?? this.theme,
      segmentChars: segmentChars ?? this.segmentChars,
    );
  }
}
