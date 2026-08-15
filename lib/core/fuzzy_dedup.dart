import '../models/promo.dart';

/// Fuzzy dedup safety-net (spec B). Cheap pairwise string comparison over a
/// small batch (~40 merchants/week) — classic string distance + a tiny
/// static alias map, no embedding model, no per-pair API call.
///
/// This complements (not replaces) Gemini's own cross-source dedup: it
/// catches near-identical MERCHANT names that slipped through as separate
/// entries, e.g. "KFC" vs "Kentucky Fried Chicken" or "Kopi Kenangan" vs
/// "Kopi Kenangan Indonesia".

/// Normalizes text into a stable key: lowercase, punctuation -> spaces,
/// whitespace collapsed. Used both for fuzzy matching and cross-week dedup
/// keys so they stay consistent.
String normalizeForDedup(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Normalizes a merchant name for fuzzy comparison: same as
/// [normalizeForDedup], plus dropping filler tokens that don't distinguish
/// one brand from another.
String normalizeMerchantName(String name) {
  final tokens = normalizeForDedup(name)
      .split(' ')
      .where((t) => !_stopwords.contains(t))
      .toList();
  return tokens.join(' ');
}

/// Merges promos whose normalized merchant names are the same brand
/// (via alias map or similarity), renaming each to the first-seen
/// representative merchant name. Order is preserved.
List<Promo> dedupeMerchantAliases(
  List<Promo> promos, {
  double tokenThreshold = 0.6,
  double charThreshold = 0.8,
}) {
  final groups = <List<Promo>>[];
  for (final p in promos) {
    final norm = _canonical(p.merchant);
    List<Promo>? matched;
    for (final g in groups) {
      if (_isSameMerchant(norm, _canonical(g.first.merchant),
          tokenThreshold: tokenThreshold, charThreshold: charThreshold)) {
        matched = g;
        break;
      }
    }
    if (matched != null) {
      matched.add(p);
    } else {
      groups.add([p]);
    }
  }

  final result = <Promo>[];
  for (final g in groups) {
    final representative = g.first.merchant;
    for (final p in g) {
      result.add(p.merchant == representative ? p : p.copyWith(merchant: representative));
    }
  }
  return result;
}

bool _isSameMerchant(String a, String b,
    {required double tokenThreshold, required double charThreshold}) {
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b) return true;
  if (_dice(a, b) >= tokenThreshold) return true;
  if (_similarity(a, b) >= charThreshold) return true;
  return false;
}

/// Canonicalizes a normalized merchant name via a small static alias map so
/// acronyms and common name variants collapse to one key ("kfc" and
/// "kentucky fried chicken" both become "kfc").
String _canonical(String merchant) =>
    _aliases[normalizeMerchantName(merchant)] ?? normalizeMerchantName(merchant);

/// Token-set (Sørensen–Dice) coefficient — good for "extra words" variants
/// like "kopi kenangan" vs "kopi kenangan indonesia".
double _dice(String a, String b) {
  final ta = a.split(' ').toSet();
  final tb = b.split(' ').toSet();
  if (ta.isEmpty || tb.isEmpty) return 0.0;
  final overlap = ta.intersection(tb).length;
  return 2 * overlap / (ta.length + tb.length);
}

/// Character-level similarity (1 - normalized Levenshtein distance) —
/// good for typo variants within a single token.
double _similarity(String a, String b) {
  if (a == b) return 1.0;
  final maxLen = a.length > b.length ? a.length : b.length;
  if (maxLen == 0) return 1.0;
  return 1.0 - _levenshtein(a, b) / maxLen;
}

/// Classic Levenshtein distance with a two-row rolling buffer (O(n·m) time,
/// O(m) memory) — fine for names of a few dozen characters.
int _levenshtein(String a, String b) {
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;

  var prev = List<int>.generate(b.length + 1, (i) => i);
  var curr = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    curr[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      final del = curr[j - 1] + 1;
      final ins = prev[j] + 1;
      final sub = prev[j - 1] + cost;
      curr[j] = del < ins ? (del < sub ? del : sub) : (ins < sub ? ins : sub);
    }
    final tmp = prev;
    prev = curr;
    curr = tmp;
  }
  return prev[b.length];
}

/// Filler tokens removed from merchant names before comparison.
const _stopwords = {
  'indonesia', 'indonesian', 'id', 'pt', 'tbk', 'the', 'official', 'store',
  'resto', 'restaurant', 'cafe', 'outlet', 'cabang',
};

/// Known alias/canonical mappings (keys and values both normalized via
/// [normalizeMerchantName]). Acronyms -> full name so "KFC" matches
/// "Kentucky Fried Chicken".
const _aliases = {
  'kfc': 'kfc',
  'kentucky fried chicken': 'kfc',
  'kentucky fried': 'kfc',
  'mcd': 'mcdonalds',
  'mcdonalds': 'mcdonalds',
  'mekdi': 'mcdonalds',
  'jco': 'jco',
  'j co': 'jco',
  'j co donuts': 'jco',
  'j co donuts coffee': 'jco',
  'a w': 'a w',
  'aw': 'a w',
  'hokben': 'hokben',
  'hoka hoka bento': 'hokben',
  'cfc': 'california fried chicken',
  'california fried chicken': 'california fried chicken',
  'ricis': 'richeese factory',
  'richeese factory': 'richeese factory',
  'richeese': 'richeese factory',
};
