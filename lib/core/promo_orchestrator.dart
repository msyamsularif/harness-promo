import 'dart:io';

import '../flows/promo_flow.dart';
import '../models/promo.dart';
import '../services/link_validator.dart';
import '../services/serpapi_client.dart';
import '../services/social_buzz_checker.dart';
import '../storage/buzz_cache.dart';
import '../storage/promo_storage.dart';
import 'promo_constants.dart';
import 'promo_deduper.dart';

class PromoOrchestrator {
  final PromoFlow promoFlow;
  final PromoStorage? storage;
  final BuzzCache? buzzCache;
  final bool enableBuzzCheck;
  final bool enableLinkValidation;

  /// Caps the number of merchants buzz-checked per sub-category
  /// (0 = no cap). See [PromoOrchestrator] constructor docs.
  final int buzzMaxMerchants;

  /// Enables the batched LLM dedup pass (layer 2) after the deterministic
  /// merchant-key dedup. Costs one extra Gemini call per run.
  final bool enableLlmDedup;

  late final SocialBuzzChecker _buzzChecker;
  late final LinkValidator _linkValidator;

  /// [search] is ONLY used by SocialBuzzChecker (the "how much is this
  /// being talked about" signal) — NOT for the main promo search, which
  /// is already delegated to the `searchPromo` tool inside [promoFlow].
  ///
  /// [storage] is used to load previous weeks' promos for cross-week
  /// de-duplication. When null, de-duplication is skipped.
  ///
  /// [buzzCache] is used to reuse buzz results from recent runs for the
  /// same merchant. When null, every merchant is re-checked.
  ///
  /// [buzzMaxMerchants] limits how many merchants get a buzz check per
  /// sub-category (0 = unlimited). Merchants beyond the cap simply don't
  /// show a buzz line in the Telegram output.
  PromoOrchestrator({
    required SearchService search,
    required this.promoFlow,
    this.storage,
    this.buzzCache,
    this.enableBuzzCheck = true,
    this.enableLinkValidation = true,
    this.buzzMaxMerchants = 0,
    this.enableLlmDedup = false,
  }) {
    _buzzChecker = SocialBuzzChecker(search: search);
    _linkValidator = LinkValidator();
  }

  /// Used by the weekly cron job: finds promos for [region] (default
  /// "Jabodetabek"), one `promoFlow.extract()` call per sub-category.
  /// Gemini decides the actual search query via the `searchPromo` tool;
  /// deduplication and the max-10-per-sub-category cap are also handled
  /// by Gemini inside PromoFlow.
  ///
  /// [onCategoryComplete] (optional) is awaited after each sub-category is
  /// enriched, so the caller can notify per-category (e.g. send a separate
  /// Telegram message per category as soon as it's ready).
  ///
  /// Failures are ISOLATED per sub-category: if one sub-category's
  /// extraction throws (e.g. Gemini rate limit, max-turns abort), it is
  /// logged and skipped so the remaining sub-categories are still
  /// delivered. Only if EVERY sub-category fails does this rethrow, so
  /// the caller sends an error notification instead of a misleading
  /// "no promos found" summary.
  Future<List<Promo>> runDefault({
    required String region,
    Future<void> Function(String category, List<Promo> promos)?
        onCategoryComplete,
  }) async {
    return _runForCategories(
      categorySearchHints,
      region,
      onCategoryComplete: onCategoryComplete,
    );
  }

  /// Used by the bot listener: finds promos for a specific [location] per
  /// the user's on-demand request, for the requested sub-categories only
  /// ([categoryList] null or empty means all sub-categories).
  ///
  /// Same per-sub-category failure isolation as [runDefault].
  Future<List<Promo>> runForLocation(
    String location, {
    List<String>? categoryList,
    Future<void> Function(String category, List<Promo> promos)?
        onCategoryComplete,
  }) async {
    final targetCategories = (categoryList == null || categoryList.isEmpty)
        ? categorySearchHints.keys.toList()
        : categoryList;

    final hints = <String, String>{
      for (final category in targetCategories)
        if (categorySearchHints.containsKey(category))
          category: categorySearchHints[category]!,
    };

    return _runForCategories(
      hints,
      location,
      onCategoryComplete: onCategoryComplete,
    );
  }

  /// Shared loop behind [runDefault] and [runForLocation]. Processes ONE
  /// sub-category at a time end-to-end (extract → dedup → enrich → notify)
  /// so a failure in one category never blocks the others.
  ///
  /// Dedup is two-layered and runs per category:
  ///   1. Deterministic merchant-key dedup (free, no API call).
  ///   2. Optional LLM dedup (`enableLlmDedup`) comparing this category's
  ///      new promos against still-valid historical promos of the SAME
  ///      category — catches fuzzy matches that key-normalization misses.
  ///
  /// Rethrows when all of the requested sub-categories failed.
  Future<List<Promo>> _runForCategories(
    Map<String, String> hintsByCategory,
    String region, {
    Future<void> Function(String category, List<Promo> promos)?
        onCategoryComplete,
  }) async {
    final failures = <String>[];
    final allPromos = <Promo>[];

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final historicalPromos =
        storage != null ? await storage!.loadLatestWeekly() : <Promo>[];
    final deduper = PromoDeduper(historicalPromos, today: today);

    if (historicalPromos.isNotEmpty) {
      stderr.writeln('[orchestrator] loaded ${historicalPromos.length} '
          'historical promos for cross-week deduplication');
    }

    for (final entry in hintsByCategory.entries) {
      final category = entry.key;
      final searchHint = entry.value;

      List<Promo> enriched;
      try {
        final promos = await promoFlow.extract(
          category,
          region,
          searchHint: searchHint,
        );

        // Layer 1: deterministic merchant-key dedup.
        var newPromos = deduper.filterNew(promos);
        final keyDedupCount = promos.length - newPromos.length;
        if (keyDedupCount > 0) {
          stderr.writeln('[orchestrator] category "$category": '
              '$keyDedupCount promos skipped by key dedup');
        }

        // Layer 2 (optional): LLM dedup against this category's history.
        if (enableLlmDedup && newPromos.isNotEmpty) {
          final categoryHistory = historicalPromos
              .where((p) => p.category == category)
              .toList();
          if (categoryHistory.isNotEmpty) {
            final dupIndices = await promoFlow.findDuplicateIndices(
              newPromos: newPromos,
              historicalPromos: categoryHistory,
              category: category,
            );
            if (dupIndices.isNotEmpty) {
              newPromos = [
                for (var i = 0; i < newPromos.length; i++)
                  if (!dupIndices.contains(i)) newPromos[i],
              ];
              stderr.writeln('[orchestrator] category "$category": '
                  '${dupIndices.length} promos skipped by LLM dedup');
            }
          }
        }

        enriched = await _enrich(newPromos);
        allPromos.addAll(enriched);
      } catch (e) {
        stderr.writeln(
            '[orchestrator] Extraction failed for category "$category", skipping: $e');
        failures.add(category);
        continue;
      }

      if (onCategoryComplete != null) {
        try {
          await onCategoryComplete(category, enriched);
        } catch (e) {
          // A notification failure (e.g. Telegram hiccup) must not affect
          // the extraction accounting for the remaining categories.
          stderr.writeln(
              '[orchestrator] Category notification failed for "$category": $e');
        }
      }
    }

    if (failures.isNotEmpty && failures.length == hintsByCategory.length) {
      throw Exception(
          'All ${failures.length} sub-category extractions failed; nothing to deliver.');
    }

    await buzzCache?.save();

    return allPromos;
  }

  /// Enriches a batch of promos in three stages:
  ///
  /// 1. Drop promos whose expiry date has already passed (cheap, no
  ///    external calls).
  /// 2. Link validation (drop unreachable sources) — optional.
  /// 3. Social buzz check — optional, and only run for promos that
  ///    survived link validation, so we don't waste search-provider quota
  ///    on promos that will be discarded anyway.
  ///
  /// Buzz is checked ONCE per unique merchant and the result is shared by
  /// all of that merchant's promos: the buzz query is merchant-based, so
  /// checking each promo individually would return identical results while
  /// burning extra SerpApi quota.
  Future<List<Promo>> _enrich(List<Promo> promos) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // 1. Expired promo filter.
    var result = _dropExpired(promos, today);
    final expiredCount = promos.length - result.length;

    // 2. Validate source links.
    if (enableLinkValidation) {
      result = await _linkValidator.filterValid(result);
    }
    final invalidLinkCount = promos.length - expiredCount - result.length;

    // 3. Check social buzz only for promos that survived link validation.
    if (enableBuzzCheck && result.isNotEmpty) {
      // One representative promo per unique merchant, in Gemini's
      // most-interesting-first order.
      final representativeByMerchant = <String, Promo>{};
      for (final p in result) {
        representativeByMerchant.putIfAbsent(p.merchantKey, () => p);
      }

      var merchantEntries = representativeByMerchant.entries.toList();
      if (buzzMaxMerchants > 0 && merchantEntries.length > buzzMaxMerchants) {
        merchantEntries = merchantEntries.sublist(0, buzzMaxMerchants);
      }

      // Split into cache hits (no API call) and misses (parallel API calls).
      final buzzByMerchant = <String, Promo>{};
      final toCheck = <String, Promo>{};
      var cacheHits = 0;

      for (final entry in merchantEntries) {
        final key = entry.key;
        final promo = entry.value;

        final cached = buzzCache?.get(key);
        if (cached != null) {
          cacheHits++;
          buzzByMerchant[key] = promo.copyWithBuzz(
            buzzScore: cached.score,
            buzzLabel: cached.label,
            buzzPlatforms: cached.platforms,
          );
        } else {
          toCheck[key] = promo;
        }
      }

      if (toCheck.isNotEmpty) {
        final checked = await Future.wait(
          toCheck.entries.map(
            (entry) async =>
                MapEntry(entry.key, await _buzzChecker.checkBuzz(entry.value)),
          ),
        );
        for (final entry in checked) {
          buzzByMerchant[entry.key] = entry.value;
          buzzCache?.put(
            entry.key,
            BuzzCacheEntry(
              score: entry.value.buzzScore,
              label: entry.value.buzzLabel,
              platforms: entry.value.buzzPlatforms,
              checkedAt: DateTime.now(),
            ),
          );
        }
      }

      stderr.writeln('[orchestrator] buzz: ${toCheck.length} new checks, '
          '$cacheHits cache hits, '
          '${representativeByMerchant.length - merchantEntries.length} '
          'skipped by cap');

      result = result.map((p) {
        final buzz = buzzByMerchant[p.merchantKey];
        if (buzz == null) return p;
        return p.copyWithBuzz(
          buzzScore: buzz.buzzScore,
          buzzLabel: buzz.buzzLabel,
          buzzPlatforms: buzz.buzzPlatforms,
        );
      }).toList();
    }

    stderr.writeln('[orchestrator] enrichment: ${promos.length} in, '
        '${result.length} out '
        '($expiredCount expired dropped, '
        '$invalidLinkCount invalid links dropped, '
        '${enableBuzzCheck ? "buzz on" : "buzz off"})');

    return result;
  }

  /// Drops promos whose [Promo.expiryDateIso] is before [today].
  /// Promos with no expiry date are kept.
  List<Promo> _dropExpired(List<Promo> promos, DateTime today) =>
      promos.where((p) {
        final iso = p.expiryDateIso.trim();
        if (iso.isEmpty) return true;
        final parsed = DateTime.tryParse(iso);
        if (parsed == null) return true;
        final expiry = DateTime(parsed.year, parsed.month, parsed.day);
        return !expiry.isBefore(today);
      }).toList();
}
