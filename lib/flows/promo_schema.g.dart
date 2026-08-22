// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'promo_schema.dart';

// **************************************************************************
// SchemaGenerator
// **************************************************************************

/// Schema for a single promo item. Used as the `outputSchema` when calling
/// Gemini through Genkit, forcing the model to follow this exact structure
/// instead of just being asked to via prompt text.
base class PromoItemSchema {
  /// Creates a [PromoItemSchema] from a JSON map.
  factory PromoItemSchema.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  PromoItemSchema._(this._json);

  PromoItemSchema({
    required String category,
    required String merchant,
    required String promoTitle,
    required String discount,
    required String discountType,
    required double discountAmount,
    required String terms,
    required String expiryDate,
    required String expiryDateIso,
    required String evidenceQuote,
    required String sourceLink,
  }) {
    _json = {
      'category': category,
      'merchant': merchant,
      'promoTitle': promoTitle,
      'discount': discount,
      'discountType': discountType,
      'discountAmount': discountAmount,
      'terms': terms,
      'expiryDate': expiryDate,
      'expiryDateIso': expiryDateIso,
      'evidenceQuote': evidenceQuote,
      'sourceLink': sourceLink,
    };
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [PromoItemSchema].
  static const SchemanticType<PromoItemSchema> $schema =
      _PromoItemSchemaTypeFactory();

  String get category {
    return _json['category'] as String;
  }

  set category(String value) {
    _json['category'] = value;
  }

  String get merchant {
    return _json['merchant'] as String;
  }

  set merchant(String value) {
    _json['merchant'] = value;
  }

  String get promoTitle {
    return _json['promoTitle'] as String;
  }

  set promoTitle(String value) {
    _json['promoTitle'] = value;
  }

  String get discount {
    return _json['discount'] as String;
  }

  set discount(String value) {
    _json['discount'] = value;
  }

  String get discountType {
    return _json['discountType'] as String;
  }

  set discountType(String value) {
    _json['discountType'] = value;
  }

  double get discountAmount {
    return (_json['discountAmount'] as num).toDouble();
  }

  set discountAmount(double value) {
    _json['discountAmount'] = value;
  }

  String get terms {
    return _json['terms'] as String;
  }

  set terms(String value) {
    _json['terms'] = value;
  }

  String get expiryDate {
    return _json['expiryDate'] as String;
  }

  set expiryDate(String value) {
    _json['expiryDate'] = value;
  }

  String get expiryDateIso {
    return _json['expiryDateIso'] as String;
  }

  set expiryDateIso(String value) {
    _json['expiryDateIso'] = value;
  }

  String get evidenceQuote {
    return _json['evidenceQuote'] as String;
  }

  set evidenceQuote(String value) {
    _json['evidenceQuote'] = value;
  }

  String get sourceLink {
    return _json['sourceLink'] as String;
  }

  set sourceLink(String value) {
    _json['sourceLink'] = value;
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [PromoItemSchema] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _PromoItemSchemaTypeFactory extends SchemanticType<PromoItemSchema> {
  const _PromoItemSchemaTypeFactory();

  @override
  PromoItemSchema parse(Object? json) {
    return PromoItemSchema._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
        name: 'PromoItemSchema',
        definition: $Schema.object(
          properties: {
            'category': $Schema.string(
              description:
                  'Promo category, must match exactly the category requested in the prompt (e.g. "Makanan", "Minuman", "Jajanan", or "Lifestyle")',
            ),
            'merchant': $Schema.string(
              description:
                  'Name of the merchant, brand, or store offering the promo',
            ),
            'promoTitle': $Schema.string(
              description:
                  'Title or short description of the promo, written in Bahasa Indonesia',
            ),
            'discount': $Schema.string(
              description:
                  'Discount amount or benefit, e.g. "20%", "Rp20.000", or "Beli 1 Gratis 1", written in Bahasa Indonesia',
            ),
            'discountType': $Schema.string(
              description:
                  'Type of discount, used for scoring. One of: "percentage" (e.g. 20% off), "fixed" (e.g. Rp20.000 off), "bogo" (e.g. Beli 1 Gratis 1), or "other". Use an empty string "" if unclear',
            ),
            'discountAmount': $Schema.number(
              description:
                  'Numeric value of the discount, used for scoring. For "percentage" type, the percentage number (e.g. 20 for 20%). For "fixed" type, the Rupiah amount without currency symbols (e.g. 20000 for Rp20.000). Use 0 for "bogo", "other", or when no numeric amount can be determined',
            ),
            'terms': $Schema.string(
              description:
                  'Terms and conditions, brief, written in Bahasa Indonesia. Use an empty string "" if not mentioned in the source',
            ),
            'expiryDate': $Schema.string(
              description:
                  'Date the promo expires, written in Bahasa Indonesia. Use exactly "Tidak disebutkan" if not mentioned in the source',
            ),
            'expiryDateIso': $Schema.string(
              description:
                  'The same expiry date as "expiryDate", but normalized to ISO 8601 format YYYY-MM-DD (e.g. "2026-08-31") so it can be compared programmatically. Use an empty string "" if the expiry date is not mentioned or unclear in the source',
            ),
            'evidenceQuote': $Schema.string(
              description:
                  'A short verbatim quote (at most ~120 characters) from the search result that supports the discount amount or expiry date. Use an empty string "" if no supporting quote is available',
            ),
            'sourceLink': $Schema.string(
              description:
                  'Source URL where this promo was found, copied exactly from the search result',
            ),
          },
          required: [
            'category',
            'merchant',
            'promoTitle',
            'discount',
            'discountType',
            'discountAmount',
            'terms',
            'expiryDate',
            'expiryDateIso',
            'evidenceQuote',
            'sourceLink',
          ],
        ).value,
        dependencies: [],
      );
}

/// Wrapper for the extraction result: the list of valid promos Gemini found
/// from a batch of search results.
base class PromoExtractionResult {
  /// Creates a [PromoExtractionResult] from a JSON map.
  factory PromoExtractionResult.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  PromoExtractionResult._(this._json);

  PromoExtractionResult({required List<PromoItemSchema> promos}) {
    _json = {'promos': promos.map((e) => e.toJson()).toList()};
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [PromoExtractionResult].
  static const SchemanticType<PromoExtractionResult> $schema =
      _PromoExtractionResultTypeFactory();

  List<PromoItemSchema> get promos {
    return (_json['promos'] as List)
        .map((e) => PromoItemSchema.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  set promos(List<PromoItemSchema> value) {
    _json['promos'] = value.map((e) => e.toJson()).toList();
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [PromoExtractionResult] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _PromoExtractionResultTypeFactory
    extends SchemanticType<PromoExtractionResult> {
  const _PromoExtractionResultTypeFactory();

  @override
  PromoExtractionResult parse(Object? json) {
    return PromoExtractionResult._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
        name: 'PromoExtractionResult',
        definition: $Schema.object(
          properties: {
            'promos': $Schema.list(
              description:
                  'List of valid promos extracted. Return an empty array if no valid promo was found at all',
              items: $Schema.fromMap({'\$ref': r'#/$defs/PromoItemSchema'}),
            ),
          },
          required: ['promos'],
        ).value,
        dependencies: [PromoItemSchema.$schema],
      );
}

/// Input for the `searchPromo` tool — called by Gemini itself (via tool
/// calling), not by our own code. Gemini decides the most relevant search
/// keywords, and may call this tool more than once with different queries.
base class SearchPromoInput {
  /// Creates a [SearchPromoInput] from a JSON map.
  factory SearchPromoInput.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  SearchPromoInput._(this._json);

  SearchPromoInput({required String query}) {
    _json = {'query': query};
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [SearchPromoInput].
  static const SchemanticType<SearchPromoInput> $schema =
      _SearchPromoInputTypeFactory();

  String get query {
    return _json['query'] as String;
  }

  set query(String value) {
    _json['query'] = value;
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [SearchPromoInput] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _SearchPromoInputTypeFactory
    extends SchemanticType<SearchPromoInput> {
  const _SearchPromoInputTypeFactory();

  @override
  SearchPromoInput parse(Object? json) {
    return SearchPromoInput._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
        name: 'SearchPromoInput',
        definition: $Schema.object(
          properties: {
            'query': $Schema.string(
              description:
                  'Google search query to find promos, written in Bahasa Indonesia (since we are searching for Indonesian promos). Include category, region, and optionally a specific brand name, e.g. "promo makanan terbaru Jabodetabek minggu ini"',
            ),
          },
          required: ['query'],
        ).value,
        dependencies: [],
      );
}
