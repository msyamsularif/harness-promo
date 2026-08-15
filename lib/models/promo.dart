/// Normalizes a merchant name for grouping/dedup purposes (case- and
/// whitespace-insensitive), so "Kopi Kenangan", "KOPI KENANGAN ", and
/// "Kopi  Kenangan" are treated as the same merchant. Used to group
/// several promos from one merchant into a single Telegram section and
/// to share one buzz check across them.
extension PromoMerchantKey on Promo {
  String get merchantKey =>
      merchant.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
}

/// A single promo item extracted by Gemini, later enriched with a social
/// media "buzz" signal (added by SocialBuzzChecker, not by Gemini itself).
///
/// Note: [category] values are intentionally kept in Indonesian (e.g.
/// "Makanan", "Minuman", "Jajanan", "Lifestyle") because they are displayed
/// directly in the Telegram output, which targets an Indonesian audience.
class Promo {
  final String category;
  final String merchant;
  final String promoTitle;
  final String discount;

  /// Normalized discount type ("percentage", "fixed", "bogo", "other" or
  /// empty when unclear). Filled by Gemini at extraction, used for scoring.
  final String discountType;

  /// Numeric discount value (percentage number for "percentage", Rupiah
  /// amount for "fixed", null otherwise). Filled by Gemini, used for scoring.
  final double? discountAmount;

  final String terms;
  final String expiryDate; // free-form string, e.g. "31 August 2026" / "Not specified"

  /// Normalized ISO 8601 expiry date (YYYY-MM-DD), or empty when unknown.
  /// Used for expiry pruning, freshness scoring, and cross-week dedup.
  final String expiryDateIso;

  /// Short verbatim quote supporting the discount/expiry. Empty means the
  /// promo is treated as low-confidence during scoring.
  final String evidenceQuote;

  final String sourceLink;

  /// Number of social media search results found (Instagram, TikTok,
  /// Facebook, YouTube, X, Threads). -1 means not checked / check failed.
  final int buzzScore;

  /// Human-readable label derived from [buzzScore], e.g.
  /// "🔥 Sangat ramai dibicarakan" (kept in Indonesian for Telegram output).
  final String buzzLabel;

  /// Platforms where this merchant/promo was found being discussed.
  final List<String> buzzPlatforms;

  Promo({
    required this.category,
    required this.merchant,
    required this.promoTitle,
    required this.discount,
    this.discountType = '',
    this.discountAmount,
    required this.terms,
    required this.expiryDate,
    this.expiryDateIso = '',
    this.evidenceQuote = '',
    required this.sourceLink,
    this.buzzScore = -1,
    this.buzzLabel = 'Belum dicek',
    this.buzzPlatforms = const [],
  });

  /// Returns a copy of this promo with buzz data filled in.
  Promo copyWithBuzz({
    required int buzzScore,
    required String buzzLabel,
    required List<String> buzzPlatforms,
  }) =>
      Promo(
        category: category,
        merchant: merchant,
        promoTitle: promoTitle,
        discount: discount,
        discountType: discountType,
        discountAmount: discountAmount,
        terms: terms,
        expiryDate: expiryDate,
        expiryDateIso: expiryDateIso,
        evidenceQuote: evidenceQuote,
        sourceLink: sourceLink,
        buzzScore: buzzScore,
        buzzLabel: buzzLabel,
        buzzPlatforms: buzzPlatforms,
      );

  /// Returns a copy with the given field overridden (used by fuzzy dedup to
  /// normalize a merchant alias to its representative name).
  Promo copyWith({String? merchant}) => Promo(
        category: category,
        merchant: merchant ?? this.merchant,
        promoTitle: promoTitle,
        discount: discount,
        discountType: discountType,
        discountAmount: discountAmount,
        terms: terms,
        expiryDate: expiryDate,
        expiryDateIso: expiryDateIso,
        evidenceQuote: evidenceQuote,
        sourceLink: sourceLink,
        buzzScore: buzzScore,
        buzzLabel: buzzLabel,
        buzzPlatforms: buzzPlatforms,
      );

  factory Promo.fromJson(Map<String, dynamic> json) {
    return Promo(
      category: json['category']?.toString() ?? '-',
      merchant: json['merchant']?.toString() ?? '-',
      promoTitle: json['promo_title']?.toString() ?? '-',
      discount: json['discount']?.toString() ?? '-',
      discountType: json['discount_type']?.toString() ?? '',
      discountAmount: (json['discount_amount'] as num?)?.toDouble(),
      terms: json['terms']?.toString() ?? '',
      expiryDate: json['expiry_date']?.toString() ?? 'Tidak disebutkan',
      expiryDateIso: json['expiry_date_iso']?.toString() ?? '',
      evidenceQuote: json['evidence_quote']?.toString() ?? '',
      sourceLink: json['source_link']?.toString() ?? '',
      buzzScore: json['buzz_score'] is int ? json['buzz_score'] as int : -1,
      buzzLabel: json['buzz_label']?.toString() ?? 'Belum dicek',
      buzzPlatforms: (json['buzz_platforms'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'category': category,
        'merchant': merchant,
        'promo_title': promoTitle,
        'discount': discount,
        'discount_type': discountType,
        'discount_amount': discountAmount,
        'terms': terms,
        'expiry_date': expiryDate,
        'expiry_date_iso': expiryDateIso,
        'evidence_quote': evidenceQuote,
        'source_link': sourceLink,
        'buzz_score': buzzScore,
        'buzz_label': buzzLabel,
        'buzz_platforms': buzzPlatforms,
      };
}
