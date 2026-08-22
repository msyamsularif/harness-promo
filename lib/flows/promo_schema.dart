import 'package:schemantic/schemantic.dart';

part 'promo_schema.g.dart';

/// Schema for a single promo item. Used as the `outputSchema` when calling
/// Gemini through Genkit, forcing the model to follow this exact structure
/// instead of just being asked to via prompt text.
@Schema()
abstract class $PromoItemSchema {
  @Field(description: 'Promo category, must match exactly the category requested in the prompt (e.g. "Makanan", "Minuman", "Jajanan", or "Lifestyle")')
  String get category;

  @Field(description: 'Name of the merchant, brand, or store offering the promo')
  String get merchant;

  @Field(description: 'Title or short description of the promo, written in Bahasa Indonesia')
  String get promoTitle;

  @Field(description: 'Discount amount or benefit, e.g. "20%", "Rp20.000", or "Beli 1 Gratis 1", written in Bahasa Indonesia')
  String get discount;

  @Field(description: 'Type of discount, used for scoring. One of: "percentage" (e.g. 20% off), "fixed" (e.g. Rp20.000 off), "bogo" (e.g. Beli 1 Gratis 1), or "other". Use an empty string "" if unclear')
  String get discountType;

  @Field(description: 'Numeric value of the discount, used for scoring. For "percentage" type, the percentage number (e.g. 20 for 20%). For "fixed" type, the Rupiah amount without currency symbols (e.g. 20000 for Rp20.000). Use 0 for "bogo", "other", or when no numeric amount can be determined')
  double get discountAmount;

  @Field(description: 'Terms and conditions, brief, written in Bahasa Indonesia. Use an empty string "" if not mentioned in the source')
  String get terms;

  @Field(description: 'Date the promo expires, written in Bahasa Indonesia. Use exactly "Tidak disebutkan" if not mentioned in the source')
  String get expiryDate;

  @Field(description: 'The same expiry date as "expiryDate", but normalized to ISO 8601 format YYYY-MM-DD (e.g. "2026-08-31") so it can be compared programmatically. Use an empty string "" if the expiry date is not mentioned or unclear in the source')
  String get expiryDateIso;

  @Field(description: 'A short verbatim quote (at most ~120 characters) from the search result that supports the discount amount or expiry date. Use an empty string "" if no supporting quote is available')
  String get evidenceQuote;

  @Field(description: 'Source URL where this promo was found, copied exactly from the search result')
  String get sourceLink;
}

/// Wrapper for the extraction result: the list of valid promos Gemini found
/// from a batch of search results.
@Schema()
abstract class $PromoExtractionResult {
  @Field(description: 'List of valid promos extracted. Return an empty array if no valid promo was found at all')
  List<$PromoItemSchema> get promos;
}

/// Input for the `searchPromo` tool — called by Gemini itself (via tool
/// calling), not by our own code. Gemini decides the most relevant search
/// keywords, and may call this tool more than once with different queries.
@Schema()
abstract class $SearchPromoInput {
  @Field(description: 'Google search query to find promos, written in Bahasa Indonesia (since we are searching for Indonesian promos). Include category, region, and optionally a specific brand name, e.g. "promo makanan terbaru Jabodetabek minggu ini"')
  String get query;
}
