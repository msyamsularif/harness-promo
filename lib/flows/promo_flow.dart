import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:genkit_google_genai/genkit_google_genai.dart';
import 'package:genkit_openai/genkit_openai.dart';
import 'package:intl/intl.dart';

import '../core/fuzzy_dedup.dart';
import '../core/promo_scoring.dart';
import '../models/promo.dart';
import '../services/serpapi_client.dart';
import 'promo_schema.dart';

/// Flow that searches for and summarizes promos through Gemini (via Genkit).
///
/// IMPORTANT: The search service (SerpApi/Tavily/Serper via the fallback
/// chain) is registered here as a Genkit TOOL (`searchPromo`),
/// not called manually beforehand with results stuffed into the prompt.
/// Gemini itself decides which search keywords to use, and may call the
/// tool more than once with different keywords if the first attempt isn't
/// enough. This is the standard "agentic tool calling" pattern in Genkit
/// (see https://genkit.dev/docs/js/tool-calling/).
///
/// Extraction is split into TWO separate `generate()` calls rather than
/// one, because the Gemini API does not support combining tool calling
/// with structured output (`outputSchema`) in a single request — the
/// error is explicit: "Function calling with a response mime type:
/// 'application/json' is unsupported". So:
///
/// PHASE 1 (research): tool calling enabled, Gemini may call `searchPromo`
/// up to twice (hard-capped via `maxTurns: 3` so an over-eager model can't
/// burn quota in a long tool loop), final answer is free-form text.
/// PHASE 2 (structuring): no tools, purely turns phase 1's text into the
/// `outputSchema` — must not add any new information.
///
/// Both phases use the `retry` middleware (RetryPlugin) so a transient
/// Gemini 429/RESOURCE_EXHAUSTED is retried with exponential backoff
/// instead of aborting the whole run.
class PromoFlow {
  final Genkit _ai;
  final SearchService _search;

  /// Gemini model used. `gemini-2.5-flash` is on Google AI Studio's free
  /// tier, fast enough, and supports tool calling.
  static const _modelName = 'gemini-2.5-flash';

  /// Fallback model when Gemini hits rate limits. Uses OpenRouter's
  /// OpenAI-compatible API with a free model. The model only needs to
  /// follow the JSON prompt (single-phase fallback doesn't use tools).
  static const _defaultFallbackModel = 'openai/gpt-oss-20b:free';

  /// True when a fallback plugin has been registered (openRouterApiKey was
  /// provided). When false, rate-limit errors are rethrown as before.
  final bool _hasFallback;

  /// The OpenRouter model identifier used by the fallback path (resolved
  /// from the FALLBACK_MODEL env var, or the default free model).
  final String _fallbackModel;

  /// Max MERCHANTS kept per sub-category (several promos from the same
  /// merchant count as ONE slot and are later rendered as one Telegram
  /// section). Enforced both via prompt instructions AND as a safety net
  /// via merchant-grouping + `.take()` in code.
  static const _maxPromoPerCategory = 10;

  PromoFlow(
      {required String geminiApiKey,
      String? openRouterApiKey,
      String? fallbackModel,
      required SearchService search})
      : _ai = Genkit(plugins: [
          googleAI(apiKey: geminiApiKey),
          if (openRouterApiKey != null && openRouterApiKey.isNotEmpty)
            openAI(
              name: 'openrouter',
              apiKey: openRouterApiKey,
              baseUrl: 'https://openrouter.ai/api/v1',
              models: [
                CustomModelDefinition(
                  name: fallbackModel ?? _defaultFallbackModel,
                  info: ModelInfo(
                    label: 'OpenRouter fallback',
                    supports: {
                      'multiturn': true,
                      'tools': true,
                      'systemRole': true,
                    },
                  ),
                ),
              ],
            ),
          RetryPlugin(),
        ]),
        _hasFallback = openRouterApiKey != null && openRouterApiKey.isNotEmpty,
        _fallbackModel = fallbackModel ?? _defaultFallbackModel,
        _search = search {
    _registerSearchTool();
  }

  void _registerSearchTool() {
    _ai.defineTool(
      name: 'searchPromo',
      description:
          'Searches Google for the latest promos/discounts matching a given '
          'query. The search budget is limited — only call this again with '
          'different keywords if the previous results clearly lacked valid '
          'promos (e.g. try including a well-known big brand name in this '
          'category, or a variation of promo-related terms).',
      inputSchema: SearchPromoInput.$schema,
      fn: (input, _) async {
        final results = await _search.search(input.query);
        if (results.isEmpty) {
          return 'No search results found for this query.';
        }
        return results
            .map((r) =>
                '- Title: ${r.title}\n  Snippet: ${r.snippet}\n  Link: ${r.link}')
            .join('\n');
      },
    );
  }

  ModelRef<dynamic> _fallbackModelRef() =>
      openAI.model(_fallbackModel, namespace: 'openrouter');

  /// OpenRouter fallback: calls the search service directly (no Genkit tool
  /// calling), then asks the fallback model to extract structured promos
  /// from raw search text. Uses prompt-based JSON output + manual parse
  /// (OpenRouter free models don't reliably support strict JSON schema).
  Future<List<Promo>> _fallbackSinglePhase(
    String category,
    String region,
    DateTime today,
    String todayIso,
    String searchHint,
  ) async {
    final searchResults = await _search.search(
      '$searchHint $region minggu ini',
    );
    stderr.writeln('[promo_flow][fallback] "$category": search returned '
        '${searchResults.length} results.');
    if (searchResults.isEmpty) return [];

    final searchText = searchResults
        .map((r) =>
            '- Title: ${r.title}\n  Snippet: ${r.snippet}\n  Link: ${r.link}')
        .join('\n');

    final prompt = '''
Extract valid promos for "$category" in "$region" from the search results below.

Today is $todayIso. Skip promos whose expiry date has passed. Promos expiring today are still valid.

Search results:
$searchText

Return ONLY a JSON object with this exact structure (no markdown, no explanation):
{
  "promos": [
    {
      "category": "$category",
      "merchant": "Nama toko",
      "promoTitle": "Judul promo",
      "discount": "Diskon",
      "discountType": "percentage|fixed|bogo|other|",
      "discountAmount": 0,
      "terms": "S&K (atau kosong)",
      "expiryDate": "Tanggal kadaluarsa",
      "expiryDateIso": "YYYY-MM-DD atau kosong",
      "evidenceQuote": "kutipan singkat pendukung diskon/expiry (atau kosong)",
      "sourceLink": "URL sumber"
    }
  ]
}

Rules:
- Max $_maxPromoPerCategory different merchants. Multiple promos from same merchant = count as one.
- Deduplicate: same merchant & offer from different sources → merge into one entry.
- LINK ACCURACY: each promo's "sourceLink" must be the URL of a page/post that specifically discusses that exact promo. Never reuse the same sourceLink for two DIFFERENT merchants. If you cannot find a distinct, correct source link for a promo, skip that promo entirely.
- "discountType" is one of "percentage" (20% off), "fixed" (Rp20.000 off), "bogo" (Beli 1 Gratis 1), "other", or empty if unclear. "discountAmount" is the number only (percentage number for "percentage", Rupiah amount without symbols for "fixed"); use 0 for "bogo"/"other"/unclear.
- "evidenceQuote" is a short VERBATIM quote (max ~120 chars) from the search results that supports the discount or expiry; use "" if none.
- Write in Bahasa Indonesia. Do not invent info.
- If there are no valid promos, return {"promos": []}.
- Only output the JSON object, nothing else.
''';

    final response = await _ai.generate<dynamic, String>(
      model: _fallbackModelRef(),
      prompt: prompt,
      use: [retry()],
    );

    final promos = _parseFallbackResponse(response.text, category, today);
    stderr.writeln('[promo_flow][fallback] "$category": extracted '
        '${promos.length} promos.');
    return promos;
  }

  List<Promo> _parseFallbackResponse(
      String text, String category, DateTime today) {
    try {
      final json = _extractJson(text);
      if (json == null) {
        stderr.writeln('[promo_flow][fallback] "$category": could not parse '
            'JSON from fallback response (length ${text.length}).');
        return [];
      }
      final list = json['promos'] as List<dynamic>?;
      if (list == null || list.isEmpty) {
        stderr.writeln('[promo_flow][fallback] "$category": fallback model '
            'returned an empty promos list.');
        return [];
      }

      final byMerchant = <String, List<PromoItemSchema>>{};
      final linkOwner = <String, String>{};
      for (final itemJson in list) {
        if (itemJson is! Map<String, dynamic>) continue;
        try {
          final item = PromoItemSchema.fromJson(itemJson);
          final parsed = DateTime.tryParse(item.expiryDateIso.trim());
          if (parsed != null) {
            final expiry = DateTime(parsed.year, parsed.month, parsed.day);
            if (expiry.isBefore(today)) continue;
          }

          final merchantKey = _itemKey(item.merchant);
          final link = _normalizeLink(item.sourceLink);

          // Guard against the fallback model hallucinating the same source
          // link across different merchants: only the first merchant keeps
          // a given link; later reuses are dropped.
          if (link.isNotEmpty) {
            final owner = linkOwner[link];
            if (owner != null && owner != merchantKey) continue;
            linkOwner[link] = merchantKey;
          }

          byMerchant
              .putIfAbsent(merchantKey, () => [])
              .add(item);
        } catch (_) {
          // Skip malformed items
        }
      }

      final promos = byMerchant.values
          .take(_maxPromoPerCategory)
          .expand((group) => group)
          .map(_toPromo)
          .toList();
      return _rankByPartialScore(dedupeMerchantAliases(promos), today);
    } catch (e) {
      stderr.writeln('[promo_flow] Failed to parse fallback response: $e');
      return [];
    }
  }

  /// Simple merchant key for schema items (doesn't have the Promo extension).
  String _itemKey(String merchant) =>
      merchant.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// Normalizes a source URL for de-duplication: trims and drops a trailing
  /// slash so `https://a.b/` and `https://a.b` compare equal.
  String _normalizeLink(String link) {
    var l = link.trim();
    if (l.endsWith('/')) l = l.substring(0, l.length - 1);
    return l;
  }

  Map<String, dynamic>? _extractJson(String text) {
    // Strip markdown code fences (```json ... ```) first — GPT-OSS sometimes
    // wraps its output even when asked for raw JSON.
    var candidate = text.trim().replaceFirst(RegExp(r'^\s*```[a-zA-Z]*\s*'), '');
    candidate = candidate.replaceFirst(RegExp(r'```\s*$'), '').trim();

    final direct = _tryDecodeObject(candidate);
    if (direct != null) return direct;

    // Fall back to locating the outermost balanced JSON object (or array)
    // within whatever prose the model may have emitted.
    final object = _extractBalanced(candidate, '{', '}');
    if (object != null) {
      final parsed = _tryDecodeObject(object);
      if (parsed != null) return parsed;
    }

    final array = _extractBalanced(candidate, '[', ']');
    if (array != null) {
      final list = _tryDecodeList(array);
      if (list != null) return {'promos': list};
    }

    final preview =
        text.length > 200 ? text.substring(0, 200) : text;
    stderr.writeln('[promo_flow] Could not parse fallback response as JSON '
        '(length ${text.length}). First 200 chars: $preview');
    return null;
  }

  Map<String, dynamic>? _tryDecodeObject(String s) {
    try {
      final decoded = jsonDecode(s);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  List<dynamic>? _tryDecodeList(String s) {
    try {
      final decoded = jsonDecode(s);
      return decoded is List ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Returns the substring from the first [open] char to its matching
  /// [close] char, honoring quotes so braces inside string values don't
  /// break the scan. Returns null if no balanced pair exists.
  String? _extractBalanced(String text, String open, String close) {
    final start = text.indexOf(open);
    if (start < 0) return null;

    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == '\\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
      } else if (ch == open) {
        depth++;
      } else if (ch == close) {
        depth--;
        if (depth == 0) return text.substring(start, i + 1);
      }
    }
    return null;
  }

  /// [category] sub-category label, e.g. "Makanan", "Minuman", "Jajanan",
  /// or "Lifestyle". [region] e.g. "Jabodetabek" or a specific location
  /// from an on-demand bot request. [searchHint] a suggested starting
  /// keyword for Gemini (it may expand on this itself).
  Future<List<Promo>> extract(
    String category,
    String region, {
    required String searchHint,
  }) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final todayIso = DateFormat('yyyy-MM-dd').format(now);

    try {
      return await _geminiTwoPhase(
          category, region, today, todayIso, searchHint);
    } catch (e) {
      if (!_hasFallback) rethrow;

      stderr.writeln('[promo_flow] Gemini failed for "$category" '
          '(${e.runtimeType}), switching to OpenRouter single-phase fallback');
      return await _fallbackSinglePhase(
          category, region, today, todayIso, searchHint);
    }
  }

  Future<List<Promo>> _geminiTwoPhase(
    String category,
    String region,
    DateTime today,
    String todayIso,
    String searchHint,
  ) async {
    final researchPrompt = '''
You are an assistant that searches for and summarizes promos for the sub-category "$category" in the region "$region".

Use the "searchPromo" tool to find the latest promos. A good starting keyword is: "$searchHint $region minggu ini" (write your search queries in Bahasa Indonesia, since we are searching for Indonesian promos).

SEARCH BUDGET: you may search AT MOST TWICE, so craft each query carefully. Only search a second time if the first results clearly lack valid promos (e.g. try including a well-known big brand name popular in this category, or a variation of promo/discount-related terms). When you are done searching, you MUST finish by writing the summary text described below — do not request another tool call.

Today's date is $todayIso. EXPIRY RULE: skip any promo whose expiry date has already passed (expiry date earlier than today). Promos expiring exactly ON today's date are still valid and must be included. Promos with no stated expiry date are fine to include.

Once you feel the search results are sufficient, write a summary of the promos as FREE-FORM TEXT bullet points (not JSON), following these rules:
1. Only include results that genuinely contain a valid promo/discount relevant to "$category" in "$region".
2. DEDUPLICATE: if the same promo (same merchant & same offer) appears in multiple different sources, merge it into a SINGLE entry.
3. LINK ACCURACY: include a source link that specifically discusses that exact promo, not a generic homepage/category link.
4. PRIORITIZE BIG BRANDS: if there are promos from large, well-known brands, prioritize them over small/unknown merchants.
5. Order the results from most interesting/relevant first.
6. Limit to a maximum of $_maxPromoPerCategory different merchants/brands. Multiple DISTINCT promos from the same merchant are welcome — list each of them as its own bullet point; they count as ONE merchant toward the limit.
7. For each promo, clearly state: merchant name, promo title/description, discount amount, terms & conditions (or "not specified" if none), expiry date (or "not specified"), and the source link.
8. For each promo, also include a short EVIDENCE QUOTE on its own line: a VERBATIM phrase (at most ~120 characters) from the search results that supports the discount amount or the expiry date. Use an empty line if no supporting phrase exists.
9. IMPORTANT: write all promo text (merchant names aside) in Bahasa Indonesia, since the final result will be shown to an Indonesian audience.
10. Do not invent information that isn't in the search results.
11. If there is no valid promo at all, clearly state that no promo was found for this category.
''';

    final researchResponse = await _ai.generate<dynamic, String>(
      model: googleAI.gemini(_modelName),
      prompt: researchPrompt,
      toolNames: ['searchPromo'],
      maxTurns: 3,
      use: [retry()],
    );

    final rawSummary = researchResponse.text.trim();
    stderr.writeln('[promo_flow][gemini] "$category": phase 1 summary is '
        '${rawSummary.length} chars.');
    if (rawSummary.isEmpty) return [];

    final structurePrompt = '''
Here is a free-text summary of promos for category "$category" in region "$region":

$rawSummary

Turn the summary above into structured data following the given schema. Do NOT add, remove, or invent any information beyond what is already in the summary — this is purely a reformatting task, not a re-analysis. Set the "category" field of every promo to exactly "$category". Keep all text field values in Bahasa Indonesia as they already are in the summary. Also normalize each promo's expiry date into the "expiryDateIso" field (format YYYY-MM-DD; use today's date $todayIso to resolve an unstated year, and an empty string "" if the summary gives no clear expiry date). Fill the "discountType" field (one of "percentage", "fixed", "bogo", "other", or "" if unclear) and the "discountAmount" field (the number only: the percentage number for "percentage", the Rupiah amount without symbols for "fixed", 0 for "bogo"/"other"/unclear) by deriving them from the "discount" text. Fill the "evidenceQuote" field with the verbatim evidence quote line from the summary, or "" if the summary has none — do not invent a quote. If the summary above states that no promo was found, return an empty promo list.
''';

    final structuredResponse = await _ai.generate(
      model: googleAI.gemini(_modelName),
      prompt: structurePrompt,
      outputSchema: PromoExtractionResult.$schema,
      use: [retry()],
    );

    final result = structuredResponse.output;
    if (result == null) {
      throw Exception(
          'Gemini did not return valid structured output for category "$category".');
    }

    stderr.writeln('[promo_flow][gemini] "$category": phase 2 produced '
        '${result.promos.length} raw promos.');

    // Safety net for the prompt's expiry rule: drop promos whose
    // normalized expiry date is BEFORE today. Expiring exactly today is
    // still valid; an empty/unparseable date keeps the promo (we can't
    // prove it expired).
    bool isStillValid(PromoItemSchema item) {
      final parsed = DateTime.tryParse(item.expiryDateIso.trim());
      if (parsed == null) return true;
      final expiry = DateTime(parsed.year, parsed.month, parsed.day);
      return !expiry.isBefore(today);
    }

    // Group by merchant so several promos from the same merchant count as
    // ONE slot toward the cap — one very active brand can't eat the whole
    // sub-category quota.
    //
    // Ordering before grouping is deterministic: convert to Promo,
    // fuzzy-dedupe merchant aliases (safety-net), then sort by composite
    // score rather than relying purely on the prompt's ordering.
    final valid = result.promos.where(isStillValid).map(_toPromo).toList();
    final merged = dedupeMerchantAliases(valid);
    final ranked = _rankByPartialScore(merged, today);

    final byMerchant = <String, List<Promo>>{};
    for (final promo in ranked) {
      byMerchant
          .putIfAbsent(promo.merchantKey, () => [])
          .add(promo);
    }

    final promos = byMerchant.values
        .take(_maxPromoPerCategory)
        .expand((group) => group)
        .toList();
    stderr.writeln('[promo_flow][gemini] "$category": kept ${promos.length} '
        'promos after validity + fuzzy dedup + merchant cap.');
    return promos;
  }

  Promo _toPromo(PromoItemSchema item) {
    final raw = item.toJson();
    return Promo(
      category: item.category,
      merchant: item.merchant,
      promoTitle: item.promoTitle,
      discount: item.discount,
      discountType: raw['discountType']?.toString() ?? '',
      discountAmount: (raw['discountAmount'] as num?)?.toDouble(),
      terms: item.terms,
      expiryDate: item.expiryDate,
      expiryDateIso: item.expiryDateIso.trim(),
      evidenceQuote: raw['evidenceQuote']?.toString() ?? '',
      sourceLink: item.sourceLink,
    );
  }

  /// Sorts [promos] by descending composite score (buzz is still -1 here,
  /// so it contributes a constant neutral value) as a deterministic tie-in
  /// to Gemini's "most interesting first" ordering.
  List<Promo> _rankByPartialScore(List<Promo> promos, DateTime today) =>
      rankByScore(promos, today: today);
}
