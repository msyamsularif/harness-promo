import 'dart:convert';
import 'dart:io';

/// One cached buzz result for a single merchant.
class BuzzCacheEntry {
  final int score;
  final String label;
  final List<String> platforms;
  final DateTime checkedAt;

  BuzzCacheEntry({
    required this.score,
    required this.label,
    required this.platforms,
    required this.checkedAt,
  });

  factory BuzzCacheEntry.fromJson(Map<String, dynamic> json) => BuzzCacheEntry(
        score: (json['score'] as num?)?.toInt() ?? -1,
        label: json['label']?.toString() ?? '',
        platforms: (json['platforms'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        checkedAt: DateTime.tryParse(json['checked_at']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  Map<String, dynamic> toJson() => {
        'score': score,
        'label': label,
        'platforms': platforms,
        'checked_at': checkedAt.toIso8601String(),
      };
}

/// Persistent cache of merchant buzz results, keyed by `merchantKey`.
///
/// Buzz is merchant-level (not promo-level) and changes slowly, so a
/// merchant checked recently does not need a fresh search-provider call
/// every single week — this is one of the biggest sources of repeated
/// API cost in the pipeline. Results older than [ttl] are considered
/// stale and re-checked.
class BuzzCache {
  final String filePath;

  /// A cached buzz result stays valid for 14 days, i.e. a merchant is
  /// re-checked roughly every other week.
  static const ttl = Duration(days: 14);

  final Map<String, BuzzCacheEntry> _entries;

  BuzzCache({required String directoryPath})
      : filePath = '$directoryPath/buzz_cache.json',
        _entries = _loadFile('$directoryPath/buzz_cache.json');

  /// Returns the cached entry for [merchantKey] if present and fresh,
  /// otherwise null (meaning a real check is needed).
  BuzzCacheEntry? get(String merchantKey) {
    final entry = _entries[merchantKey];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.checkedAt) > ttl) return null;
    return entry;
  }

  void put(String merchantKey, BuzzCacheEntry entry) {
    _entries[merchantKey] = entry;
  }

  /// Persists the cache to disk. Failures are logged but not fatal —
  /// losing the cache only means some extra API calls next run.
  Future<void> save() async {
    try {
      final file = File(filePath);
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      final payload = {
        for (final e in _entries.entries) e.key: e.value.toJson(),
      };
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
      );
    } catch (e) {
      stderr.writeln('[buzz_cache] Failed to save: $e');
    }
  }

  static Map<String, BuzzCacheEntry> _loadFile(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return {};
      final content = file.readAsStringSync();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return {
        for (final e in json.entries)
          if (e.value is Map<String, dynamic>)
            e.key: BuzzCacheEntry.fromJson(e.value as Map<String, dynamic>),
      };
    } catch (e) {
      stderr.writeln('[buzz_cache] Failed to load: $e');
      return {};
    }
  }
}
