import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../core/models/category.dart';
import '../core/models/track.dart';
import '../data/track_repository.dart';
import 'ai_scan_screen.dart';
import 'common.dart';
import 'track_ai_sheet.dart';

class CategoriesScreen extends StatelessWidget {
  const CategoriesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Categories'),
        actions: [
          IconButton(
            tooltip: 'AI library manager',
            icon: const Icon(Icons.insights_rounded),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AiScanScreen())),
          ),
        ],
      ),
      body: Reloading<(List<AiCategory>, Map<String, int>)>(
        load: () async => (await s.categories.all(), await s.tracks.categoryCounts()),
        builder: (context, d) {
          final (cats, counts) = d;
          final enabled = cats.where((c) => c.enabled).toList();
          final ready = s.classifier.status.isReady;
          final modelLabels = {for (final l in s.classifier.status.manifest?.labels ?? const []) l.categoryId};
          return CustomScrollView(slivers: [
            if (!ready)
              SliverToBoxAdapter(
                child: Card(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: ListTile(
                    leading: const Icon(Icons.info_outline_rounded),
                    title: const Text('AI classification is unavailable'),
                    subtitle: Text(s.classifier.status.reason ?? 'The model has not been loaded yet.'),
                  ),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 220,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.35,
                ),
                itemCount: enabled.length,
                itemBuilder: (_, i) {
                  final c = enabled[i];
                  final v = CategoryVisual.of(c.id);
                  final workflow = c.id == CategoryIds.needsReview || c.id == CategoryIds.other;
                  final supported = !ready || workflow || modelLabels.contains(c.id);
                  return InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => CategoryDetailScreen(category: c))),
                    child: Ink(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        gradient: LinearGradient(
                          colors: [v.color.withValues(alpha: 0.42), v.color.withValues(alpha: 0.12)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Icon(v.icon, color: Colors.white),
                          const Spacer(),
                          Text('${counts[c.id] ?? 0}',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 20)),
                        ]),
                        const Spacer(),
                        Text(c.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                        Text(
                          supported ? c.description : 'Not in the bundled model',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      ]),
                    ),
                  );
                },
              ),
            ),
          ]);
        },
      ),
    );
  }
}

class CategoryDetailScreen extends StatefulWidget {
  const CategoryDetailScreen({super.key, required this.category});

  final AiCategory category;

  @override
  State<CategoryDetailScreen> createState() => _CategoryDetailScreenState();
}

class _CategoryDetailScreenState extends State<CategoryDetailScreen> {
  bool _provisionalOnly = false;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final v = CategoryVisual.of(widget.category.id);
    return Scaffold(
      appBar: AppBar(title: Text(widget.category.name)),
      body: Reloading<(List<Track>, Map<int, List<CategoryMembership>>, Map<String, String>)>(
        deps: [_provisionalOnly],
        load: () async {
          final tracks = await s.tracks.all(categoryId: widget.category.id, sort: TrackSort.title);
          final members = await s.tracks.memberships(trackIds: [for (final t in tracks) t.id]);
          final filtered = _provisionalOnly
              ? tracks
                  .where((t) => (members[t.id] ?? const [])
                      .any((m) => m.categoryId == widget.category.id && m.tier == AssignmentTier.provisional))
                  .toList()
              : tracks;
          return (filtered, members, await categoryNames(s));
        },
        builder: (context, d) {
          final (tracks, members, names) = d;
          return ListView(children: [
            Container(
              margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                gradient: LinearGradient(colors: [v.color.withValues(alpha: 0.5), v.color.withValues(alpha: 0.1)]),
              ),
              child: Row(children: [
                Icon(v.icon, size: 40, color: Colors.white),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${tracks.length} tracks',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 18)),
                    Text('Automatic virtual playlist · files are not moved',
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 12)),
                  ]),
                ),
                IconButton.filled(
                  onPressed: tracks.isEmpty ? null : () => s.player.playTracks(tracks),
                  icon: const Icon(Icons.play_arrow_rounded),
                ),
                IconButton(
                  onPressed: tracks.isEmpty ? null : () => s.player.playTracks(tracks, shuffle: true),
                  icon: const Icon(Icons.shuffle_rounded, color: Colors.white),
                ),
              ]),
            ),
            if (!widget.category.isNeedsReview)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FilterChip(
                    label: const Text('Provisional only'),
                    selected: _provisionalOnly,
                    onSelected: (x) => setState(() => _provisionalOnly = x),
                  ),
                ),
              ),
            if (tracks.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 48),
                child: EmptyState(icon: Icons.inbox_rounded, title: 'No tracks in this category'),
              ),
            for (final (i, t) in tracks.indexed)
              TrackTile(
                track: t,
                memberships: members[t.id] ?? const [],
                categoryNames: names,
                onTap: () => s.player.playTracks(tracks, start: i),
                trailing: IconButton(
                  tooltip: 'Review classification',
                  icon: const Icon(Icons.fact_check_outlined),
                  onPressed: () => showTrackAiSheet(context, t.id),
                ),
              ),
          ]);
        },
      ),
    );
  }
}
