import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../core/models/track.dart';
import '../data/catalog_repositories.dart';
import '../data/track_repository.dart';
import 'common.dart';
import 'library_screen.dart';

/// User playlists, independent from the automatic AI playlists.
class PlaylistsScreen extends StatelessWidget {
  const PlaylistsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return Scaffold(
      appBar: AppBar(title: const Text('Playlists')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => createPlaylistDialog(context),
        icon: const Icon(Icons.playlist_add_rounded),
        label: const Text('New playlist'),
      ),
      body: Reloading<List<UserPlaylist>>(
        load: s.playlists.all,
        builder: (context, lists) => ListView(padding: const EdgeInsets.only(bottom: 96), children: [
          _Smart(
            icon: Icons.favorite_rounded,
            title: 'Favourites',
            load: () => s.tracks.all(favoritesOnly: true, sort: TrackSort.title),
          ),
          _Smart(icon: Icons.history_rounded, title: 'Recently played', load: () => s.tracks.recentlyPlayed(limit: 100)),
          _Smart(
            icon: Icons.trending_up_rounded,
            title: 'Most played',
            load: () async => (await s.tracks.all(sort: TrackSort.mostPlayed)).where((t) => t.playCount > 0).take(100).toList(),
          ),
          const SectionHeader('Your playlists'),
          if (lists.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Create playlists for your own mixes. AI playlists live under AI Categories.'),
            ),
          for (final p in lists)
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.queue_music_rounded)),
              title: Text(p.name),
              subtitle: Text('${p.trackCount} tracks'),
              trailing: PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'rename') {
                    final name = await _nameDialog(context, 'Rename playlist', initial: p.name);
                    if (name != null) await s.playlists.rename(p.id, name);
                  } else if (v == 'delete') {
                    await s.playlists.delete(p.id);
                  }
                  s.scanner.revision.value++;
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'delete', child: Text('Delete playlist')),
                ],
              ),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaylistDetailScreen(playlist: p))),
            ),
        ]),
      ),
    );
  }
}

class _Smart extends StatelessWidget {
  const _Smart({required this.icon, required this.title, required this.load});

  final IconData icon;
  final String title;
  final Future<List<Track>> Function() load;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Icon(icon, color: Theme.of(context).colorScheme.onPrimaryContainer),
        ),
        title: Text(title),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TrackListScreen(title: title, load: load))),
      );
}

class PlaylistDetailScreen extends StatelessWidget {
  const PlaylistDetailScreen({super.key, required this.playlist});

  final UserPlaylist playlist;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return Scaffold(
      appBar: AppBar(title: Text(playlist.name)),
      body: Reloading<List<Track>>(
        load: () => s.playlists.tracks(playlist.id),
        builder: (context, tracks) {
          if (tracks.isEmpty) {
            return const EmptyState(
              icon: Icons.playlist_add_rounded,
              title: 'Empty playlist',
              message: 'Use “Add to playlist…” from any track menu.',
            );
          }
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(children: [
                Text('${tracks.length} tracks'),
                const Spacer(),
                TextButton.icon(
                    onPressed: () => s.player.playTracks(tracks, shuffle: true),
                    icon: const Icon(Icons.shuffle_rounded),
                    label: const Text('Shuffle')),
                FilledButton.icon(
                    onPressed: () => s.player.playTracks(tracks),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Play')),
              ]),
            ),
            Expanded(
              child: ReorderableListView.builder(
                itemCount: tracks.length,
                onReorder: (from, to) async {
                  final list = [...tracks];
                  final t = list.removeAt(from);
                  list.insert(to > from ? to - 1 : to, t);
                  await s.playlists.reorder(playlist.id, [for (final x in list) x.id]);
                  s.scanner.revision.value++;
                },
                itemBuilder: (_, i) => Dismissible(
                  key: ValueKey(tracks[i].id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    color: Colors.red.withValues(alpha: 0.3),
                    child: const Icon(Icons.playlist_remove_rounded),
                  ),
                  onDismissed: (_) async {
                    await s.playlists.removeTrack(playlist.id, tracks[i].id);
                    s.scanner.revision.value++;
                  },
                  child: TrackTile(
                    track: tracks[i],
                    onTap: () => s.player.playTracks(tracks, start: i),
                    trailing: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle_rounded)),
                  ),
                ),
              ),
            ),
          ]);
        },
      ),
    );
  }
}

Future<String?> _nameDialog(BuildContext context, String title, {String initial = ''}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(labelText: 'Name')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, c.text.trim().isEmpty ? null : c.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

Future<int?> createPlaylistDialog(BuildContext context) async {
  final s = context.read<AppServices>();
  final name = await _nameDialog(context, 'New playlist');
  if (name == null) return null;
  final id = await s.playlists.create(name);
  s.scanner.revision.value++;
  return id;
}

Future<void> showAddToPlaylist(BuildContext context, List<int> trackIds) async {
  final s = context.read<AppServices>();
  final lists = await s.playlists.all();
  if (!context.mounted) return;
  final chosen = await showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => ListView(shrinkWrap: true, children: [
      ListTile(
        leading: const Icon(Icons.add_rounded),
        title: const Text('New playlist…'),
        onTap: () async {
          final id = await createPlaylistDialog(ctx);
          if (ctx.mounted) Navigator.pop(ctx, id);
        },
      ),
      for (final p in lists)
        ListTile(
          leading: const Icon(Icons.queue_music_rounded),
          title: Text(p.name),
          subtitle: Text('${p.trackCount} tracks'),
          onTap: () => Navigator.pop(ctx, p.id),
        ),
    ]),
  );
  if (chosen == null) return;
  final added = await s.playlists.addTracks(chosen, trackIds);
  s.scanner.revision.value++;
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(added == 0 ? 'Already in playlist' : 'Added $added track(s)'),
    ));
  }
}
