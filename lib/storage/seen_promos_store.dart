import 'dart:convert';
import 'dart:io';

import '../core/fuzzy_dedup.dart';
import '../models/promo.dart';

/// Stable dedup key for a promo: normalized merchant + normalized title.
/// Used as the map key in `seen_promos.json` so a still-running promo from
/// a previous week isn't re-sent.
String promoDedupKey(Promo p) =>
    '${normalizeForDedup(p.merchant)}|${normalizeForDedup(p.promoTitle)}';

/// Cross-week dedup (spec C). Remembers which promos were already shown so
/// a still-running promo isn't re-sent the next week. Backed by a single
/// small JSON file, NOT the full weekly history — entries are pruned on
/// every load (expired, or no-expiry entries older than a rolling window)
/// so the file stays small and bounded on the device.
///
/// NOTE: the weekly cron and the bot listener are separate processes and
/// may read/write this file concurrently. For this device-scale (a few
/// hundred entries, one write per run) last-writer-wins is acceptable.
class SeenPromosStore {
  final File _file;
  final Map<String, _SeenEntry> _seen = {};
  bool _loaded = false;
  bool _dirty = false;

  /// Rolling window (in days) after which a no-expiry entry is dropped so
  /// the file can't grow unbounded.
  static const maxNoExpiryAgeDays = 8 * 7;

  SeenPromosStore({required String outputDir})
      : _file = File('$outputDir/seen_promos.json');

  /// Filters [promos] down to those not already seen (and not expired),
  /// recording the new ones in memory. Call [save] afterwards to persist.
  /// [today] is used to prune expired entries on load.
  List<Promo> filterNew(List<Promo> promos, {DateTime? today}) {
    final t = today ?? DateTime.now();
    _ensureLoaded(t);
    final fresh = <Promo>[];
    for (final p in promos) {
      final key = promoDedupKey(p);
      if (_seen.containsKey(key)) continue;
      _seen[key] = _SeenEntry(expiry: p.expiryDateIso.trim(), firstSeen: _iso(t));
      _dirty = true;
      fresh.add(p);
    }
    return fresh;
  }

  /// Persists the (pruned) seen map. No-op if nothing was loaded/changed.
  Future<void> save() async {
    if (!_loaded || !_dirty) return;
    await _file.parent.create(recursive: true);
    final payload = <String, dynamic>{
      for (final e in _seen.entries)
        e.key: {'expiry': e.value.expiry, 'first_seen': e.value.firstSeen},
    };
    await _file.writeAsString(jsonEncode(payload));
    _dirty = false;
  }

  void _ensureLoaded(DateTime today) {
    if (_loaded) return;
    _loaded = true;
    if (!_file.existsSync()) return;

    var pruned = false;
    try {
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) return;
      decoded.forEach((key, value) {
        final m = value is Map<String, dynamic> ? value : <String, dynamic>{};
        final expiry = m['expiry']?.toString() ?? '';
        final firstSeen = m['first_seen']?.toString() ?? '';
        if (_isExpired(expiry, firstSeen, today)) {
          pruned = true;
          return;
        }
        _seen[key] = _SeenEntry(expiry: expiry, firstSeen: firstSeen);
      });
    } catch (e) {
      stderr.writeln('[seen_promos] Failed to load ${_file.path}: $e');
      _seen.clear();
    }
    if (pruned) _dirty = true;
  }

  bool _isExpired(String expiryIso, String firstSeenIso, DateTime today) {
    final now = DateTime(today.year, today.month, today.day);
    final expiry = DateTime.tryParse(expiryIso);
    if (expiry != null) {
      final e = DateTime(expiry.year, expiry.month, expiry.day);
      return e.isBefore(now);
    }
    // No expiry date: keep for the rolling window, then prune.
    final firstSeen = DateTime.tryParse(firstSeenIso);
    if (firstSeen != null) {
      return firstSeen.isBefore(
          today.subtract(const Duration(days: maxNoExpiryAgeDays)));
    }
    return false;
  }

  static String _iso(DateTime d) => d.toIso8601String().split('T').first;
}

class _SeenEntry {
  final String expiry;
  final String firstSeen;
  _SeenEntry({required this.expiry, required this.firstSeen});
}
