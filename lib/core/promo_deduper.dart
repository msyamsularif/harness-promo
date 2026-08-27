import '../models/promo.dart';

/// De-duplicates newly extracted promos against historical promos, keyed by
/// a NORMALIZED merchant name only. The goal is to avoid burning API calls
/// (link validation, buzz checks) and Telegram messages on promos from a
/// merchant that was already reported in a previous week and is still
/// running.
///
/// Keying by merchant alone (rather than merchant+discount+expiry) is
/// deliberate: LLM extraction is non-deterministic, so the discount and
/// expiry strings of the "same" promo rarely match exactly between runs.
/// The merchant name is the most stable signal, but even it carries
/// LLM-added context qualifiers (e.g. "Kinokuniya (via BRI)", "Bean Spot
/// (di Alfamart)"), so it is normalized before comparison — see
/// [normalizeMerchant].
///
/// A merchant is considered "seen" only if its historical promo is still
/// valid (expiry today or in the future, or no expiry date at all); a
/// merchant whose historical promo already expired is treated as fresh so a
/// brand-new promo can come through.
class PromoDeduper {
  final Set<String> _seenMerchants;

  PromoDeduper(List<Promo> historicalPromos, {required DateTime today})
      : _seenMerchants = _stillValidMerchants(historicalPromos, today);

  /// Returns only the promos from [promos] whose merchant has not been
  /// seen in history. Also memoizes the new merchants so a merchant does
  /// not appear twice within a single run.
  List<Promo> filterNew(List<Promo> promos) {
    final result = <Promo>[];
    for (final p in promos) {
      if (_seenMerchants.add(normalizeMerchant(p.merchant))) {
        result.add(p);
      }
    }
    return result;
  }

  static Set<String> _stillValidMerchants(List<Promo> promos, DateTime today) {
    final seen = <String>{};
    for (final p in promos) {
      if (_isStillValid(p, today)) {
        seen.add(normalizeMerchant(p.merchant));
      }
    }
    return seen;
  }

  /// Normalizes a merchant name so LLM-added context qualifiers don't break
  /// dedup. Applied to BOTH the historical set and the incoming promos.
  ///
  /// Examples:
  ///   "Kinokuniya (via BRI)"          -> "kinokuniya"
  ///   "Bean Spot (di Alfamart)"       -> "bean spot"
  ///   "Kopi Insight Cabang Agus Salim" -> "kopi insight"
  ///   "Bean Spot Coffee"              -> "bean spot"
  static String normalizeMerchant(String merchant) {
    var m = merchant.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

    // Strip trailing parenthetical qualifiers, repeatedly (handles nesting).
    String prev;
    do {
      prev = m;
      m = m.replaceFirst(RegExp(r'\s*\([^)]*\)\s*$'), '').trim();
    } while (m != prev);

    // Strip a trailing "cabang ..." (branch) qualifier.
    m = m.replaceFirst(RegExp(r'\s+cabang\b.*$'), '').trim();

    // Strip a trailing "via/di/by <partner>" qualifier.
    m = m.replaceFirst(RegExp(r'\s+(via|di|by)\s+[^\s]+$'), '').trim();

    // Normalize a trailing English brand-type suffix so "Bean Spot Coffee"
    // matches "Bean Spot". Deliberately NOT stripping Indonesian "kopi/teh",
    // which are usually integral to the brand name itself.
    m = m.replaceFirst(
        RegExp(r'\s+(coffee|cafe|café)\s*$'), '').trim();

    return m;
  }

  static bool _isStillValid(Promo p, DateTime today) {
    final iso = p.expiryDateIso.trim();
    // No stated expiry date → assume it is still running (can't prove it
    // expired), so the merchant stays "seen".
    if (iso.isEmpty) return true;
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return true;
    final expiry = DateTime(parsed.year, parsed.month, parsed.day);
    return !expiry.isBefore(today);
  }
}
