import 'package:flutter/material.dart';

import 'package:novel_reader/src/app.dart';
import 'package:novel_reader/src/data/db/app_database.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await AppDatabase.open();
  runApp(NovelReaderApp(db: db));
}
