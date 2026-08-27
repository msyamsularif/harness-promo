import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/promo.dart';

/// Checks whether a promo's source link is actually reachable, so broken
/// or dead links don't get shown to the user. Promos whose link fails
/// validation are dropped entirely (not just the link — the whole promo),
/// per the requirement that unreachable sources shouldn't be surfaced.
class LinkValidator {
  final http.Client _http;

  // Per-run cache: normalized URL -> reachability result.
  final Map<String, bool> _cache = {};

  static const _timeout = Duration(seconds: 8);

  // A browser-like User-Agent reduces false negatives from sites that
  // block requests with no/unusual User-Agent headers.
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0 Safari/537.36';

  LinkValidator({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  /// Filters [promos], keeping only those whose [Promo.sourceLink] is
  /// reachable. Checks run in PARALLEL to avoid a linear slowdown per item.
  /// Duplicate source links within the same batch are checked only once.
  Future<List<Promo>> filterValid(List<Promo> promos) async {
    if (promos.isEmpty) return promos;

    var checksPerformed = 0;
    var cacheHits = 0;

    final checks = await Future.wait(
      promos.map((p) async {
        final normalized = _normalizeUrl(p.sourceLink);
        if (_cache.containsKey(normalized)) {
          cacheHits++;
          return MapEntry(p, _cache[normalized]!);
        }
        checksPerformed++;
        final result = await _checkReachability(p.sourceLink);
        _cache[normalized] = result;
        return MapEntry(p, result);
      }),
    );

    final valid =
        checks.where((entry) => entry.value).map((entry) => entry.key).toList();

    stderr.writeln('[link_validator] ${promos.length} links, '
        '$checksPerformed HTTP checks performed, '
        '$cacheHits cache hits, '
        '${valid.length} valid');

    return valid;
  }

  /// Public entry point that reuses the per-run cache when called directly.
  Future<bool> isReachable(String url) async {
    final normalized = _normalizeUrl(url);
    if (_cache.containsKey(normalized)) {
      return _cache[normalized]!;
    }
    final result = await _checkReachability(url);
    _cache[normalized] = result;
    return result;
  }

  /// Performs the actual HTTP reachability check. Tries HEAD first (cheaper),
  /// falling back to GET if HEAD fails outright or returns a non-acceptable
  /// status — some servers reject HEAD but serve GET just fine.
  Future<bool> _checkReachability(String url) async {
    if (url.isEmpty) return false;

    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return false;

    final headers = {'User-Agent': _userAgent};

    try {
      final headResponse =
          await _http.head(uri, headers: headers).timeout(_timeout);
      if (_isAcceptable(headResponse.statusCode)) return true;
    } catch (_) {
      // HEAD failed outright — fall through and try GET below.
    }

    try {
      final getResponse =
          await _http.get(uri, headers: headers).timeout(_timeout);
      return _isAcceptable(getResponse.statusCode);
    } catch (_) {
      return false;
    }
  }

  /// Normalizes a URL for cache keys and de-duplication.
  String _normalizeUrl(String url) => url.trim().replaceAll(RegExp(r'/$'), '');

  /// 2xx/3xx are clearly fine. 403 is treated as reachable too, since many
  /// sites (especially social platforms) block non-browser requests with
  /// 403 even though the underlying content genuinely exists.
  bool _isAcceptable(int statusCode) {
    if (statusCode >= 200 && statusCode < 400) return true;
    if (statusCode == 403) return true;
    return false;
  }

  void close() => _http.close();
}
