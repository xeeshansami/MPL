import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ai/audio_classifier.dart';
import '../app_services.dart';
import '../core/models/category.dart';
import '../core/models/track.dart';
import '../data/track_repository.dart';
import '../library/library_scanner.dart';
import 'common.dart';
import 'track_ai_sheet.dart';

enum _Filter { all, uncertain, errors, pending }

/// AI library management: progress, distribution, per-track results and
/// scan/reclassify controls.
class AiScanScreen extends StatefulWidget {
  const AiScanScreen({super.key});

  @override
  State<AiScanScreen> createState() => _AiScanScreenState();
}

class _AiData {
  _AiData(this.stats, this.counts, this.categories, this.tracks, this.members);

  final LibraryStats stats;
  final Map<String, int> counts;
  final List<AiCategory> categories;
  final List<Track> tracks;
  final Map<int, List<CategoryMembership>> members;
}

class _AiScanScreenState extends State<AiScanScreen> {
  _Filter _filter = _Filter.all;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final scanner = context.watch<LibraryScanner>();
    return Scaffold(
      appBar: AppBar(title: const Text('AI Library Manager')),
      body: Reloading<_AiData>(
        load: () async => _AiData(
          await s.tracks.stats(s.classifier.status.manifest?.modelVersion),
          await s.tracks.categoryCounts(),
          await s.categories.all(),
          await s.tracks.all(sort: TrackSort.dateAdded),
          await s.tracks.memberships(),
        ),
        builder: (context, d) {
          final names = {for (final c in d.categories) c.id: c.name};
          final rows = d.tracks.where((t) {
            final m = d.members[t.id] ?? const [];
            return switch (_filter) {
              _Filter.all => true,
              _Filter.uncertain => t.needsReview || m.any((x) => x.tier == AssignmentTier.provisional),
              _Filter.errors => t.analysisStatus == AnalysisStatus.failed,
              _Filter.pending => t.analysisStatus != AnalysisStatus.done && t.analysisStatus != AnalysisStatus.failed,
            };
          }).toList();
          return CustomScrollView(slivers: [
            SliverToBoxAdapter(child: _ModelCard(status: s.classifier.status)),
            SliverToBoxAdapter(child: _ProgressCard(scanner: scanner)),
            SliverToBoxAdapter(child: _StatsGrid(stats: d.stats, discovered: d.stats.total)),
            SliverToBoxAdapter(child: _Distribution(counts: d.counts, categories: d.categories)),
            if (scanner.errors.isNotEmpty)
              SliverToBoxAdapter(
                child: Card(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: ExpansionTile(
                    leading: const Icon(Icons.error_outline_rounded, color: Colors.redAccent),
                    title: Text('${scanner.errors.length} error(s) in the last scan'),
                    children: [
                      for (final e in scanner.errors)
                        ListTile(dense: true, title: Text(e.title), subtitle: Text(e.message)),
                    ],
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SectionHeader('Per-track results')),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SegmentedButton<_Filter>(
                  segments: const [
                    ButtonSegment(value: _Filter.all, label: Text('All')),
                    ButtonSegment(value: _Filter.uncertain, label: Text('Uncertain')),
                    ButtonSegment(value: _Filter.errors, label: Text('Errors')),
                    ButtonSegment(value: _Filter.pending, label: Text('Pending')),
                  ],
                  selected: {_filter},
                  showSelectedIcon: false,
                  onSelectionChanged: (v) => setState(() => _filter = v.first),
                ),
              ),
            ),
            SliverList.builder(
              itemCount: rows.length,
              itemBuilder: (_, i) => _ResultTile(track: rows[i], members: d.members[rows[i].id] ?? const [], names: names),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ]);
        },
      ),
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({required this.status});

  final ModelStatus status;

  @override
  Widget build(BuildContext context) {
    final m = status.manifest;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(status.isReady ? Icons.memory_rounded : Icons.warning_amber_rounded,
                color: status.isReady ? scheme.primary : Colors.amber),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                status.isReady ? '${m!.modelId} · v${m.modelVersion}' : 'No validated model',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const Chip(label: Text('Offline'), avatar: Icon(Icons.airplanemode_active_rounded, size: 16)),
          ]),
          const SizedBox(height: 8),
          if (status.isReady)
            Text(
              '${m!.labels.length} categories · ${m.sampleRate ~/ 1000} kHz mono · '
              '${m.windowSeconds.toStringAsFixed(2)} s × ${m.windowsPerTrack} windows\n'
              'Evaluated on ${m.evaluation.testFiles} held-out files (${m.evaluation.dataset}, ${m.evaluation.date}). '
              'Thresholds: ${m.evaluation.thresholdMethod}.',
              style: Theme.of(context).textTheme.bodySmall,
            )
          else
            Text(status.reason ?? 'Model not loaded yet.', style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.scanner});

  final LibraryScanner scanner;

  @override
  Widget build(BuildContext context) {
    final running = scanner.isRunning;
    final paused = scanner.phase == ScanPhase.paused;
    final progress = scanner.queueTotal == 0 ? null : scanner.processed / scanner.queueTotal;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            switch (scanner.phase) {
              ScanPhase.idle => 'Idle',
              ScanPhase.discovering => 'Discovering audio…',
              ScanPhase.readingMetadata => 'Reading metadata…',
              ScanPhase.analyzing => 'Analysing ${scanner.processed}/${scanner.queueTotal}',
              ScanPhase.paused => 'Paused at ${scanner.processed}/${scanner.queueTotal}',
              ScanPhase.completed => 'Completed',
              ScanPhase.cancelled => 'Cancelled',
              ScanPhase.error => 'Error',
            },
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (scanner.message != null) ...[
            const SizedBox(height: 4),
            Text(scanner.message!, style: Theme.of(context).textTheme.bodySmall),
          ],
          if (running) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress, borderRadius: BorderRadius.circular(4)),
            if (scanner.currentTitle != null) ...[
              const SizedBox(height: 6),
              Text(scanner.currentTitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ],
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (!running)
              FilledButton.icon(
                onPressed: scanner.scan,
                icon: const Icon(Icons.radar_rounded),
                label: const Text('Scan for new audio'),
              ),
            if (running && !paused)
              FilledButton.tonalIcon(onPressed: scanner.pause, icon: const Icon(Icons.pause_rounded), label: const Text('Pause')),
            if (paused)
              FilledButton.icon(onPressed: scanner.resume, icon: const Icon(Icons.play_arrow_rounded), label: const Text('Resume')),
            if (running)
              OutlinedButton.icon(onPressed: scanner.cancel, icon: const Icon(Icons.stop_rounded), label: const Text('Cancel')),
            if (!running)
              OutlinedButton.icon(
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('Reclassify entire library?'),
                      content: const Text(
                          'Every track is analysed again with the bundled model. Your manual corrections are kept.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Reclassify')),
                      ],
                    ),
                  );
                  if (ok == true) await scanner.reclassifyAll();
                },
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Reclassify all'),
              ),
          ]),
        ]),
      ),
    );
  }
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.stats, required this.discovered});

  final LibraryStats stats;
  final int discovered;

  @override
  Widget build(BuildContext context) {
    final items = [
      ('Discovered', discovered, Icons.library_music_rounded),
      ('Analysed', stats.analyzed, Icons.check_circle_rounded),
      ('Remaining', stats.remaining, Icons.hourglass_bottom_rounded),
      ('Organised', stats.organized, Icons.auto_awesome),
      ('Uncertain', stats.needsReview + stats.provisional, Icons.help_outline_rounded),
      ('Failed', stats.failed, Icons.error_outline_rounded),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1.25,
        children: [
          for (final (label, value, icon) in items)
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
                  const Spacer(),
                  Text('$value', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                  Text(label, style: Theme.of(context).textTheme.bodySmall),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}

class _Distribution extends StatelessWidget {
  const _Distribution({required this.counts, required this.categories});

  final Map<String, int> counts;
  final List<AiCategory> categories;

  @override
  Widget build(BuildContext context) {
    final rows = categories.where((c) => (counts[c.id] ?? 0) > 0).toList()
      ..sort((a, b) => counts[b.id]!.compareTo(counts[a.id]!));
    if (rows.isEmpty) return const SizedBox.shrink();
    final maxV = counts[rows.first.id]!;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SectionHeader('Category distribution'),
      for (final c in rows)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(children: [
            Icon(CategoryVisual.of(c.id).icon, size: 18, color: CategoryVisual.of(c.id).color),
            const SizedBox(width: 8),
            SizedBox(width: 120, child: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
            Expanded(child: ConfidenceBar(value: counts[c.id]! / maxV, color: CategoryVisual.of(c.id).color)),
            SizedBox(width: 44, child: Text('${counts[c.id]}', textAlign: TextAlign.end)),
          ]),
        ),
    ]);
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.track, required this.members, required this.names});

  final Track track;
  final List<CategoryMembership> members;
  final Map<String, String> names;

  @override
  Widget build(BuildContext context) {
    final String subtitle;
    switch (track.analysisStatus) {
      case AnalysisStatus.failed:
        subtitle = 'Failed: ${track.analysisError ?? 'unknown error'}';
      case AnalysisStatus.done:
        final assigned = members.where((m) => m.categoryId != CategoryIds.needsReview).toList();
        if (assigned.isNotEmpty) {
          subtitle = assigned
              .map((m) => '${names[m.categoryId] ?? m.categoryId}'
                  '${m.confidence == null ? '' : ' ${(m.confidence! * 100).round()}%'}'
                  '${m.tier == AssignmentTier.provisional ? ' (provisional)' : m.tier == AssignmentTier.user ? ' (you)' : ''}')
              .join(' · ');
        } else {
          subtitle = 'Needs review${_bestGuess(names)}';
        }
      case AnalysisStatus.awaitingModel:
        subtitle = 'Waiting for a validated model';
      default:
        subtitle = 'Queued for analysis';
    }
    return ListTile(
      leading: Artwork(track: track, size: 40),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => showTrackAiSheet(context, track.id),
    );
  }

  String _bestGuess(Map<String, String> names) {
    final raw = track.evidenceJson;
    if (raw == null) return '';
    final best = (jsonDecode(raw) as Map<String, Object?>)['best_guess'];
    if (best is! Map) return '';
    final id = best['category'] as String;
    return ' · best guess ${names[id] ?? id} ${((best['score'] as num) * 100).round()}%';
  }
}
