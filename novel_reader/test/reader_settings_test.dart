import 'package:flutter_test/flutter_test.dart';

import 'package:novel_reader/src/data/db/app_database.dart';
import 'package:novel_reader/src/domain/reader_settings.dart';

void main() {
  test('阅读设置可保存并读回', () {
    final db = AppDatabase.openInMemory();

    // 默认值
    final defaults = db.getReaderSettings();
    expect(defaults.fontSize, 18);
    expect(defaults.theme, ReaderThemeMode.light);

    // 保存修改
    db.saveReaderSettings(const ReaderSettings(
      fontSize: 24,
      lineHeight: 2.0,
      margin: 32,
      theme: ReaderThemeMode.night,
    ));

    final loaded = db.getReaderSettings();
    expect(loaded.fontSize, 24);
    expect(loaded.lineHeight, 2.0);
    expect(loaded.margin, 32);
    expect(loaded.theme, ReaderThemeMode.night);
  });

  test('损坏的设置值回退默认', () {
    final db = AppDatabase.openInMemory();
    // 直接写入非法值模拟旧版本/损坏数据
    db.setSetting('reader.font_size', 'abc');
    db.setSetting('reader.theme', '不存在的主题');

    final loaded = db.getReaderSettings();
    expect(loaded.fontSize, 18);
    expect(loaded.theme, ReaderThemeMode.light);
  });
}
