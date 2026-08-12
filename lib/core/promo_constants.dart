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
