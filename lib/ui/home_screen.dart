import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ai/audio_classifier.dart';
import '../app_services.dart';
import '../core/models/category.dart';
import '../core/models/track.dart';
import '../data/track_repository.dart';
import '../library/library_scanner.dart';
import 'ai_scan_screen.dart';
import 'categories_screen.dart';
import 'common.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.onNavigate});

  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return Scaffold(
      body: SafeArea(
        child: Reloading<_HomeData>(
          load: () async => _HomeData(
            stats: await s.tracks.stats(s.classifier.status.manifest?.modelVersion),
            counts: await s.tracks.categoryCounts(),
            categories: await s.categories.all(),
            recent: await s.tracks.recentlyAdded(limit: 12),
            played: await s.tracks.recentlyPlayed(limit: 12),
          ),
          builder: (context, d) {
            if (d.stats.total == 0) {
              return ListView(children: [
                const _Header(),
                const _AiStatusCard(stats: LibraryStats()),
                const SizedBox(height: 40),
                EmptyState(
                  icon: Icons.library_music_outlined,
                  title: 'No audio yet',
                  message: 'Grant access to your music or import files. Everything is analysed on this device.',
                  action: FilledButton.icon(
                    onPressed: () => _import(context),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Import audio'),
                  ),
                ),
              ]);
            }
            final top = d.categories
                .where((c) => c.enabled && (d.counts[c.id] ?? 0) > 0)
                .toList()
              ..sort((a, b) => (d.counts[b.id] ?? 0).compareTo(d.counts[a.id] ?? 0));
            return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
              const _Header(),
              _AiStatusCard(stats: d.stats),
              if (top.isNotEmpty) ...[
                SectionHeader('Your AI playlists', action: TextButton(onPressed: () => onNavigate(2), child: const Text('All'))),
                SizedBox(
                  height: 112,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    scrollDirection: Axis.horizontal,
                    itemCount: top.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (_, i) => _CategoryCard(category: top[i], count: d.counts[top[i].id] ?? 0),
                  ),
                ),
              ],
              _TrackRow(title: 'Recently added', tracks: d.recent, onAll: () => onNavigate(1)),
              if (d.played.isNotEmpty) _TrackRow(title: 'Recently played', tracks: d.played),
            ]);
          },
        ),
      ),
    );
  }

  static Future<void> _import(BuildContext context) async {
    final s = context.read<AppServices>();
    final n = await s.importer.importFiles();
    if (n > 0) await s.scanner.scan();
  }
}

class _HomeData {
  _HomeData({required this.stats, required this.counts, required this.categories, required this.recent, required this.played});

  final LibraryStats stats;
  final Map<String, int> counts;
  final List<AiCategory> categories;
  final List<Track> recent;
  final List<Track> played;
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('MPL Organizer', style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
            Text('Offline AI music library', style: t.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
        IconButton.filledTonal(
          tooltip: 'Import audio',
          onPressed: () => HomeScreen._import(context),
          icon: const Icon(Icons.add_rounded),
        ),
      ]),
    );
  }
}

class _AiStatusCard extends StatelessWidget {
  const _AiStatusCard({required this.stats});

  final LibraryStats stats;

  @override
  Widget build(BuildContext context) {
    final scanner = context.watch<LibraryScanner>();
    final status = context.read<AppServices>().classifier.status;
    final scheme = Theme.of(context).colorScheme;
    final unavailable = status.state == ModelState.unavailable;
    final progress = scanner.queueTotal == 0 ? null : scanner.processed / scanner.queueTotal;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AiScanScreen())),
        child: Ink(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              colors: unavailable
                  ? [const Color(0xFF3A3020), const Color(0xFF2A2418)]
                  : [scheme.primary.withValues(alpha: 0.35), const Color(0xFF1B3B4B)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(unavailable ? Icons.warning_amber_rounded : Icons.auto_awesome, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  switch (status.state) {
                    ModelState.ready => 'On-device AI · model ${status.manifest!.modelVersion}',
                    ModelState.unavailable => 'AI classification unavailable',
                    _ => 'Preparing on-device AI…',
                  },
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16),
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Colors.white70),
            ]),
            const SizedBox(height: 10),
            if (unavailable)
              Text(status.reason ?? '', style: const TextStyle(color: Colors.white70, fontSize: 13), maxLines: 3, overflow: TextOverflow.ellipsis)
            else
              Wrap(spacing: 18, runSpacing: 8, children: [
                _Stat('Tracks', stats.total),
                _Stat('Organised', stats.organized),
                _Stat('Uncertain', stats.needsReview + stats.provisional),
                _Stat('Remaining', stats.remaining),
              ]),
            if (scanner.isRunning) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: progress, borderRadius: BorderRadius.circular(4)),
              const SizedBox(height: 6),
              Text(scanner.currentTitle ?? scanner.message ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ],
          ]),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$value', style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ]);
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({required this.category, required this.count});

  final AiCategory category;
  final int count;

  @override
  Widget build(BuildContext context) {
    final v = CategoryVisual.of(category.id);
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CategoryDetailScreen(category: category))),
      child: Ink(
        width: 132,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(colors: [v.color.withValues(alpha: 0.55), v.color.withValues(alpha: 0.18)],
              begin: Alignment.topLeft, end: Alignment.bottomRight),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(v.icon, color: Colors.white),
          const Spacer(),
          Text(category.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          Text('$count tracks', style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ]),
      ),
    );
  }
}

class _TrackRow extends StatelessWidget {
  const _TrackRow({required this.title, required this.tracks, this.onAll});

  final String title;
  final List<Track> tracks;
  final VoidCallback? onAll;

  @override
  Widget build(BuildContext context) {
    final player = context.read<AppServices>().player;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionHeader(title, action: onAll == null ? null : TextButton(onPressed: onAll, child: const Text('All'))),
      SizedBox(
        height: 176,
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          scrollDirection: Axis.horizontal,
          itemCount: tracks.length,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (_, i) {
            final t = tracks[i];
            return SizedBox(
              width: 124,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => player.playTracks(tracks, start: i),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Artwork(track: t, size: 124, radius: 16),
                  const SizedBox(height: 6),
                  Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(t.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ]),
              ),
            );
          },
        ),
      ),
    ]);
  }
}
