/// Static brand tier data for the composite score (see `promo_scoring.dart`).
///
/// Bigger, more recognizable brands get a higher tier because they're more
/// interesting to the user and more likely to be a genuine, high-quality
/// promo. This is pure data + a cheap substring lookup — no API calls, no
/// model, and it lives inline in the AOT binary (a few hundred bytes).
///
/// Matching is `contains` against a normalized (lowercase, punctuation
/// stripped) merchant name, so "McDonald's Indonesia" still matches
/// "mcdonalds". Keep these lists small and additive; tune them as you see
/// new brands appear in the weekly output.

/// Returns the tier value (0..1) for [merchant]. Unknown/independent
/// merchants get a small but non-zero baseline so they still rank, just
/// below recognized big brands.
double brandTier(String merchant) {
  final name = _normalize(merchant);
  if (name.isEmpty) return _tierDefault;
  for (final entry in _tier1) {
    if (_matches(name, entry)) return 1.0;
  }
  for (final entry in _tier2) {
    if (_matches(name, entry)) return 0.6;
  }
  return _tierDefault;
}

/// True when the normalized [name] matches a tier [entry]. An entry may
/// carry a nickname in parentheses ("Hoka Hoka Bento (Hokben)") — each
/// parenthesized part becomes a separate alias, any of which can match.
bool _matches(String name, String entry) =>
    _aliases(entry).any((alias) => _containsAllWords(name, alias));

/// Splits an entry on parentheses and normalizes each part into an alias.
List<String> _aliases(String entry) => entry
    .split(RegExp(r'[()]'))
    .map(_normalize)
    .where((alias) => alias.isNotEmpty)
    .toList();

/// True when every word in [alias] appears in [name] (allowing [name] to
/// carry extra words). Very short words (<= 2 chars, e.g. "H&M" -> "hm")
/// must match a whole token instead, to avoid substring false positives.
bool _containsAllWords(String name, String alias) {
  final nameTokens = name.split(' ').toSet();
  for (final word in alias.split(' ')) {
    if (word.length <= 2) {
      if (!nameTokens.contains(word)) return false;
    } else if (!name.contains(word)) {
      return false;
    }
  }
  return true;
}

const double _tierDefault = 0.3;

/// Big national/international brands (score 1.0).
const _tier1 = [
  // -- Makanan (fast food & resto besar, ribuan gerai atau ratusan gerai) --
  'KFC',
  'McDonald\'s',
  'Burger King',
  'Pizza Hut',
  'Domino\'s Pizza',
  'Texas Chicken',
  'CFC',
  'A&W',
  'Hoka Hoka Bento (Hokben)',
  'Solaria',
  'Es Teler 77',
  'Wendy\'s',
  'Richeese Factory',

  // -- Minuman (kopi & minuman kekinian dengan ekspansi masif) --
  'Starbucks',
  'Kopi Kenangan',
  'Janji Jiwa',
  'Chatime',
  'Es Teh Indonesia',
  'Mixue',
  'Gulu Gulu',
  'Fore Coffee',
  'Kopi Tuku',
  'Excelso',
  'Haus!',

  // -- Jajanan (donat, roti besar, nasional) --
  'J.CO Donuts & Coffee',
  'Dunkin\'',
  'Breadtalk',
  'Sari Roti',
  'Holland Bakery',

  // -- Lifestyle: Minimarket & Retail raksasa (puluhan ribu gerai) --
  'Indomaret',
  'Alfamart',
  'Alfamidi',
  'Circle K',
  'FamilyMart',
  'Lawson',
  'Superindo',

  // -- Lifestyle: Department store, hypermarket, fashion, elektronik --
  'Matahari Department Store',
  'Ramayana',
  'Transmart',
  'Hypermart',
  'Ranch Market',
  'Uniqlo',
  'H&M',
  'Zara',
  'Ace Hardware',
  'Informa',
  'IKEA',
  'Erafone',
  'iBox',
];

/// Well-known mid-tier brands (score 0.6).
const _tier2 = [
  // -- Makanan: chain nasional/regional dengan ratusan cabang --
  'Waroeng Steak & Shake (Waroeng SS)',
  'Warunk Upnormal',
  'Rocket Chicken',
  'Sabana Fried Chicken',
  'Ayam Geprek Bensu',
  'Bebek Kaleyo',
  'Bakso Boedjangan',
  'Sate Khas Senayan',
  'Sushi Tei',
  'Marugame Udon',
  'Yoshinoya',
  'Bakmi GM',
  'Ta Wan',
  'Pepper Lunch',
  'Genki Sushi',
  'Platinum Grill',
  'Kebab Turki Baba Rafi',
  'Bakso Lava',
  'Cek Toko Sebelah',
  'Ayam Geprek Sa\'i',

  // -- Minuman: chain kopi/minuman kekinian dengan puluhan-ratusan cabang --
  'Kedai Kopi Kulo',
  'Coffee Toffee',
  'Tomoro Coffee',
  'Point Coffee',
  'Flash Coffee',
  'Xi Bo Ba',
  'Kopi Soe',
  'Anomali Coffee',
  'Kopi Nako',
  'Gong Cha',
  'Xing Fu Tang',
  'The Alley',
  'Sour Sally',
  'CoCo Fresh Tea & Juice',

  // -- Jajanan: chain roti/martabak/dessert dengan cabang banyak --
  'Martabak Bangka 68',
  'Martabak Boss',
  'Auntie Anne\'s',
  'Mister Donut',
  'Baskin Robbins',
  'Diamond Ice Cream',
  'Aice',
  'Campina',
  'Cimory',

  // -- Lifestyle: retail/kesehatan/fashion dengan cabang banyak --
  'Miniso',
  'Watsons',
  'Guardian',
  'Kimia Farma (apotek)',
  'Century Healthcare',
  'Natasha Skin Care',
  'Erha Clinic',
  'Sociolla',
  'Sport Station',
  'Planet Sports',
  'Digimap',
  'Cotton On',
  'Pull&Bear',
  'Stradivarius',
  'The Executive',
];

String _normalize(String name) => name
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9 ]'), '')
    .replaceAll(
      RegExp(r'\s+'),
      ' ',
    )
    .trim();
