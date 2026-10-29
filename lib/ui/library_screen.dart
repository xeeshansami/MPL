import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../core/models/track.dart';
import '../data/track_repository.dart';
import 'common.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _search = TextEditingController();
  String _query = '';
  TrackSort _sort = TrackSort.title;
  bool _favorites = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Library'),
          actions: [
            PopupMenuButton<TrackSort>(
              tooltip: 'Sort',
              icon: const Icon(Icons.sort_rounded),
              initialValue: _sort,
              onSelected: (v) => setState(() => _sort = v),
              itemBuilder: (_) => const [
                PopupMenuItem(value: TrackSort.title, child: Text('Title')),
                PopupMenuItem(value: TrackSort.artist, child: Text('Artist')),
                PopupMenuItem(value: TrackSort.album, child: Text('Album')),
                PopupMenuItem(value: TrackSort.dateAdded, child: Text('Recently added')),
                PopupMenuItem(value: TrackSort.duration, child: Text('Duration')),
                PopupMenuItem(value: TrackSort.mostPlayed, child: Text('Most played')),
              ],
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(112),
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(children: [
                  Expanded(
                    child: SearchBar(
                      controller: _search,
                      hintText: 'Search title, artist, album, file',
                      leading: const Icon(Icons.search_rounded),
                      elevation: const WidgetStatePropertyAll(0),
                      onChanged: (v) => setState(() => _query = v),
                      trailing: [
                        if (_query.isNotEmpty)
                          IconButton(
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => setState(() {
                              _search.clear();
                              _query = '';
                            }),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Icon(Icons.favorite_rounded, size: 18),
                    selected: _favorites,
                    onSelected: (v) => setState(() => _favorites = v),
                  ),
                ]),
              ),
              const TabBar(tabs: [Tab(text: 'Songs'), Tab(text: 'Albums'), Tab(text: 'Artists')]),
            ]),
          ),
        ),
        body: Reloading<(List<Track>, Map<int, List<CategoryMembership>>, Map<String, String>)>(
          deps: [_query, _sort, _favorites],
          load: () async {
            final tracks = await s.tracks.all(sort: _sort, query: _query, favoritesOnly: _favorites);
            return (tracks, await s.tracks.memberships(), await categoryNames(s));
          },
          builder: (context, d) {
            final (tracks, members, names) = d;
            if (tracks.isEmpty) {
              return EmptyState(
                icon: Icons.music_off_rounded,
                title: _query.isEmpty && !_favorites ? 'Library is empty' : 'No matches',
                message: _query.isEmpty && !_favorites ? 'Import audio from Home or Settings.' : null,
              );
            }
            return TabBarView(children: [
              _SongList(tracks: tracks, members: members, names: names),
              _GroupList(tracks: tracks, keyOf: (t) => t.displayAlbum, subtitle: (t) => t.displayArtist, icon: Icons.album_rounded),
              _GroupList(tracks: tracks, keyOf: (t) => t.displayArtist, icon: Icons.person_rounded),
            ]);
          },
        ),
      ),
    );
  }
}

class _SongList extends StatelessWidget {
  const _SongList({required this.tracks, required this.members, required this.names});

  final List<Track> tracks;
  final Map<int, List<CategoryMembership>> members;
  final Map<String, String> names;

  @override
  Widget build(BuildContext context) {
    final player = context.read<AppServices>().player;
    return ListView.builder(
      itemCount: tracks.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(children: [
              Text('${tracks.length} tracks', style: Theme.of(context).textTheme.labelLarge),
              const Spacer(),
              TextButton.icon(onPressed: () => player.playTracks(tracks, shuffle: true),
                  icon: const Icon(Icons.shuffle_rounded), label: const Text('Shuffle')),
              FilledButton.icon(onPressed: () => player.playTracks(tracks),
                  icon: const Icon(Icons.play_arrow_rounded), label: const Text('Play')),
            ]),
          );
        }
        final t = tracks[i - 1];
        return TrackTile(
          track: t,
          memberships: members[t.id] ?? const [],
          categoryNames: names,
          onTap: () => player.playTracks(tracks, start: i - 1),
        );
      },
    );
  }
}

class _GroupList extends StatelessWidget {
  const _GroupList({required this.tracks, required this.keyOf, required this.icon, this.subtitle});

  final List<Track> tracks;
  final String Function(Track) keyOf;
  final String Function(Track)? subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<Track>>{};
    for (final t in tracks) {
      (groups[keyOf(t)] ??= []).add(t);
    }
    final keys = groups.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return ListView.builder(
      itemCount: keys.length,
      itemBuilder: (_, i) {
        final list = groups[keys[i]]!;
        return ListTile(
          leading: Artwork(track: list.firstWhere((t) => t.artworkPath != null, orElse: () => list.first)),
          title: Text(keys[i], maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${subtitle == null ? '' : '${subtitle!(list.first)} · '}${list.length} tracks'),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => TrackListScreen(title: keys[i], load: () async => list),
          )),
        );
      },
    );
  }
}

/// Generic track list page (album, artist, favourites…).
class TrackListScreen extends StatelessWidget {
  const TrackListScreen({super.key, required this.title, required this.load});

  final String title;
  final Future<List<Track>> Function() load;

  @override
  Widget build(BuildContext context) {
    final player = context.read<AppServices>().player;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Reloading<List<Track>>(
        load: load,
        builder: (context, tracks) => tracks.isEmpty
            ? const EmptyState(icon: Icons.music_off_rounded, title: 'Nothing here yet')
            : ListView.builder(
                itemCount: tracks.length,
                itemBuilder: (_, i) => TrackTile(track: tracks[i], onTap: () => player.playTracks(tracks, start: i)),
              ),
      ),
    );
  }
}
