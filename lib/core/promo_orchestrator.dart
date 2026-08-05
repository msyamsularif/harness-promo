import '../flows/promo_flow.dart';
import '../models/promo.dart';
import '../services/link_validator.dart';
import '../services/serpapi_client.dart';
import '../services/social_buzz_checker.dart';

/// Suggested starting keyword per sub-category (region not included yet).
/// Used as a HINT for Gemini (via the prompt in PromoFlow), not a rigid
/// final query — Gemini decides the actual query via the `searchPromo`
/// tool, and may deviate/expand on this hint as needed.
///
/// Values are kept in Bahasa Indonesia on purpose: they're passed directly
/// as Google search query text, and translating them to English would
/// hurt relevance since we're searching for Indonesian-language promo
/// content.
const categorySearchHints = {
  'Makanan': 'promo makanan terbaru',
  'Minuman': 'promo minuman kopi terbaru',
  'Jajanan': 'promo jajanan snack terbaru',
  'Lifestyle': 'promo lifestyle fashion gadget terbaru',
};

/// Maps each sub-category to its parent category, used to group the
/// Telegram output (F&B vs Lifestyle).
const categoryParentMap = {
  'Makanan': 'F&B',
  'Minuman': 'F&B',
  'Jajanan': 'F&B',
  'Lifestyle': 'Lifestyle',
};

class PromoOrchestrator {
  final PromoFlow promoFlow;
  final bool enableBuzzCheck;
  final bool enableLinkValidation;
  late final SocialBuzzChecker _buzzChecker;
  late final LinkValidator _linkValidator;

  /// [serpapi] here is ONLY used by SocialBuzzChecker (the "how much is
  /// this being talked about" signal) — NOT for the main promo search,
  /// which is already delegated to the `searchPromo` tool inside
  /// [promoFlow].
  PromoOrchestrator({
    required SerpApiClient serpapi,
    required this.promoFlow,
    this.enableBuzzCheck = true,
    this.enableLinkValidation = true,
  }) {
    _buzzChecker = SocialBuzzChecker(serpapi: serpapi);
    _linkValidator = LinkValidator();
  }

  /// Used by the weekly cron job: finds promos for [region] (default
  /// "Jabodetabek"), one `promoFlow.extract()` call per sub-category.
  /// Gemini decides the actual search query via the `searchPromo` tool;
  /// deduplication and the max-10-per-sub-category cap are also handled
  /// by Gemini inside PromoFlow.
  Future<List<Promo>> runDefault({required String region}) async {
    final allPromos = <Promo>[];

    for (final entry in categorySearchHints.entries) {
      final category = entry.key;
      final searchHint = entry.value;

      final promos = await promoFlow.extract(
        category,
        region,
        searchHint: searchHint,
      );
      allPromos.addAll(await _enrich(promos));
    }

    return allPromos;
  }

  /// Used by the bot listener: finds promos for a specific [location] per
  /// the user's on-demand request, for the requested sub-categories only
  /// ([categoryList] null or empty means all sub-categories).
  Future<List<Promo>> runForLocation(
    String location, {
    List<String>? categoryList,
  }) async {
    final targetCategories = (categoryList == null || categoryList.isEmpty)
        ? categorySearchHints.keys.toList()
        : categoryList;

    final allPromos = <Promo>[];

    for (final category in targetCategories) {
      final searchHint = categorySearchHints[category];
      if (searchHint == null) continue; // unknown sub-category, skip

      final promos = await promoFlow.extract(
        category,
        location,
        searchHint: searchHint,
      );
      allPromos.addAll(await _enrich(promos));
    }

    return allPromos;
  }

  /// Runs link validation (drop unreachable sources) and buzz checking
  /// (both optional, both parallelized) on a batch of promos.
  Future<List<Promo>> _enrich(List<Promo> promos) async {
    var result = promos;

    if (enableLinkValidation) {
      result = await _linkValidator.filterValid(result);
    }

    if (enableBuzzCheck && result.isNotEmpty) {
      result = await Future.wait(result.map(_buzzChecker.checkBuzz));
    }

    return result;
  }
}
