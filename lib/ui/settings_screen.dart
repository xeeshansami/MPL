import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ai/category_resolver.dart';
import '../app_services.dart';
import '../core/models/category.dart';
import '../data/catalog_repositories.dart';
import 'common.dart';
import 'now_playing.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Reloading<(ClassificationPolicy, List<AiCategory>, List<LibrarySource>, String?)>(
        load: () async => (await s.settings.policy(), await s.categories.all(), await s.settings.sources(),
            await s.settings.get('use_mediastore')),
        builder: (context, d) {
          final (policy, cats, sources, useMediaStore) = d;
          final status = s.classifier.status;
          final m = status.manifest;
          return ListView(padding: const EdgeInsets.only(bottom: 32), children: [
            const SectionHeader('On-device AI model'),
            ListTile(
              leading: Icon(status.isReady ? Icons.memory_rounded : Icons.warning_amber_rounded),
              title: Text(status.isReady ? '${m!.modelId} v${m.modelVersion}' : 'Unavailable'),
              subtitle: Text(status.isReady
                  ? 'Bundled in the app, runs fully offline. ${m!.labels.length} categories, '
                      'evaluated on ${m.evaluation.testFiles} test files.'
                  : status.reason ?? 'Not loaded yet'),
            ),
            if (m != null)
              ExpansionTile(
                leading: const Icon(Icons.analytics_outlined),
                title: const Text('Per-category evaluation'),
                subtitle: Text('Thresholds: ${m.evaluation.thresholdMethod}'),
                children: [
                  for (final l in m.labels)
                    ListTile(
                      dense: true,
                      leading: Icon(CategoryVisual.of(l.categoryId).icon, color: CategoryVisual.of(l.categoryId).color),
                      title: Text(cats.firstWhere((c) => c.id == l.categoryId).name),
                      subtitle: Text([
                        'auto ≥ ${l.autoThreshold.toStringAsFixed(2)}',
                        'provisional ≥ ${l.provisionalThreshold.toStringAsFixed(2)}',
                        for (final e in l.metrics.entries)
                          '${e.key} ${e.value is double ? (e.value as double).toStringAsFixed(3) : e.value}',
                      ].join(' · ')),
                    ),
                ],
              ),
            const SectionHeader('Classification policy'),
            ListTile(
              leading: const Icon(Icons.layers_outlined),
              title: const Text('Maximum categories per track'),
              subtitle: Text(m == null || m.multiLabel
                  ? '${policy.maxLabels} (multi-label: e.g. both Sad and Romantic)'
                  : 'The bundled model is single-label'),
              trailing: SizedBox(
                width: 140,
                child: Slider(
                  value: policy.maxLabels.toDouble(),
                  min: 1,
                  max: 5,
                  divisions: 4,
                  label: '${policy.maxLabels}',
                  onChanged: (v) => _savePolicy(context, policy.copyWith(maxLabels: v.round())),
                ),
              ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.sell_outlined),
              title: const Text('Genre tags can confirm provisional results'),
              subtitle: const Text('A matching embedded genre tag promotes a provisional AI result to automatic. '
                  'Metadata alone never assigns a category.'),
              value: policy.metadataPromotesProvisional,
              onChanged: (v) => _savePolicy(context, policy.copyWith(metadataPromotesProvisional: v)),
            ),
            const ListTile(
              dense: true,
              leading: Icon(Icons.info_outline_rounded),
              subtitle: Text('Confidence thresholds come from the model’s evaluation and are shown per category above. '
                  'Policy changes apply to the next analysis; use Reclassify all to apply them now.'),
            ),
            const SectionHeader('Categories'),
            for (final c in cats)
              SwitchListTile(
                secondary: Icon(CategoryVisual.of(c.id).icon, color: CategoryVisual.of(c.id).color),
                title: Text(c.name),
                subtitle: Text(c.keywords.isEmpty ? c.description : 'Keywords: ${c.keywords.take(6).join(', ')}…',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                value: c.enabled,
                onChanged: c.isNeedsReview
                    ? null
                    : (v) async {
                        await s.categories.update(c.copyWith(enabled: v));
                        await s.scanner.categoriesChanged();
                      },
              ).withLongPress(() => _editCategory(context, c)),
            const ListTile(
              dense: true,
              subtitle: Text('Long-press a category to rename it or edit its metadata keywords.'),
            ),
            const SectionHeader('Library sources'),
            if (Platform.isAndroid) ...[
              SwitchListTile(
                secondary: const Icon(Icons.phone_android_rounded),
                title: const Text('Device music (MediaStore)'),
                subtitle: const Text('All audio indexed by Android, excluding ringtones and short clips'),
                value: useMediaStore != 'false',
                onChanged: (v) async {
                  await s.settings.set('use_mediastore', '$v');
                  await s.scanner.scan();
                },
              ),
              for (final src in sources)
                ListTile(
                  leading: Icon(src.type == 'saf_tree' ? Icons.folder_rounded : Icons.audio_file_rounded),
                  title: Text(src.label ?? src.uri, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(src.type == 'saf_tree' ? 'Folder (Storage Access Framework)' : 'File (Storage Access Framework)'),
                  trailing: IconButton(
                    tooltip: 'Remove source (files are not deleted)',
                    icon: const Icon(Icons.link_off_rounded),
                    onPressed: () async {
                      await s.importer.removeSource(src);
                      await s.scanner.scan();
                    },
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: const Text('Add folder'),
                onTap: () async {
                  if (await s.importer.addFolder()) await s.scanner.scan();
                },
              ),
            ],
            ListTile(
              leading: const Icon(Icons.file_open_outlined),
              title: Text(Platform.isIOS ? 'Import from Files' : 'Add audio files'),
              subtitle: Text(Platform.isIOS
                  ? 'Copies are stored privately in this app; your originals are untouched'
                  : 'Referenced in place with persistent read permission'),
              onTap: () async {
                if (await s.importer.importFiles() > 0) await s.scanner.scan();
              },
            ),
            const SectionHeader('Playback'),
            if (s.player.equalizerSupported)
              ListTile(
                leading: const Icon(Icons.equalizer_rounded),
                title: const Text('Equalizer & loudness'),
                onTap: () => showEqualizerSheet(context),
              )
            else
              const ListTile(
                leading: Icon(Icons.equalizer_rounded),
                title: Text('Equalizer'),
                subtitle: Text('Not available on this platform'),
                enabled: false,
              ),
            const SectionHeader('Privacy'),
            const ListTile(
              leading: Icon(Icons.airplanemode_active_rounded),
              title: Text('Works fully offline'),
              subtitle: Text('Audio analysis runs on this device with the bundled model. Nothing is uploaded or '
                  'downloaded, and organising never moves, renames, copies or deletes your files.'),
            ),
          ]);
        },
      ),
    );
  }

  static Future<void> _savePolicy(BuildContext context, ClassificationPolicy p) async {
    final s = context.read<AppServices>();
    await s.settings.setPolicy(p);
    s.scanner.revision.value++;
  }

  static Future<void> _editCategory(BuildContext context, AiCategory c) async {
    final s = context.read<AppServices>();
    final name = TextEditingController(text: c.name);
    final keywords = TextEditingController(text: c.keywords.join(', '));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Edit ${c.name}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Display name')),
          const SizedBox(height: 12),
          TextField(
            controller: keywords,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Metadata keywords (comma separated)',
              helperText: 'Supporting evidence only',
            ),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    await s.categories.update(c.copyWith(
      name: name.text.trim().isEmpty ? c.name : name.text.trim(),
      keywords: [for (final k in keywords.text.split(',')) if (k.trim().isNotEmpty) k.trim()],
    ));
    await s.scanner.categoriesChanged();
  }
}

extension on Widget {
  Widget withLongPress(VoidCallback onLongPress) => GestureDetector(onLongPress: onLongPress, child: this);
}
