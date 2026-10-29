import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../core/models/category.dart';
import '../core/models/track.dart';
import '../library/library_scanner.dart';
import 'common.dart';

Future<void> showTrackAiSheet(BuildContext context, int trackId) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (context, controller) => _TrackAiSheet(trackId: trackId, controller: controller),
      ),
    );

class _SheetData {
  _SheetData(this.track, this.scores, this.members, this.overrides, this.categories);

  final Track track;
  final Map<String, double> scores;
  final List<CategoryMembership> members;
  final List<CategoryMembership> overrides;
  final List<AiCategory> categories;
}

class _TrackAiSheet extends StatelessWidget {
  const _TrackAiSheet({required this.trackId, required this.controller});

  final int trackId;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return Reloading<_SheetData?>(
      load: () async {
        final t = await s.tracks.byId(trackId);
        if (t == null) return null;
        return _SheetData(
          t,
          await s.tracks.predictions(trackId),
          (await s.tracks.memberships(trackIds: [trackId]))[trackId] ?? const [],
          await s.tracks.overridesAsMemberships(trackId),
          await s.categories.all(),
        );
      },
      builder: (context, d) {
        if (d == null) return const EmptyState(icon: Icons.error_outline, title: 'Track not found');
        final names = {for (final c in d.categories) c.id: c.name};
        final manifest = s.classifier.status.manifest;
        final labelInfo = {for (final l in manifest?.labels ?? const []) l.categoryId: l};
        final evidence = d.track.evidenceJson == null
            ? const <String, Object?>{}
            : jsonDecode(d.track.evidenceJson!) as Map<String, Object?>;
        final theme = Theme.of(context);
        final hasOverrides = d.overrides.isNotEmpty;
        final staleModel = manifest != null && d.track.modelVersion != null && d.track.modelVersion != manifest.modelVersion;

        return ListView(controller: controller, padding: const EdgeInsets.fromLTRB(20, 0, 20, 32), children: [
          Row(children: [
            Artwork(track: d.track, size: 56),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(d.track.title, style: theme.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                Text(d.track.displayArtist, style: theme.textTheme.bodySmall),
              ]),
            ),
          ]),
          const SizedBox(height: 16),
          Text('Categories', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          if (d.members.isEmpty)
            Text(_statusText(d.track), style: theme.textTheme.bodyMedium)
          else
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final m in d.members)
                InputChip(
                  avatar: Icon(CategoryVisual.of(m.categoryId).icon, size: 16, color: CategoryVisual.of(m.categoryId).color),
                  label: Text('${names[m.categoryId] ?? m.categoryId}'
                      '${m.confidence == null ? '' : ' · ${(m.confidence! * 100).round()}%'}'
                      '${m.tier == AssignmentTier.provisional ? ' · provisional' : ''}'
                      '${m.tier == AssignmentTier.user ? ' · set by you' : ''}'),
                  onDeleted: m.origin == 'user' ? null : () => s.aiPlaylists.excludeCategory(trackId, m.categoryId).then((_) => s.scanner.revision.value++),
                  deleteButtonTooltipMessage: 'Not this category',
                ),
            ]),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (d.members.any((m) => m.tier == AssignmentTier.provisional || m.categoryId == CategoryIds.needsReview) &&
                d.members.any((m) => m.categoryId != CategoryIds.needsReview))
              FilledButton.tonalIcon(
                onPressed: () => s.aiPlaylists.confirmCurrent(trackId).then((_) => s.scanner.revision.value++),
                icon: const Icon(Icons.check_rounded),
                label: const Text('Confirm'),
              ),
            FilledButton.icon(
              onPressed: () => _pickCategories(context, d),
              icon: const Icon(Icons.edit_rounded),
              label: const Text('Set categories'),
            ),
            if (hasOverrides)
              OutlinedButton.icon(
                onPressed: () => s.aiPlaylists.resetOverrides(trackId).then((_) => s.scanner.revision.value++),
                icon: const Icon(Icons.restart_alt_rounded),
                label: const Text('Reset to AI'),
              ),
            OutlinedButton.icon(
              onPressed: s.classifier.status.isReady ? () => context.read<LibraryScanner>().reclassify([trackId]) : null,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Reclassify'),
            ),
          ]),
          if (hasOverrides)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Your correction takes precedence over future AI predictions until you reset it.',
                  style: theme.textTheme.bodySmall),
            ),
          const Divider(height: 32),
          Text('Model predictions', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            d.track.modelVersion == null
                ? 'Not analysed yet'
                : 'Model v${d.track.modelVersion}'
                    '${d.track.analyzedMs == null ? '' : ' · ${DateTime.fromMillisecondsSinceEpoch(d.track.analyzedMs!).toLocal().toString().substring(0, 16)}'}'
                    '${staleModel ? ' · outdated, will be re-analysed' : ''}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          if (d.scores.isEmpty)
            Text(d.track.analysisError ?? 'No scores stored.', style: theme.textTheme.bodySmall)
          else
            for (final e in d.scores.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  SizedBox(width: 120, child: Text(names[e.key] ?? e.key, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  Expanded(
                    child: ConfidenceBar(
                      value: e.value,
                      color: CategoryVisual.of(e.key).color,
                      marks: [
                        if (labelInfo[e.key] != null) labelInfo[e.key]!.provisionalThreshold,
                        if (labelInfo[e.key] != null) labelInfo[e.key]!.autoThreshold,
                      ],
                    ),
                  ),
                  SizedBox(width: 48, child: Text('${(e.value * 100).toStringAsFixed(0)}%', textAlign: TextAlign.end)),
                ]),
              ),
          if (d.scores.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Tick marks: provisional and automatic thresholds from the model evaluation.',
                  style: theme.textTheme.bodySmall),
            ),
          if (evidence.isNotEmpty) ...[
            const Divider(height: 32),
            Text('Why this decision', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Text('Audible windows: ${evidence['windows_audible']}/${evidence['windows_total']}',
                style: theme.textTheme.bodySmall),
            for (final m in (evidence['metadata'] as List? ?? const []).cast<Map<String, Object?>>())
              Text('• Metadata ${m['field']} "${m['keyword']}" → ${names[m['category']] ?? m['category']} (${m['strength']})',
                  style: theme.textTheme.bodySmall),
            for (final line in (evidence['decisions'] as List? ?? const []).cast<String>())
              Text('• $line', style: theme.textTheme.bodySmall),
          ],
          const Divider(height: 32),
          Text('Source', style: theme.textTheme.titleSmall),
          Text('${d.track.sourceType} · ${d.track.filename}\nOriginal file is never moved or modified.',
              style: theme.textTheme.bodySmall),
        ]);
      },
    );
  }

  static void _bump(BuildContext context) {
    if (context.mounted) context.read<AppServices>().scanner.revision.value++;
  }

  static String _statusText(Track t) => switch (t.analysisStatus) {
        AnalysisStatus.failed => 'Analysis failed: ${t.analysisError}',
        AnalysisStatus.awaitingModel => 'Waiting for a validated AI model',
        AnalysisStatus.done => 'Not assigned to any category',
        _ => 'Queued for analysis',
      };

  Future<void> _pickCategories(BuildContext context, _SheetData d) async {
    final s = context.read<AppServices>();
    final current = {
      for (final m in d.members)
        if (m.categoryId != CategoryIds.needsReview) m.categoryId,
    };
    final selected = await showDialog<Set<String>>(
      context: context,
      builder: (_) => _CategoryPicker(
        categories: d.categories.where(LibraryScanner.assignable).toList(),
        initial: current,
      ),
    );
    if (selected == null) return;
    await s.aiPlaylists.setUserCategories(trackId, selected);
    if (context.mounted) _bump(context);
  }
}

class _CategoryPicker extends StatefulWidget {
  const _CategoryPicker({required this.categories, required this.initial});

  final List<AiCategory> categories;
  final Set<String> initial;

  @override
  State<_CategoryPicker> createState() => _CategoryPickerState();
}

class _CategoryPickerState extends State<_CategoryPicker> {
  late final Set<String> _sel = {...widget.initial};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Set categories'),
      content: SizedBox(
        width: 360,
        child: ListView(shrinkWrap: true, children: [
          for (final c in widget.categories)
            CheckboxListTile(
              value: _sel.contains(c.id),
              secondary: Icon(CategoryVisual.of(c.id).icon, color: CategoryVisual.of(c.id).color),
              title: Text(c.name),
              onChanged: (v) => setState(() => v == true ? _sel.add(c.id) : _sel.remove(c.id)),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _sel.isEmpty ? null : () => Navigator.pop(context, _sel),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
