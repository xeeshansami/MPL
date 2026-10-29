import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../core/models/category.dart';
import '../core/models/track.dart';
import '../player/player_controller.dart';
import 'playlists_screen.dart';
import 'track_ai_sheet.dart';

class CategoryVisual {
  const CategoryVisual(this.icon, this.color);

  final IconData icon;
  final Color color;

  static CategoryVisual of(String id) => _map[id] ?? const CategoryVisual(Icons.label_outline, Color(0xFF90A4AE));

  static const _map = {
    CategoryIds.quran: CategoryVisual(Icons.menu_book_rounded, Color(0xFF2FA37A)),
    CategoryIds.naat: CategoryVisual(Icons.auto_awesome_rounded, Color(0xFF4CC3A0)),
    CategoryIds.noha: CategoryVisual(Icons.water_drop_rounded, Color(0xFF6874D8)),
    CategoryIds.hamd: CategoryVisual(Icons.wb_sunny_rounded, Color(0xFFF2B451)),
    CategoryIds.manqabat: CategoryVisual(Icons.local_florist_rounded, Color(0xFFB57AD8)),
    CategoryIds.nasheed: CategoryVisual(Icons.record_voice_over_rounded, Color(0xFF3FB8B0)),
    CategoryIds.sad: CategoryVisual(Icons.cloud_rounded, Color(0xFF7E95A8)),
    CategoryIds.romantic: CategoryVisual(Icons.favorite_rounded, Color(0xFFE8737E)),
    CategoryIds.dance: CategoryVisual(Icons.nightlife_rounded, Color(0xFFFF7A4D)),
    CategoryIds.pop: CategoryVisual(Icons.star_rounded, Color(0xFFF06BA4)),
    CategoryIds.rock: CategoryVisual(Icons.electric_bolt_rounded, Color(0xFFE5534B)),
    CategoryIds.classical: CategoryVisual(Icons.piano_rounded, Color(0xFFB0927E)),
    CategoryIds.instrumental: CategoryVisual(Icons.music_note_rounded, Color(0xFF5FA8E8)),
    CategoryIds.speech: CategoryVisual(Icons.podcasts_rounded, Color(0xFF9A7FE0)),
    CategoryIds.other: CategoryVisual(Icons.graphic_eq_rounded, Color(0xFF8FA3AD)),
    CategoryIds.needsReview: CategoryVisual(Icons.help_outline_rounded, Color(0xFFF4C542)),
  };
}

String formatDuration(Duration d) {
  final h = d.inHours, m = d.inMinutes.remainder(60), s = d.inSeconds.remainder(60);
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// Reloads [load] whenever library data changes (scanner revision) or [deps] change.
class Reloading<T> extends StatefulWidget {
  const Reloading({super.key, required this.load, required this.builder, this.deps = const []});

  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data) builder;
  final List<Object?> deps;

  @override
  State<Reloading<T>> createState() => _ReloadingState<T>();
}

class _ReloadingState<T> extends State<Reloading<T>> {
  T? _data;
  Object? _error;
  late final ValueNotifier<int> _rev;

  @override
  void initState() {
    super.initState();
    _rev = context.read<AppServices>().scanner.revision..addListener(_reload);
    _reload();
  }

  @override
  void didUpdateWidget(covariant Reloading<T> old) {
    super.didUpdateWidget(old);
    if (old.deps.length != widget.deps.length ||
        [for (var i = 0; i < widget.deps.length; i++) old.deps[i] != widget.deps[i]].any((x) => x)) {
      _reload();
    }
  }

  Future<void> _reload() async {
    try {
      final d = await widget.load();
      if (mounted) {
        setState(() {
          _data = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _rev.removeListener(_reload);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text('Could not load: $_error'));
    final d = _data;
    if (d == null) return const Center(child: CircularProgressIndicator());
    return widget.builder(context, d);
  }
}

class Artwork extends StatelessWidget {
  const Artwork({super.key, required this.track, this.size = 48, this.radius = 10});

  final Track? track;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final path = track?.artworkPath;
    Widget child;
    if (path != null && File(path).existsSync()) {
      child = Image.file(File(path), width: size, height: size, fit: BoxFit.cover, cacheWidth: (size * 3).round(),
          errorBuilder: (_, _, _) => _placeholder(scheme));
    } else {
      child = _placeholder(scheme);
    }
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: SizedBox(width: size, height: size, child: child));
  }

  Widget _placeholder(ColorScheme scheme) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [scheme.primaryContainer, scheme.tertiaryContainer],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(child: Icon(Icons.music_note_rounded, size: size * 0.45, color: scheme.onPrimaryContainer)),
      );
}

/// Small pill showing an AI category and how it was assigned.
class CategoryChip extends StatelessWidget {
  const CategoryChip({super.key, required this.membership, this.name});

  final CategoryMembership membership;
  final String? name;

  @override
  Widget build(BuildContext context) {
    final v = CategoryVisual.of(membership.categoryId);
    final label = StringBuffer(name ?? membership.categoryId);
    if (membership.tier == AssignmentTier.provisional) label.write(' ?');
    if (membership.tier == AssignmentTier.user) label.write(' ✓');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: v.color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
        border: membership.tier == AssignmentTier.provisional ? Border.all(color: v.color.withValues(alpha: 0.6)) : null,
      ),
      child: Text(label.toString(), style: TextStyle(fontSize: 11, color: v.color, fontWeight: FontWeight.w600)),
    );
  }
}

class ConfidenceBar extends StatelessWidget {
  const ConfidenceBar({super.key, required this.value, required this.color, this.marks = const []});

  final double value;
  final Color color;

  /// Threshold markers (0..1) drawn over the bar.
  final List<double> marks;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      return SizedBox(
        height: 8,
        child: Stack(children: [
          Container(decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4))),
          FractionallySizedBox(
            widthFactor: value.clamp(0, 1),
            child: Container(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4))),
          ),
          for (final m in marks)
            Positioned(
              left: (c.maxWidth * m).clamp(0, c.maxWidth - 2),
              top: 0,
              bottom: 0,
              child: Container(width: 2, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5)),
            ),
        ]),
      );
    });
  }
}

class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.track,
    required this.onTap,
    this.memberships = const [],
    this.categoryNames = const {},
    this.trailing,
    this.subtitleOverride,
  });

  final Track track;
  final VoidCallback onTap;
  final List<CategoryMembership> memberships;
  final Map<String, String> categoryNames;
  final Widget? trailing;
  final String? subtitleOverride;

  @override
  Widget build(BuildContext context) {
    final player = context.read<AppServices>().player;
    final isCurrent = context.select<PlayerController, bool>((p) => p.current?.id == track.id);
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      leading: Artwork(track: track),
      title: Text(track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: isCurrent ? TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w600) : null),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(subtitleOverride ?? '${track.displayArtist} · ${formatDuration(track.duration)}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        if (memberships.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(spacing: 4, runSpacing: 4, children: [
              for (final m in memberships) CategoryChip(membership: m, name: categoryNames[m.categoryId]),
            ]),
          ),
      ]),
      trailing: trailing ??
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (v) async {
              switch (v) {
                case 'next':
                  await player.playNext(track);
                case 'queue':
                  await player.addToQueue([track]);
                case 'playlist':
                  if (context.mounted) await showAddToPlaylist(context, [track.id]);
                case 'fav':
                  await player.toggleFavorite(track);
                  if (context.mounted) context.read<AppServices>().scanner.revision.value++;
                case 'ai':
                  if (context.mounted) await showTrackAiSheet(context, track.id);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'next', child: Text('Play next')),
              const PopupMenuItem(value: 'queue', child: Text('Add to queue')),
              const PopupMenuItem(value: 'playlist', child: Text('Add to playlist…')),
              PopupMenuItem(value: 'fav', child: Text(track.favorite ? 'Remove from favourites' : 'Add to favourites')),
              const PopupMenuItem(value: 'ai', child: Text('AI category & correction…')),
            ],
          ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 8, 8),
        child: Row(children: [
          Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
          ?action,
        ]),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 56, color: theme.colorScheme.primary.withValues(alpha: 0.7)),
          const SizedBox(height: 12),
          Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(message!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center),
          ],
          if (action != null) ...[const SizedBox(height: 16), action!],
        ]),
      ),
    );
  }
}

/// Loads category display names once per build tree.
Future<Map<String, String>> categoryNames(AppServices s) async =>
    {for (final c in await s.categories.all()) c.id: c.name};
