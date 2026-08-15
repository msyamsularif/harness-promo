import '../models/promo.dart';
import 'brand_tiers.dart';

/// Composite promo score (spec A). Pure arithmetic over a handful of
/// fields already present on [Promo] — no API calls, no model, O(1) per
/// promo. Runs on the device to rank results deterministically instead of
/// relying solely on Gemini's "most interesting first" prompt ordering.
///
/// Every component is normalized to 0..1 before weighting, so the weights
/// below are relative importance, not absolute magnitudes. Tune them
/// manually after reviewing the weekly output.
const discountWeight = 0.35;
const brandWeight = 0.25;
const buzzWeight = 0.20;
const freshnessWeight = 0.15;
const reliabilityWeight = 0.05;

/// Multiplier applied when a promo has no supporting [Promo.evidenceQuote]
/// (spec F) — such promos are treated as low-confidence.
const lowConfidenceMultiplier = 0.85;

/// Computes the composite score for [promo], in the range 0..1 (bounded by
/// the confidence multiplier).
double compositeScore(Promo promo, {DateTime? today}) {
  final t = today ?? DateTime.now();
  final base = discountWeight * _discountValue(promo) +
      brandWeight * brandTier(promo.merchant) +
      buzzWeight * _buzzValue(promo.buzzScore) +
      freshnessWeight * _freshnessValue(promo.expiryDateIso, t) +
      reliabilityWeight * _reliabilityValue(promo.sourceLink);

  final confidence =
      promo.evidenceQuote.trim().isEmpty ? lowConfidenceMultiplier : 1.0;
  return base * confidence;
}

/// Returns a copy of [promos] sorted by descending composite score. Stable
/// for equal scores, so the original (Gemini) ordering is preserved as a
/// tie-breaker.
List<Promo> rankByScore(List<Promo> promos, {DateTime? today}) {
  final sorted = List<Promo>.of(promos);
  sorted.sort((a, b) {
    final cmp = compositeScore(b, today: today)
        .compareTo(compositeScore(a, today: today));
    return cmp;
  });
  return sorted;
}

/// Normalizes the discount into 0..1 based on [Promo.discountType] and
/// [Promo.discountAmount].
double _discountValue(Promo p) {
  final amount = p.discountAmount;
  switch (p.discountType.trim().toLowerCase()) {
    case 'percentage':
      if (amount == null || amount <= 0) return 0.1;
      return (amount / 100).clamp(0.0, 1.0);
    case 'fixed':
      // Rp100.000 is treated as the practical ceiling for a food/lifestyle
      // discount; anything at or above it scores 1.0.
      if (amount == null || amount <= 0) return 0.1;
      return (amount / 100000).clamp(0.0, 1.0);
    case 'bogo':
      return 0.5;
    default:
      return 0.15;
  }
}

/// Normalizes the buzz score (raw result count) into 0..1. A negative
/// score means "not checked", treated as a neutral 0.5 so unchecked promos
/// are neither rewarded nor punished.
double _buzzValue(int buzzScore) {
  if (buzzScore < 0) return 0.5;
  return (buzzScore / 10).clamp(0.0, 1.0);
}

/// Freshness proxy: a promo with a long remaining validity window is
/// assumed to be newly announced (fresher). Days remaining 0..30 map to
/// 0..1; no known expiry is neutral 0.5.
double _freshnessValue(String expiryIso, DateTime today) {
  final parsed = DateTime.tryParse(expiryIso.trim());
  if (parsed == null) return 0.5;
  final expiry = DateTime(parsed.year, parsed.month, parsed.day);
  final now = DateTime(today.year, today.month, today.day);
  final days = expiry.difference(now).inDays;
  if (days < 0) return 0.0;
  return (days / 30).clamp(0.0, 1.0);
}

/// Source reliability heuristic based on the domain of [sourceLink].
/// Known news/aggregator domains rank highest, social platforms (a direct
/// but less formal source) are mid, everything else gets a neutral value.
double _reliabilityValue(String sourceLink) {
  if (sourceLink.isEmpty) return 0.0;
  final host = Uri.tryParse(sourceLink)?.host.toLowerCase() ?? '';
  if (host.isEmpty) return 0.3;

  for (final reliable in _reliableDomains) {
    if (host.contains(reliable)) return 1.0;
  }
  for (final social in _socialDomains) {
    if (host.contains(social)) return 0.7;
  }
  return 0.5;
}

const _reliableDomains = [
  'detik.com', 'kompas.com', 'tribunnews.com', 'jawapos.com', 'suara.com',
  'idntimes.com', 'tempo.co', 'cnnindonesia.com', 'cnbcindonesia.com',
  'pergikuliner.com', 'zomato.com', 'traveloka.com', 'tokopedia.com',
  'shopee.co.id', 'lazada.co.id', 'blibli.com', 'gojek.com', 'grab.com',
];

const _socialDomains = [
  'instagram.com', 'tiktok.com', 'facebook.com', 'youtube.com', 'youtu.be',
  'x.com', 'twitter.com', 'threads.net',
];
