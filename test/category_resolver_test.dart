import 'package:flutter_test/flutter_test.dart';
import 'package:mpl/ai/category_resolver.dart';
import 'package:mpl/ai/metadata_rules.dart';
import 'package:mpl/core/models/category.dart';
import 'package:mpl/core/models/track.dart';

import 'helpers.dart';

void main() {
  final m = testManifest();
  final all = {for (final c in CategoryDefaults.all) c.id};
  const resolver = CategoryResolver();

  Resolution run(
    List<Map<String, double>> windows, {
    List<double>? levels,
    List<MetadataMatch> meta = const [],
    Set<String>? enabled,
    ClassificationPolicy policy = const ClassificationPolicy(),
  }) =>
      resolver.resolve(
        manifest: m,
        windowScores: [for (final w in windows) scores(m, w)],
        windowLevelsDb: levels ?? List.filled(windows.length, -20),
        metadata: meta,
        enabledCategoryIds: enabled ?? all,
        policy: policy,
      );

  MetadataMatch match(String cat, EvidenceStrength s, {String field = 'genre'}) =>
      MetadataMatch(categoryId: cat, field: field, keyword: cat, strength: s);

  test('high confidence assigns automatically', () {
    final r = run(List.filled(5, {'quran': 0.95}));
    expect(r.needsReview, isFalse);
    expect(r.assignments.single.categoryId, 'quran');
    expect(r.assignments.single.tier, AssignmentTier.auto);
    expect(r.assignments.single.confidence, closeTo(0.95, 1e-9));
  });

  test('medium confidence is provisional', () {
    final r = run(List.filled(5, {'naat': 0.6}));
    expect(r.assignments.single.tier, AssignmentTier.provisional);
  });

  test('low confidence goes to Needs Review with a best guess', () {
    final r = run(List.filled(5, {'noha': 0.3}));
    expect(r.needsReview, isTrue);
    expect(r.assignments, isEmpty);
    expect((r.evidence['best_guess'] as Map)['category'], 'noha');
  });

  test('ambiguous audio can stay uncertain', () {
    final r = run(List.filled(5, {'quran': 0.45, 'naat': 0.45, 'speech': 0.4}));
    expect(r.needsReview, isTrue);
  });

  test('silence / too little audio → Needs Review', () {
    final r = run(List.filled(5, {'quran': 0.99}), levels: [-90, -90, -90, -20, -90]);
    expect(r.needsReview, isTrue);
    expect(r.reviewReason, contains('audible'));
  });

  test('silent windows are excluded from the average', () {
    final windows = [
      {'quran': 0.95}, {'quran': 0.95}, {'quran': 0.95}, {'quran': 0.95}, {'quran': 0.0},
    ];
    final r = run(windows, levels: [-20, -20, -20, -20, -100]);
    expect(r.scores['quran'], closeTo(0.95, 1e-9));
  });

  test('multi-label: a song can be both sad and romantic', () {
    final r = run(List.filled(5, {'sad': 0.9, 'romantic': 0.85}));
    expect(r.assignments.map((a) => a.categoryId), ['sad', 'romantic']);
  });

  test('single-label model keeps only the arg-max', () {
    final single = testManifest(multiLabel: false);
    final r = resolver.resolve(
      manifest: single,
      windowScores: List.filled(3, scores(single, {'sad': 0.9, 'romantic': 0.85})),
      windowLevelsDb: List.filled(3, -20),
      metadata: const [],
      enabledCategoryIds: all,
    );
    expect(r.assignments.map((a) => a.categoryId), ['sad']);
  });

  test('maxLabels caps the number of categories', () {
    final r = run(List.filled(5, {'sad': 0.9, 'romantic': 0.88, 'speech': 0.86}),
        policy: const ClassificationPolicy(maxLabels: 2));
    expect(r.assignments.length, 2);
  });

  test('mixed recording (low window agreement) is capped at provisional', () {
    final windows = [
      {'quran': 1.0}, {'quran': 1.0}, {'quran': 1.0}, {'quran': 1.0}, {'quran': 0.3},
    ];
    expect(run(windows).assignments.single.tier, AssignmentTier.auto); // 4/5 windows agree
    final strict = run(windows, policy: const ClassificationPolicy(windowAgreementMin: 0.9));
    expect(strict.scores['quran'], closeTo(0.86, 1e-9));
    expect(strict.assignments.single.tier, AssignmentTier.provisional);
  });

  test('strong genre tag promotes provisional to auto (policy on)', () {
    final r = run(List.filled(5, {'naat': 0.6}), meta: [match('naat', EvidenceStrength.strong)]);
    expect(r.assignments.single.tier, AssignmentTier.auto);
    final off = run(List.filled(5, {'naat': 0.6}),
        meta: [match('naat', EvidenceStrength.strong)],
        policy: const ClassificationPolicy(metadataPromotesProvisional: false));
    expect(off.assignments.single.tier, AssignmentTier.provisional);
  });

  test('metadata alone never assigns a category', () {
    final r = run(List.filled(5, {'quran': 0.1}), meta: [match('quran', EvidenceStrength.strong)]);
    expect(r.assignments, isEmpty);
    expect(r.needsReview, isTrue);
  });

  test('metadata conflicting with the model downgrades auto to provisional and is recorded', () {
    final r = run(List.filled(5, {'sad': 0.95}), meta: [match('noha', EvidenceStrength.medium, field: 'title')]);
    expect(r.assignments.single.categoryId, 'sad');
    expect(r.assignments.single.tier, AssignmentTier.provisional);
    expect(r.evidence['conflict'], isNotNull);
  });

  test('weak filename hint does not cause a conflict', () {
    final r = run(List.filled(5, {'sad': 0.95}), meta: [match('noha', EvidenceStrength.weak, field: 'filename')]);
    expect(r.assignments.single.tier, AssignmentTier.auto);
  });

  test('metadata for categories the model does not support is noted, not assigned', () {
    final r = run(List.filled(5, {'quran': 0.95}), meta: [match('manqabat', EvidenceStrength.strong)]);
    expect(r.assignments.map((a) => a.categoryId), ['quran']);
    expect((r.evidence['decisions'] as List).join(), contains('manqabat'));
  });

  test('specific category wins over Other Audio', () {
    final r = run(List.filled(5, {'other': 0.9, 'speech': 0.85}));
    expect(r.assignments.map((a) => a.categoryId), ['speech']);
  });

  test('disabled category → Other Audio', () {
    final r = run(List.filled(5, {'quran': 0.95}), enabled: all.difference({'quran'}));
    expect(r.assignments.single.categoryId, CategoryIds.other);
    expect(r.assignments.single.tier, AssignmentTier.workflow);
  });
}
