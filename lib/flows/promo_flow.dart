import 'package:genkit/genkit.dart';
import 'package:genkit_google_genai/genkit_google_genai.dart';

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
/// PHASE 1 (research): tool calling enabled, Gemini is free to call
/// `searchPromo` multiple times, final answer is free-form text.
/// PHASE 2 (structuring): no tools, purely turns phase 1's text into the
/// `outputSchema` — must not add any new information.
class PromoFlow {
  final Genkit _ai;
  final SerpApiClient _serpapi;

  /// Gemini model used. `gemini-2.5-flash` is on Google AI Studio's free
  /// tier, fast enough, and supports tool calling.
  static const _modelName = 'gemini-2.5-flash';

  /// Max promos kept per sub-category. Enforced both via prompt
  /// instructions AND as a safety net via `.take()` in code.
  static const _maxPromoPerCategory = 10;
  PromoFlow({required String geminiApiKey, required SerpApiClient serpapi})
      : _ai = Genkit(plugins: [googleAI(apiKey: geminiApiKey)]),
        _serpapi = serpapi {
    _registerSearchTool();
  }

  void _registerSearchTool() {
    _ai.defineTool(
      name: 'searchPromo',
      description:
          'Searches Google for the latest promos/discounts matching a given '
          'query. Can be called more than once with different keywords to '
          'widen search coverage (e.g. try including a well-known big brand '
          'name in this category, or a variation of promo-related terms).',
      inputSchema: SearchPromoInput.$schema,
      fn: (input, _) async {
        final results = await _serpapi.search(input.query, maxResults: 10);
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

  /// [category] sub-category label, e.g. "Makanan", "Minuman", "Jajanan",
  /// or "Lifestyle". [region] e.g. "Jabodetabek" or a specific location
  /// from an on-demand bot request. [searchHint] a suggested starting
  /// keyword for Gemini (it may expand on this itself).
  Future<List<Promo>> extract(
    String category,
    String region, {
    required String searchHint,
  }) async {
    final researchPrompt = '''
You are an assistant that searches for and summarizes promos for the sub-category "$category" in the region "$region".

Use the "searchPromo" tool to find the latest promos. A good starting keyword is: "$searchHint $region minggu ini" (write your search queries in Bahasa Indonesia, since we are searching for Indonesian promos). You MAY call this tool more than once with different keywords if the first result isn't enough (e.g. try including a well-known big brand name popular in this category, or a variation of promo/discount-related terms).

Once you feel the search results are sufficient, write a summary of the promos as FREE-FORM TEXT bullet points (not JSON), following these rules:
1. Only include results that genuinely contain a valid promo/discount relevant to "$category" in "$region".
2. DEDUPLICATE: if the same promo (same merchant & same offer) appears in multiple different sources, merge it into a SINGLE entry.
3. LINK ACCURACY: include a source link that specifically discusses that exact promo, not a generic homepage/category link.
4. PRIORITIZE BIG BRANDS: if there are promos from large, well-known brands, prioritize them over small/unknown merchants.
5. Order the results from most interesting/relevant first.
6. Limit to a maximum of $_maxPromoPerCategory promos.
7. For each promo, clearly state: merchant name, promo title/description, discount amount, terms & conditions (or "not specified" if none), expiry date (or "not specified"), and the source link.
8. IMPORTANT: write all promo text (merchant names aside) in Bahasa Indonesia, since the final result will be shown to an Indonesian audience.
9. Do not invent information that isn't in the search results.
10. If there is no valid promo at all, clearly state that no promo was found for this category.
''';

    final researchResponse = await _ai.generate(
      model: googleAI.gemini(_modelName),
      prompt: researchPrompt,
      toolNames: ['searchPromo'],
    );

    final rawSummary = researchResponse.text.trim();
    if (rawSummary.isEmpty) return [];

    final structurePrompt = '''
Here is a free-text summary of promos for category "$category" in region "$region":

$rawSummary

Turn the summary above into structured data following the given schema. Do NOT add, remove, or invent any information beyond what is already in the summary — this is purely a reformatting task, not a re-analysis. Set the "category" field of every promo to exactly "$category". Keep all text field values in Bahasa Indonesia as they already are in the summary. If the summary above states that no promo was found, return an empty promo list.
''';

    final structuredResponse = await _ai.generate(
      model: googleAI.gemini(_modelName),
      prompt: structurePrompt,
      outputSchema: PromoExtractionResult.$schema,
    );

    final result = structuredResponse.output;
    if (result == null) {
      throw Exception(
          'Gemini did not return valid structured output for category "$category".');
    }

    return result.promos.map(_toPromo).take(_maxPromoPerCategory).toList();
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
