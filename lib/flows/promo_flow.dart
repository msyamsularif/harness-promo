import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:genkit_google_genai/genkit_google_genai.dart';
import 'package:genkit_openai/genkit_openai.dart';
import 'package:intl/intl.dart';

import '../models/promo.dart';
import '../services/serpapi_client.dart';
import 'promo_schema.dart';

/// Flow that searches for and summarizes promos through Gemini (via Genkit).
///
/// IMPORTANT: SerpApi is registered here as a Genkit TOOL (`searchPromo`),
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
  final SerpApiClient _serpapi;

  /// Gemini model used. `gemini-2.5-flash` is on Google AI Studio's free
  /// tier, fast enough, and supports tool calling.
  static const _modelName = 'gemini-2.5-flash';

  /// Groq fallback model when Gemini hits rate limits. Uses Groq's free
  /// tier (~30 RPM). Llama 3.3 70B supports tools, multiturn, and system
  /// role — same feature set our flow needs.
  static const _fallbackModel = 'openai/gpt-oss-120b';

  /// True when a Groq fallback plugin has been registered (groqApiKey was
  /// provided). When false, rate-limit errors are rethrown as before.
  final bool _hasFallback;

  /// Max MERCHANTS kept per sub-category (several promos from the same
  /// merchant count as ONE slot and are later rendered as one Telegram
  /// section). Enforced both via prompt instructions AND as a safety net
  /// via merchant-grouping + `.take()` in code.
  static const _maxPromoPerCategory = 10;

  PromoFlow(
      {required String geminiApiKey,
      String? groqApiKey,
      required SerpApiClient serpapi})
      : _ai = Genkit(plugins: [
          googleAI(apiKey: geminiApiKey),
          if (groqApiKey != null && groqApiKey.isNotEmpty)
            openAI(
              name: 'groq',
              apiKey: groqApiKey,
              baseUrl: 'https://api.groq.com/openai/v1',
              models: [
                CustomModelDefinition(
                  name: _fallbackModel,
                  info: ModelInfo(
                    label: 'GPT-OSS 120B',
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
        _hasFallback = groqApiKey != null && groqApiKey.isNotEmpty,
        _serpapi = serpapi {
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
        final results = await _serpapi.search(input.query);
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

  ModelRef<dynamic> _groqModel() =>
      openAI.model(_fallbackModel, namespace: 'groq');

  /// Groq fallback: calls SerpApi directly (no Genkit tool calling),
  /// then asks GPT-OSS to extract structured promos from raw search text.
  /// Avoids the "json mode + tools" conflict and `strict: true` schema
  /// validation failures by using prompt-based JSON output + manual parse.
  Future<List<Promo>> _groqSinglePhase(
    String category,
    String region,
    DateTime today,
    String todayIso,
    String searchHint,
  ) async {
    final searchResults = await _serpapi.search(
      '$searchHint $region minggu ini',
    );
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
      "terms": "S&K (atau kosong)",
      "expiryDate": "Tanggal kadaluarsa",
      "expiryDateIso": "YYYY-MM-DD atau kosong",
      "sourceLink": "URL sumber"
    }
  ]
}

Rules:
- Max $_maxPromoPerCategory different merchants. Multiple promos from same merchant = count as one.
- Deduplicate: same merchant & offer from different sources → merge into one entry.
- Write in Bahasa Indonesia. Do not invent info.
- If there are no valid promos, return {"promos": []}.
- Only output the JSON object, nothing else.
''';

    final response = await _ai.generate<dynamic, String>(
      model: _groqModel(),
      prompt: prompt,
      use: [retry()],
    );

    return _parseGroqResponse(response.text, category, today);
  }

  List<Promo> _parseGroqResponse(String text, String category, DateTime today) {
    try {
      final json = _extractJson(text);
      if (json == null) return [];
      final list = json['promos'] as List<dynamic>?;
      if (list == null || list.isEmpty) return [];

      final byMerchant = <String, List<PromoItemSchema>>{};
      for (final itemJson in list) {
        if (itemJson is! Map<String, dynamic>) continue;
        try {
          final item = PromoItemSchema.fromJson(itemJson);
          final parsed = DateTime.tryParse(item.expiryDateIso.trim());
          if (parsed != null) {
            final expiry = DateTime(parsed.year, parsed.month, parsed.day);
            if (expiry.isBefore(today)) continue;
          }
          byMerchant
              .putIfAbsent(_itemKey(item.merchant), () => [])
              .add(item);
        } catch (_) {
          // Skip malformed items
        }
      }

      return byMerchant.values
          .take(_maxPromoPerCategory)
          .expand((group) => group)
          .map(_toPromo)
          .toList();
    } catch (e) {
      stderr.writeln('[promo_flow] Failed to parse Groq response: $e');
      return [];
    }
  }

  /// Simple merchant key for schema items (doesn't have the Promo extension).
  String _itemKey(String merchant) =>
      merchant.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  Map<String, dynamic>? _extractJson(String text) {
    try {
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      // Try to find a JSON object in the text
      final match = RegExp(r'\{[\s\S]*\}').firstMatch(text);
      if (match != null) {
        try {
          return jsonDecode(match.group(0)!) as Map<String, dynamic>;
        } catch (_) {}
      }
      return null;
    }
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
          '(${e.runtimeType}), switching to Groq single-phase fallback');
      return await _groqSinglePhase(
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
8. IMPORTANT: write all promo text (merchant names aside) in Bahasa Indonesia, since the final result will be shown to an Indonesian audience.
9. Do not invent information that isn't in the search results.
10. If there is no valid promo at all, clearly state that no promo was found for this category.
''';

    final researchResponse = await _ai.generate<dynamic, String>(
      model: googleAI.gemini(_modelName),
      prompt: researchPrompt,
      toolNames: ['searchPromo'],
      maxTurns: 3,
      use: [retry()],
    );

    final rawSummary = researchResponse.text.trim();
    if (rawSummary.isEmpty) return [];

    final structurePrompt = '''
Here is a free-text summary of promos for category "$category" in region "$region":

$rawSummary

Turn the summary above into structured data following the given schema. Do NOT add, remove, or invent any information beyond what is already in the summary — this is purely a reformatting task, not a re-analysis. Set the "category" field of every promo to exactly "$category". Keep all text field values in Bahasa Indonesia as they already are in the summary. Also normalize each promo's expiry date into the "expiryDateIso" field (format YYYY-MM-DD; use today's date $todayIso to resolve an unstated year, and an empty string "" if the summary gives no clear expiry date). If the summary above states that no promo was found, return an empty promo list.
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

    // Group by merchant (insertion order preserved, keeping Gemini's
    // most-interesting-first ordering) so several promos from the same
    // merchant count as ONE slot toward the cap — one very active brand
    // can't eat the whole sub-category quota.
    final byMerchant = <String, List<PromoItemSchema>>{};
    for (final item in result.promos.where(isStillValid)) {
      byMerchant
          .putIfAbsent(_itemKey(item.merchant), () => [])
          .add(item);
    }

    return byMerchant.values
        .take(_maxPromoPerCategory)
        .expand((group) => group)
        .map(_toPromo)
        .toList();
  }

  Promo _toPromo(PromoItemSchema item) => Promo(
        category: item.category,
        merchant: item.merchant,
        promoTitle: item.promoTitle,
        discount: item.discount,
        terms: item.terms,
        expiryDate: item.expiryDate,
        sourceLink: item.sourceLink,
      );
}
