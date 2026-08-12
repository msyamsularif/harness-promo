import '../models/promo.dart';
import 'serpapi_client.dart';

/// Checks how much a promo/brand is being talked about on social media
/// (Instagram, TikTok, Facebook, YouTube, X, Threads), via SerpApi.
///
/// DESIGN NOTE: this deliberately uses ONE combined query (site: OR site:
/// OR ...) per promo, instead of 6 separate queries per platform. This is
/// purely a cost decision — with up to 40 promos per week (4 sub-categories
/// x 10 promos), 6 separate queries per promo would mean 240 extra SerpApi
/// calls per week. A single combined query is enough to give a "how much
/// buzz" signal and "which platforms", just not an exact count per platform.
/// If you need an exact per-platform breakdown later, that requires
/// upgrading to separate queries (and automatically 6x the SerpApi cost).
class SocialBuzzChecker {
  final SearchService _search;

  SocialBuzzChecker({required SearchService search}) : _search = search;

  static const _platformHosts = {
    'instagram.com': 'Instagram',
    'tiktok.com': 'TikTok',
    'facebook.com': 'Facebook',
    'youtube.com': 'YouTube',
    'youtu.be': 'YouTube',
    'x.com': 'X',
    'twitter.com': 'X',
    'threads.net': 'Threads',
  };

  /// Checks buzz for a single [promo], returning a copy with buzz data
  /// filled in. The query is built from the merchant name + a generic
  /// "promo" keyword — NOT the exact promoTitle text, because Gemini's
  /// extracted summary rarely matches the exact wording of real social
  /// media captions. So this is a signal for how much the BRAND is being
  /// talked about in relation to promos, not a confirmation that this
  /// exact specific promo is the one being discussed.
  Future<Promo> checkBuzz(Promo promo) async {
    final query =
        '"${promo.merchant}" promo (site:instagram.com OR site:tiktok.com OR '
        'site:facebook.com OR site:youtube.com OR site:x.com OR '
        'site:twitter.com OR site:threads.net)';

    try {
      final results = await _search.search(query);

      final platforms = <String>{};
      for (final r in results) {
        final host = Uri.tryParse(r.link)?.host.replaceFirst('www.', '') ?? '';
        for (final entry in _platformHosts.entries) {
          if (host.contains(entry.key)) {
            platforms.add(entry.value);
            break;
          }
        }
      }

      final score = results.length;
      return promo.copyWithBuzz(
        buzzScore: score,
        buzzLabel: _labelFor(score),
        buzzPlatforms: platforms.toList()..sort(),
      );
    } catch (e) {
      // If the buzz check fails (e.g. SerpApi rate limit), don't fail the
      // whole extraction process — just mark it as unknown and move on.
      return promo.copyWithBuzz(
        buzzScore: -1,
        buzzLabel: 'Tidak diketahui',
        buzzPlatforms: const [],
      );
    }
  }

  // Labels are kept in Indonesian since they're shown directly in the
  // Telegram output.
  String _labelFor(int score) {
    if (score >= 8) return '🔥 Sangat ramai dibicarakan';
    if (score >= 4) return '📢 Cukup ramai dibicarakan';
    if (score >= 1) return '💬 Mulai dibicarakan';
    return '🤫 Belum ramai dibicarakan';
  }
}
