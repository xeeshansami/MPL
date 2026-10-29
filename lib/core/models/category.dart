import 'dart:convert';

/// A configurable AI category. Each category is a virtual playlist.
class AiCategory {
  const AiCategory({
    required this.id,
    required this.name,
    required this.description,
    this.enabled = true,
    this.sortOrder = 0,
    this.keywords = const [],
    this.builtin = true,
  });

  final String id;
  final String name;
  final String description;
  final bool enabled;
  final int sortOrder;

  /// Words/phrases used as *supporting* metadata evidence (never as a
  /// replacement for audio inference). Matched as whole tokens.
  final List<String> keywords;
  final bool builtin;

  bool get isNeedsReview => id == CategoryIds.needsReview;

  AiCategory copyWith({String? name, bool? enabled, List<String>? keywords}) => AiCategory(
        id: id,
        name: name ?? this.name,
        description: description,
        enabled: enabled ?? this.enabled,
        sortOrder: sortOrder,
        keywords: keywords ?? this.keywords,
        builtin: builtin,
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'description': description,
        'enabled': enabled ? 1 : 0,
        'sort_order': sortOrder,
        'keywords': jsonEncode(keywords),
        'builtin': builtin ? 1 : 0,
      };

  factory AiCategory.fromRow(Map<String, Object?> r) => AiCategory(
        id: r['id'] as String,
        name: r['name'] as String,
        description: r['description'] as String,
        enabled: (r['enabled'] as int) == 1,
        sortOrder: r['sort_order'] as int,
        keywords: (jsonDecode(r['keywords'] as String) as List).cast<String>(),
        builtin: (r['builtin'] as int) == 1,
      );
}

abstract final class CategoryIds {
  static const quran = 'quran';
  static const naat = 'naat';
  static const noha = 'noha';
  static const hamd = 'hamd';
  static const manqabat = 'manqabat';
  static const nasheed = 'nasheed';
  static const sad = 'sad';
  static const romantic = 'romantic';
  static const dance = 'dance';
  static const pop = 'pop';
  static const rock = 'rock';
  static const classical = 'classical';
  static const instrumental = 'instrumental';
  static const speech = 'speech';
  static const other = 'other';
  static const needsReview = 'needs_review';
}

abstract final class CategoryDefaults {
  static const all = <AiCategory>[
    AiCategory(
      id: CategoryIds.quran,
      name: 'Quran',
      description: 'Quran recitation and tilawat',
      keywords: ['quran', "qur'an", 'quran e pak', 'tilawat', 'tilawah', 'tilawa', 'surah', 'surat', 'sura',
        'qari', 'qirat', 'qiraat', 'juz', 'para', 'قرآن', 'القرآن', 'سورة', 'سورہ', 'تلاوت'],
    ),
    AiCategory(
      id: CategoryIds.naat,
      name: 'Naat',
      description: 'Islamic devotional poetry and praise',
      keywords: ['naat', "na'at", 'naats', 'naat sharif', 'naat shareef', 'نعت'],
    ),
    AiCategory(
      id: CategoryIds.noha,
      name: 'Noha',
      description: 'Noha and elegiac devotional recitations',
      keywords: ['noha', 'nauha', 'nohay', 'nohe', 'marsiya', 'marsia', 'nouha', 'نوحہ', 'نوحه', 'مرثیہ'],
    ),
    AiCategory(
      id: CategoryIds.hamd,
      name: 'Hamd',
      description: 'Islamic devotional praise of God',
      keywords: ['hamd', 'hamd e bari', 'hamd e bari tala', 'حمد'],
    ),
    AiCategory(
      id: CategoryIds.manqabat,
      name: 'Manqabat',
      description: 'Devotional poetry in praise of revered religious figures',
      keywords: ['manqabat', 'munqabat', 'manqbat', 'manqabaat', 'منقبت'],
    ),
    AiCategory(
      id: CategoryIds.nasheed,
      name: 'Nasheed',
      description: 'Nasheeds and devotional vocal recordings',
      keywords: ['nasheed', 'nasheeds', 'anasheed', 'nashid', 'نشيد', 'نشید', 'أناشيد'],
    ),
    AiCategory(
      id: CategoryIds.sad,
      name: 'Sad Music',
      description: 'Sad or melancholic songs',
      keywords: ['sad', 'sad song', 'heartbreak', 'melancholy', 'dard', 'gham', 'judai', 'bewafa', 'breakup'],
    ),
    AiCategory(
      id: CategoryIds.romantic,
      name: 'Romantic Music',
      description: 'Romantic songs',
      keywords: ['romantic', 'love song', 'ishq', 'pyar', 'mohabbat', 'romance'],
    ),
    AiCategory(
      id: CategoryIds.dance,
      name: 'Dance Music',
      description: 'Dance-oriented and high-energy music',
      keywords: ['dance', 'edm', 'house', 'techno', 'trance', 'club', 'electronic', 'electronica', 'bhangra',
        'disco', 'dubstep', 'drum and bass'],
    ),
    AiCategory(id: CategoryIds.pop, name: 'Pop Music', description: 'Pop music',
        keywords: ['pop', 'k pop', 'j pop', 'synthpop', 'dance pop']),
    AiCategory(id: CategoryIds.rock, name: 'Rock Music', description: 'Rock music',
        keywords: ['rock', 'hard rock', 'metal', 'heavy metal', 'punk', 'grunge', 'alternative rock']),
    AiCategory(id: CategoryIds.classical, name: 'Classical Music', description: 'Classical music',
        keywords: ['classical', 'symphony', 'concerto', 'sonata', 'opera', 'baroque', 'orchestra', 'raag', 'raga']),
    AiCategory(id: CategoryIds.instrumental, name: 'Instrumental Music', description: 'Music without vocals',
        keywords: ['instrumental', 'karaoke', 'bgm', 'no vocals']),
    AiCategory(
      id: CategoryIds.speech,
      name: 'Podcast / Speech',
      description: 'Spoken-word recordings and podcasts',
      keywords: ['podcast', 'episode', 'lecture', 'bayan', 'audiobook', 'interview', 'speech', 'spoken word',
        'sermon', 'khutbah', 'dars', 'talk'],
    ),
    AiCategory(id: CategoryIds.other, name: 'Other Audio',
        description: 'Recognised audio that does not fit a supported category'),
    AiCategory(id: CategoryIds.needsReview, name: 'Needs Review',
        description: 'The AI could not confidently select a category'),
  ];
}
