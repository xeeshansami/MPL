import '../core/models/category.dart';

enum EvidenceStrength { weak, medium, strong }

/// One keyword hit in a track's metadata. Supporting evidence only.
class MetadataMatch {
  const MetadataMatch({
    required this.categoryId,
    required this.field,
    required this.keyword,
    required this.strength,
  });

  final String categoryId;
  final String field;
  final String keyword;
  final EvidenceStrength strength;

  Map<String, Object?> toJson() =>
      {'category': categoryId, 'field': field, 'keyword': keyword, 'strength': strength.name};
}

/// Whole-token keyword matching over title/artist/album/genre/filename/folder.
///
/// Strength by field: an embedded genre tag is *strong*; title, album and
/// artist are *medium*; filename and folder are *weak*.
class MetadataRules {
  MetadataRules(List<AiCategory> categories)
      : _rules = [
          for (final c in categories)
            if (c.enabled && !c.isNeedsReview)
              for (final k in c.keywords)
                if (tokenize(k).isNotEmpty) (categoryId: c.id, keyword: k, tokens: tokenize(k)),
        ];

  final List<({String categoryId, String keyword, List<String> tokens})> _rules;

  static final _split = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
  static final _apostrophes = RegExp('[\'’`ʼ]');
  static final _extension = RegExp(r'\.[A-Za-z0-9]{2,5}$');

  static List<String> tokenize(String s) =>
      s.toLowerCase().replaceAll(_apostrophes, '').split(_split).where((t) => t.isNotEmpty).toList();

  List<MetadataMatch> evaluate({
    String? title,
    String? artist,
    String? album,
    String? genre,
    String? filename,
    String? folder,
  }) {
    final fields = <(String, String?, EvidenceStrength)>[
      ('genre', genre, EvidenceStrength.strong),
      ('title', title, EvidenceStrength.medium),
      ('album', album, EvidenceStrength.medium),
      ('artist', artist, EvidenceStrength.medium),
      ('filename', filename?.replaceAll(_extension, ''), EvidenceStrength.weak),
      ('folder', folder, EvidenceStrength.weak),
    ];
    final best = <String, MetadataMatch>{};
    for (final (field, value, strength) in fields) {
      if (value == null || value.isEmpty) continue;
      final tokens = tokenize(value);
      for (final rule in _rules) {
        if (!_containsPhrase(tokens, rule.tokens)) continue;
        final prev = best[rule.categoryId];
        if (prev == null || strength.index > prev.strength.index) {
          best[rule.categoryId] =
              MetadataMatch(categoryId: rule.categoryId, field: field, keyword: rule.keyword, strength: strength);
        }
      }
    }
    return best.values.toList();
  }

  static bool _containsPhrase(List<String> tokens, List<String> phrase) {
    outer:
    for (var i = 0; i + phrase.length <= tokens.length; i++) {
      for (var j = 0; j < phrase.length; j++) {
        if (tokens[i + j] != phrase[j]) continue outer;
      }
      return true;
    }
    return false;
  }
}
