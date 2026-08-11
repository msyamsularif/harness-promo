import 'dart:io';

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
  ///
  /// Failures are ISOLATED per sub-category: if one sub-category's
  /// extraction throws (e.g. Gemini rate limit, max-turns abort), it is
  /// logged and skipped so the remaining sub-categories are still
  /// delivered. Only if EVERY sub-category fails does this rethrow, so
  /// the caller sends an error notification instead of a misleading
  /// "no promos found" summary.
  Future<List<Promo>> runDefault({required String region}) async {
    return _runForCategories(categorySearchHints, region);
  }

  /// Used by the bot listener: finds promos for a specific [location] per
  /// the user's on-demand request, for the requested sub-categories only
  /// ([categoryList] null or empty means all sub-categories).
  ///
  /// Same per-sub-category failure isolation as [runDefault].
  Future<List<Promo>> runForLocation(
    String location, {
    List<String>? categoryList,
  }) async {
    final targetCategories = (categoryList == null || categoryList.isEmpty)
        ? categorySearchHints.keys.toList()
        : categoryList;

    final hints = <String, String>{
      for (final category in targetCategories)
        if (categorySearchHints.containsKey(category))
          category: categorySearchHints[category]!,
    };

    return _runForCategories(hints, location);
  }

  /// Shared loop behind [runDefault] and [runForLocation]: extracts and
  /// enriches one sub-category at a time, isolating failures per
  /// sub-category (see [runDefault]'s docs). Rethrows when all of the
  /// requested sub-categories failed.
  Future<List<Promo>> _runForCategories(
    Map<String, String> hintsByCategory,
    String region,
  ) async {
    final allPromos = <Promo>[];
    final failures = <String>[];

    for (final entry in hintsByCategory.entries) {
      final category = entry.key;
      final searchHint = entry.value;

      try {
        final promos = await promoFlow.extract(
          category,
          region,
          searchHint: searchHint,
        );
        allPromos.addAll(await _enrich(promos));
      } catch (e) {
        stderr.writeln(
            '[orchestrator] Extraction failed for category "$category", skipping: $e');
        failures.add(category);
      }
    }

    if (failures.isNotEmpty && failures.length == hintsByCategory.length) {
      throw Exception(
          'All ${failures.length} sub-category extractions failed; nothing to deliver.');
    }

    return allPromos;
  }

  /// Runs link validation (drop unreachable sources) and buzz checking
  /// (both optional, both parallelized) on a batch of promos.
  ///
  /// Buzz is checked ONCE per unique merchant and the result is shared by
  /// all of that merchant's promos: the buzz query is merchant-based, so
  /// checking each promo individually would return identical results while
  /// burning extra SerpApi quota.
  Future<List<Promo>> _enrich(List<Promo> promos) async {
    var result = promos;

    if (enableLinkValidation) {
      result = await _linkValidator.filterValid(result);
    }

    if (enableBuzzCheck && result.isNotEmpty) {
      final representativeByMerchant = <String, Promo>{};
      for (final p in result) {
        representativeByMerchant.putIfAbsent(
            merchantGroupKey(p.merchant), () => p);
      }

      final checked = await Future.wait(
        representativeByMerchant.entries.map(
          (entry) async =>
              MapEntry(entry.key, await _buzzChecker.checkBuzz(entry.value)),
        ),
      );
      final buzzByMerchant = {for (final e in checked) e.key: e.value};

      result = result.map((p) {
        final buzz = buzzByMerchant[merchantGroupKey(p.merchant)]!;
        return p.copyWithBuzz(
          buzzScore: buzz.buzzScore,
          buzzLabel: buzz.buzzLabel,
          buzzPlatforms: buzz.buzzPlatforms,
        );
      }).toList();
    }

    return result;
  }
}
