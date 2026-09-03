import 'package:flutter/material.dart';
import 'package:novel_reader/src/data/db/app_database.dart';
import 'package:novel_reader/src/presentation/bookmarks/bookmark_center_page.dart';
import 'package:novel_reader/src/presentation/files/files_page.dart';
import 'package:novel_reader/src/presentation/library/library_page.dart';
import 'package:novel_reader/src/presentation/reader/reader_page.dart';
import 'package:novel_reader/src/presentation/search/search_page.dart';
import 'package:novel_reader/src/presentation/sync/sync_page.dart';

class NovelReaderApp extends StatelessWidget {
  const NovelReaderApp({super.key, required this.db});

  final AppDatabase db;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Novel Reader',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1D4ED8)),
        useMaterial3: true,
      ),
      routes: {
        '/': (_) => LibraryPage(db: db),
        '/files': (_) => FilesPage(db: db),
        SearchRoute.name: (_) => GlobalSearchPage(db: db),
        BookmarkCenterRoute.name: (_) => BookmarkCenterPage(db: db),
        '/sync': (_) => SyncPage(db: db),
      },
      onGenerateRoute: (settings) {
        if (settings.name == ReaderRoute.name) {
          final args = settings.arguments;
          if (args is ReaderRouteArgs) {
            return MaterialPageRoute(
              builder: (_) => ReaderPage(db: db, args: args),
              settings: settings,
            );
          }
          return MaterialPageRoute(
            builder: (_) => const Scaffold(
              body: Center(child: Text('Invalid route arguments')),
            ),
            settings: settings,
          );
        }
        return null;
      },
    );
  }
}

