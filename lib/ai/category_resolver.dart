import 'dart:convert';

import '../core/models/category.dart';
import '../core/models/track.dart';
import 'metadata_rules.dart';
import 'model_manifest.dart';

/// Workflow policy knobs. Confidence thresholds are *not* here: they come
/// from the model's evaluation (manifest), never from app defaults.
class ClassificationPolicy {
  const ClassificationPolicy({
    this.maxLabels = 3,
    this.metadataPromotesProvisional = true,
    this.windowAgreementMin = 0.5,
    this.silenceDb = -50,
    this.minAudibleFraction = 0.5,
  });

  /// Upper bound on categories per track for multi-label models.
  final int maxLabels;

  /// A *strong* metadata match (embedded genre tag) for a category the model
  /// already rates at least provisional promotes it to automatic.
  final bool metadataPromotesProvisional;

  /// Minimum fraction of audible windows that must individually reach the
  /// provisional threshold for a category to be assigned automatically.
  /// Below this the recording is treated as mixed and capped at provisional.
  final double windowAgreementMin;

  /// Windows quieter than this (dBFS RMS) are ignored as silence.
  final double silenceDb;

  /// If fewer audible windows than this fraction remain, the track goes to
  /// Needs Review instead of being classified on too little audio.
  final double minAudibleFraction;

  Map<String, Object?> toJson() => {
        'maxLabels': maxLabels,
        'metadataPromotesProvisional': metadataPromotesProvisional,
        'windowAgreementMin': windowAgreementMin,
        'silenceDb': silenceDb,
        'minAudibleFraction': minAudibleFraction,
      };

  factory ClassificationPolicy.fromJson(Map<String, Object?> j) => ClassificationPolicy(
        maxLabels: (j['maxLabels'] as num?)?.toInt() ?? 3,
        metadataPromotesProvisional: (j['metadataPromotesProvisional'] as bool?) ?? true,
        windowAgreementMin: (j['windowAgreementMin'] as num?)?.toDouble() ?? 0.5,
        silenceDb: (j['silenceDb'] as num?)?.toDouble() ?? -50,
        minAudibleFraction: (j['minAudibleFraction'] as num?)?.toDouble() ?? 0.5,
      );

  ClassificationPolicy copyWith({int? maxLabels, bool? metadataPromotesProvisional}) => ClassificationPolicy(
        maxLabels: maxLabels ?? this.maxLabels,
        metadataPromotesProvisional: metadataPromotesProvisional ?? this.metadataPromotesProvisional,
        windowAgreementMin: windowAgreementMin,
        silenceDb: silenceDb,
        minAudibleFraction: minAudibleFraction,
      );
}

class Assignment {
  const Assignment(this.categoryId, this.confidence, this.tier);

  final String categoryId;
  final double? confidence;
  final String tier;
}

class Resolution {
  const Resolution({
    required this.assignments,
    required this.scores,
    required this.needsReview,
    required this.evidence,
    this.reviewReason,
  });

  final List<Assignment> assignments;

  /// Aggregated calibrated model score per model label.
  final Map<String, double> scores;
  final bool needsReview;
  final String? reviewReason;

  /// Everything needed to explain the decision to the user later.
  final Map<String, Object?> evidence;

  String get evidenceJson => jsonEncode(evidence);
}

/// Combines audio-model predictions with metadata evidence.
///
/// Resolution policy (v1):
///  1. Ignore silent windows; with too little audible audio → Needs Review.
///  2. Average calibrated scores over audible windows.
///  3. Per label: score ≥ auto threshold → automatic; ≥ provisional → provisional.
///     Single-label models keep only the arg-max label.
///  4. Mixed recordings: if too few windows individually support a label,
///     cap it at provisional.
///  5. Metadata agreement (strong, i.e. genre tag) may promote provisional →
///     automatic. Metadata never creates an assignment on its own.
///  6. Conflict: medium/strong metadata names a category the model supports
///     but scores below provisional → automatic assignments are downgraded
///     to provisional and the conflict is recorded.
///  7. Specific categories win over "Other Audio"; at most `maxLabels` kept.
///  8. Disabled categories are dropped; if that removes everything the track
///     goes to Other Audio.
///  9. No assignment → Needs Review, with the best guess and metadata hints.
class CategoryResolver {
  const CategoryResolver();

  static const policyVersion = 1;

  Resolution resolve({
    required ModelManifest manifest,
    required List<List<double>> windowScores,
    required List<double> windowLevelsDb,
    required List<MetadataMatch> metadata,
    required Set<String> enabledCategoryIds,
    ClassificationPolicy policy = const ClassificationPolicy(),
  }) {
    final decisions = <String>[];
    final labels = manifest.labels;
    final audibleIdx = [
      for (var i = 0; i < windowScores.length; i++)
        if (i >= windowLevelsDb.length || windowLevelsDb[i] > policy.silenceDb) i,
    ];
    final evidence = <String, Object?>{
      'policy_version': policyVersion,
      'model_id': manifest.modelId,
      'model_version': manifest.modelVersion,
      'windows_total': windowScores.length,
      'windows_audible': audibleIdx.length,
      'metadata': [for (final m in metadata) m.toJson()],
      'decisions': decisions,
    };

    final audibleFraction = windowScores.isEmpty ? 0.0 : audibleIdx.length / windowScores.length;
    if (audibleIdx.isEmpty || audibleFraction < policy.minAudibleFraction) {
      decisions.add('insufficient audible audio (${audibleIdx.length}/${windowScores.length} windows)');
      return Resolution(
        assignments: const [],
        scores: const {},
        needsReview: true,
        reviewReason: 'Too little audible audio to classify',
        evidence: evidence,
      );
    }

    final scores = <String, double>{};
    for (final l in labels) {
      var sum = 0.0;
      for (final i in audibleIdx) {
        sum += windowScores[i][l.index];
      }
      scores[l.categoryId] = sum / audibleIdx.length;
    }
    evidence['scores'] = scores;

    // 3. thresholds from the evaluated manifest
    var candidates = <String, String>{}; // category -> tier
    for (final l in labels) {
      final s = scores[l.categoryId]!;
      if (s >= l.autoThreshold) {
        candidates[l.categoryId] = AssignmentTier.auto;
      } else if (s >= l.provisionalThreshold) {
        candidates[l.categoryId] = AssignmentTier.provisional;
      }
    }
    if (!manifest.multiLabel && candidates.length > 1) {
      final top = candidates.keys.reduce((a, b) => scores[a]! >= scores[b]! ? a : b);
      candidates = {top: candidates[top]!};
    }

    // 4. window agreement
    final agreement = <String, double>{};
    for (final l in labels) {
      if (!candidates.containsKey(l.categoryId)) continue;
      final support = audibleIdx.where((i) => windowScores[i][l.index] >= l.provisionalThreshold).length;
      final frac = support / audibleIdx.length;
      agreement[l.categoryId] = frac;
      if (frac < policy.windowAgreementMin && candidates[l.categoryId] == AssignmentTier.auto) {
        candidates[l.categoryId] = AssignmentTier.provisional;
        decisions.add('${l.categoryId}: mixed recording (window agreement ${frac.toStringAsFixed(2)}) → provisional');
      }
    }
    evidence['window_agreement'] = agreement;

    // 5/6. metadata evidence
    final modelLabels = {for (final l in labels) l.categoryId};
    final metaByCat = {for (final m in metadata) m.categoryId: m};
    for (final entry in candidates.entries.toList()) {
      final m = metaByCat[entry.key];
      if (m != null &&
          m.strength == EvidenceStrength.strong &&
          entry.value == AssignmentTier.provisional &&
          policy.metadataPromotesProvisional &&
          (agreement[entry.key] ?? 1) >= policy.windowAgreementMin) {
        candidates[entry.key] = AssignmentTier.auto;
        decisions.add('${entry.key}: provisional promoted by ${m.field} tag "${m.keyword}"');
      }
    }
    final conflicts = [
      for (final m in metadata)
        if (m.strength != EvidenceStrength.weak &&
            modelLabels.contains(m.categoryId) &&
            !candidates.containsKey(m.categoryId))
          m,
    ];
    if (conflicts.isNotEmpty && candidates.isNotEmpty) {
      for (final k in candidates.keys.toList()) {
        if (candidates[k] == AssignmentTier.auto) candidates[k] = AssignmentTier.provisional;
      }
      decisions.add('metadata suggests ${conflicts.map((c) => c.categoryId).join(', ')} but audio model '
          'does not; automatic assignments downgraded to provisional');
      evidence['conflict'] = [for (final c in conflicts) c.toJson()];
    }
    final unverifiable = [
      for (final m in metadata)
        if (!modelLabels.contains(m.categoryId)) m.categoryId,
    ];
    if (unverifiable.isNotEmpty) {
      decisions.add('metadata mentions ${unverifiable.join(', ')}, which the bundled model does not support; '
          'not assigned');
    }

    // 7. specific beats "other"; cap count
    if (candidates.length > 1) candidates.remove(CategoryIds.other);
    var ordered = candidates.keys.toList()..sort((a, b) => scores[b]!.compareTo(scores[a]!));
    if (manifest.multiLabel && ordered.length > policy.maxLabels) {
      decisions.add('kept top ${policy.maxLabels} of ${ordered.length} categories');
      ordered = ordered.take(policy.maxLabels).toList();
    }

    // 8. disabled categories
    final before = ordered.length;
    ordered = ordered.where(enabledCategoryIds.contains).toList();
    final assignments = [for (final c in ordered) Assignment(c, scores[c], candidates[c]!)];
    if (assignments.isEmpty && before > 0) {
      decisions.add('all predicted categories are disabled');
      if (enabledCategoryIds.contains(CategoryIds.other)) {
        return Resolution(
          assignments: const [Assignment(CategoryIds.other, null, AssignmentTier.workflow)],
          scores: scores,
          needsReview: false,
          evidence: evidence,
        );
      }
    }

    // 9. nothing confident
    if (assignments.isEmpty) {
      final best = scores.entries.reduce((a, b) => a.value >= b.value ? a : b);
      evidence['best_guess'] = {'category': best.key, 'score': best.value};
      decisions.add('no category reached its provisional threshold → Needs Review');
      return Resolution(
        assignments: const [],
        scores: scores,
        needsReview: true,
        reviewReason: 'Low confidence',
        evidence: evidence,
      );
    }
    return Resolution(assignments: assignments, scores: scores, needsReview: false, evidence: evidence);
  }
}
