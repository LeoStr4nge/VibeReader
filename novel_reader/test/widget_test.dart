import 'package:flutter_test/flutter_test.dart';

import 'package:novel_reader/src/app.dart';
import 'package:novel_reader/src/data/db/app_database.dart';

void main() {
  testWidgets('App 启动后展示书架页', (WidgetTester tester) async {
    final db = AppDatabase.openInMemory();
    await tester.pumpWidget(NovelReaderApp(db: db));
    await tester.pumpAndSettle();

    // 空书架应显示“暂无最近阅读”占位
    expect(find.text('暂无最近阅读'), findsOneWidget);
  });
}
