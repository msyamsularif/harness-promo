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
  final String terms;
  final String expiryDate; // free-form string, e.g. "31 August 2026" / "Not specified"
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
    required this.terms,
    required this.expiryDate,
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
        terms: terms,
        expiryDate: expiryDate,
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
      terms: json['terms']?.toString() ?? '',
      expiryDate: json['expiry_date']?.toString() ?? 'Tidak disebutkan',
      sourceLink: json['source_link']?.toString() ?? '',
      buzzScore: json['buzz_score'] is int ? json['buzz_score'] as int : -1,
      buzzLabel: json['buzz_label']?.toString() ?? 'Belum dicek',
      buzzPlatforms: (json['buzz_platforms'] as List?)
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
        'terms': terms,
        'expiry_date': expiryDate,
        'source_link': sourceLink,
        'buzz_score': buzzScore,
        'buzz_label': buzzLabel,
        'buzz_platforms': buzzPlatforms,
      };
}
