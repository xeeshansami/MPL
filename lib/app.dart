import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_services.dart';
import 'library/library_scanner.dart';
import 'player/player_controller.dart';
import 'ui/categories_screen.dart';
import 'ui/home_screen.dart';
import 'ui/library_screen.dart';
import 'ui/now_playing.dart';
import 'ui/playlists_screen.dart';
import 'ui/settings_screen.dart';

class MplApp extends StatelessWidget {
  const MplApp({super.key, required this.services});

  final AppServices services;

  static ThemeData _theme(Brightness b) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF1DB98A), brightness: b);
    final dark = b == Brightness.dark;
    return ThemeData(
      colorScheme: dark ? scheme.copyWith(surface: const Color(0xFF0F1318)) : scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: dark ? const Color(0xFF0F1318) : null,
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        backgroundColor: dark ? const Color(0xFF151A21) : null,
        indicatorColor: scheme.primary.withValues(alpha: 0.18),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: dark ? const Color(0xFF171D25) : scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider.value(value: services),
        ChangeNotifierProvider<LibraryScanner>.value(value: services.scanner),
        ChangeNotifierProvider<PlayerController>.value(value: services.player),
      ],
      child: MaterialApp(
        title: 'MPL Organizer',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: ThemeMode.dark,
        home: const HomeShell(),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // Incremental: only new/changed files are analysed on launch.
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<AppServices>().scanner.scan());
  }

  void _go(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: [
        HomeScreen(onNavigate: _go),
        const LibraryScreen(),
        const CategoriesScreen(),
        const PlaylistsScreen(),
        const SettingsScreen(),
      ]),
      bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
        const MiniPlayer(),
        NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: _go,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Home'),
            NavigationDestination(
                icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music_rounded), label: 'Library'),
            NavigationDestination(
                icon: Icon(Icons.auto_awesome_outlined), selectedIcon: Icon(Icons.auto_awesome), label: 'AI Categories'),
            NavigationDestination(
                icon: Icon(Icons.queue_music_outlined), selectedIcon: Icon(Icons.queue_music_rounded), label: 'Playlists'),
            NavigationDestination(icon: Icon(Icons.tune_outlined), selectedIcon: Icon(Icons.tune_rounded), label: 'Settings'),
          ],
        ),
      ]),
    );
  }
}
