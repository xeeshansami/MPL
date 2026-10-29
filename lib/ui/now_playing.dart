import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../core/models/track.dart';
import '../player/player_controller.dart';
import 'common.dart';
import 'playlists_screen.dart';
import 'track_ai_sheet.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final pc = context.watch<PlayerController>();
    final t = pc.current;
    if (t == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF1A212A) : scheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NowPlayingScreen(), fullscreenDialog: true)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _Progress(player: pc.player, thin: true),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(children: [
              Hero(tag: 'art', child: Artwork(track: t, size: 44, radius: 8)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(t.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ]),
              ),
              IconButton(
                icon: Icon(pc.player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 32),
                onPressed: pc.togglePlay,
              ),
              IconButton(icon: const Icon(Icons.skip_next_rounded), onPressed: pc.player.hasNext ? pc.next : null),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.player, this.thin = false});

  final AudioPlayer player;
  final bool thin;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.positionStream,
      builder: (context, snap) {
        final pos = snap.data ?? Duration.zero;
        final dur = player.duration ?? Duration.zero;
        final value = dur.inMilliseconds == 0 ? 0.0 : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
        if (thin) return LinearProgressIndicator(value: value, minHeight: 2);
        return Column(children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(trackHeight: 4, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7)),
            child: Slider(
              value: value,
              onChanged: dur == Duration.zero ? null : (v) => player.seek(dur * v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(children: [
              Text(formatDuration(pos), style: Theme.of(context).textTheme.bodySmall),
              const Spacer(),
              Text(formatDuration(dur), style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ]);
      },
    );
  }
}

class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final pc = context.watch<PlayerController>();
    final s = context.read<AppServices>();
    final t = pc.current;
    final scheme = Theme.of(context).colorScheme;
    if (t == null) {
      return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.music_note_rounded, title: 'Nothing playing'));
    }
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.keyboard_arrow_down_rounded), onPressed: () => Navigator.pop(context)),
        title: const Text('Now playing'),
        centerTitle: true,
        actions: [
          IconButton(tooltip: 'Queue', icon: const Icon(Icons.queue_music_rounded), onPressed: () => _showQueue(context)),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [scheme.primary.withValues(alpha: 0.22), Theme.of(context).scaffoldBackgroundColor],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(builder: (context, c) {
            final art = (c.maxWidth - 64).clamp(160.0, c.maxHeight * 0.45);
            return ListView(padding: const EdgeInsets.symmetric(vertical: 16), children: [
              Center(
                child: Hero(
                  tag: 'art',
                  child: DecoratedBox(
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(28), boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 32, offset: const Offset(0, 16)),
                    ]),
                    child: Artwork(track: t, size: art, radius: 28),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                      Text('${t.displayArtist} · ${t.displayAlbum}', maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                    ]),
                  ),
                  IconButton(
                    icon: Icon(t.favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                        color: t.favorite ? Colors.pinkAccent : null),
                    onPressed: () async {
                      await pc.toggleFavorite(t);
                      s.scanner.revision.value++;
                    },
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                child: Reloading<(List<CategoryMembership>, Map<String, String>)>(
                  deps: [t.id],
                  load: () async => ((await s.tracks.memberships(trackIds: [t.id]))[t.id] ?? const <CategoryMembership>[],
                      await categoryNames(s)),
                  builder: (context, d) => InkWell(
                    onTap: () => showTrackAiSheet(context, t.id),
                    child: Wrap(spacing: 6, runSpacing: 6, children: [
                      if (d.$1.isEmpty) const Text('Not categorised yet', style: TextStyle(fontSize: 12)),
                      for (final m in d.$1) CategoryChip(membership: m, name: d.$2[m.categoryId]),
                    ]),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _Progress(player: pc.player),
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                IconButton(
                  icon: Icon(Icons.shuffle_rounded, color: pc.player.shuffleModeEnabled ? scheme.primary : null),
                  onPressed: pc.toggleShuffle,
                ),
                IconButton(iconSize: 40, icon: const Icon(Icons.skip_previous_rounded), onPressed: pc.previous),
                IconButton.filled(
                  iconSize: 48,
                  icon: Icon(pc.player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                  onPressed: pc.togglePlay,
                ),
                IconButton(iconSize: 40, icon: const Icon(Icons.skip_next_rounded), onPressed: pc.player.hasNext ? pc.next : null),
                IconButton(
                  icon: Icon(
                    pc.player.loopMode == LoopMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                    color: pc.player.loopMode == LoopMode.off ? null : scheme.primary,
                  ),
                  onPressed: pc.cycleRepeat,
                ),
              ]),
              const SizedBox(height: 12),
              Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
                ActionChip(
                  avatar: const Icon(Icons.speed_rounded, size: 18),
                  label: Text('${pc.player.speed}×'),
                  onPressed: () => _showSpeed(context),
                ),
                ActionChip(
                  avatar: const Icon(Icons.bedtime_outlined, size: 18),
                  label: Text(pc.sleepDeadline == null
                      ? 'Sleep timer'
                      : pc.sleepAtTrackEnd
                          ? 'End of track'
                          : 'Until ${TimeOfDay.fromDateTime(pc.sleepDeadline!).format(context)}'),
                  onPressed: () => _showSleep(context),
                ),
                if (pc.equalizerSupported)
                  ActionChip(
                    avatar: const Icon(Icons.equalizer_rounded, size: 18),
                    label: const Text('Equalizer'),
                    onPressed: () => showEqualizerSheet(context),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.playlist_add_rounded, size: 18),
                  label: const Text('Add to playlist'),
                  onPressed: () => showAddToPlaylist(context, [t.id]),
                ),
              ]),
            ]);
          }),
        ),
      ),
    );
  }

  void _showQueue(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        builder: (_) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (ctx, controller) {
            final pc = ctx.watch<PlayerController>();
            final current = pc.player.currentIndex ?? -1;
            return Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(children: [
                  Text('Queue · ${pc.queue.length}', style: Theme.of(ctx).textTheme.titleMedium),
                ]),
              ),
              Expanded(
                child: ReorderableListView.builder(
                  scrollController: controller,
                  itemCount: pc.queue.length,
                  onReorder: (from, to) => pc.move(from, to > from ? to - 1 : to),
                  itemBuilder: (_, i) {
                    final q = pc.queue[i];
                    return ListTile(
                      key: ValueKey('q$i-${q.id}'),
                      selected: i == current,
                      leading: Artwork(track: q, size: 40),
                      title: Text(q.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(q.displayArtist, maxLines: 1),
                      onTap: () => pc.jumpTo(i),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (i != current)
                          IconButton(icon: const Icon(Icons.remove_circle_outline_rounded), onPressed: () => pc.removeAt(i)),
                        ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle_rounded)),
                      ]),
                    );
                  },
                ),
              ),
            ]);
          },
        ),
      );

  void _showSpeed(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (ctx) {
          final pc = context.read<PlayerController>();
          return SafeArea(
            child: Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
              for (final v in const [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
                ChoiceChip(
                  label: Text('$v×'),
                  selected: pc.player.speed == v,
                  onSelected: (_) {
                    pc.setSpeed(v);
                    Navigator.pop(ctx);
                  },
                ),
              const SizedBox(height: 64, width: double.infinity),
            ]),
          );
        },
      );

  void _showSleep(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (ctx) {
          final pc = context.read<PlayerController>();
          void pick(Duration? d) {
            pc.setSleepTimer(d);
            Navigator.pop(ctx);
          }

          return SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final m in const [5, 15, 30, 45, 60, 90])
                ListTile(title: Text('$m minutes'), onTap: () => pick(Duration(minutes: m))),
              ListTile(
                title: const Text('End of current track'),
                onTap: () {
                  pc.sleepAfterCurrentTrack();
                  Navigator.pop(ctx);
                },
              ),
              if (pc.sleepDeadline != null) ListTile(title: const Text('Turn off'), onTap: () => pick(null)),
            ]),
          );
        },
      );
}

/// Android only: platform equalizer and loudness enhancer (just_audio effects).
Future<void> showEqualizerSheet(BuildContext context) {
  final pc = context.read<PlayerController>();
  final eq = pc.equalizer, loud = pc.loudness;
  if (eq == null || loud == null) return Future.value();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: FutureBuilder<AndroidEqualizerParameters>(
          future: eq.parameters,
          builder: (ctx, snap) {
            if (snap.hasError) return Text('Equalizer unavailable: ${snap.error}');
            final p = snap.data;
            if (p == null) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Start playback to initialise the equalizer.'),
              );
            }
            return Column(mainAxisSize: MainAxisSize.min, children: [
              StreamBuilder<bool>(
                stream: eq.enabledStream,
                builder: (_, s) => SwitchListTile(
                  title: const Text('Equalizer'),
                  value: s.data ?? false,
                  onChanged: eq.setEnabled,
                ),
              ),
              SizedBox(
                height: 220,
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  for (final band in p.bands)
                    Column(children: [
                      Expanded(
                        child: RotatedBox(
                          quarterTurns: -1,
                          child: StreamBuilder<double>(
                            stream: band.gainStream,
                            builder: (_, g) => Slider(
                              min: p.minDecibels,
                              max: p.maxDecibels,
                              value: (g.data ?? band.gain).clamp(p.minDecibels, p.maxDecibels),
                              onChanged: band.setGain,
                            ),
                          ),
                        ),
                      ),
                      Text(band.centerFrequency >= 1000
                          ? '${(band.centerFrequency / 1000).toStringAsFixed(1)}k'
                          : band.centerFrequency.round().toString()),
                    ]),
                ]),
              ),
              StreamBuilder<bool>(
                stream: loud.enabledStream,
                builder: (_, s) => SwitchListTile(
                  title: const Text('Loudness enhancer'),
                  value: s.data ?? false,
                  onChanged: loud.setEnabled,
                ),
              ),
              StreamBuilder<double>(
                stream: loud.targetGainStream,
                builder: (_, g) => Slider(
                  min: 0,
                  max: 1,
                  value: (g.data ?? 0).clamp(0, 1),
                  label: '+${(g.data ?? 0).toStringAsFixed(1)} dB',
                  onChanged: loud.setTargetGain,
                ),
              ),
            ]);
          },
        ),
      ),
    ),
  );
}
