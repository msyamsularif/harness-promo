import '../models/promo.dart';

/// Telegram HTML only needs these 3 characters escaped (much simpler
/// & safer than MarkdownV2). Order matters: '&' first, then '<' and '>',
/// so the resulting entities don't get double-escaped.
String escapeHtml(String text) =>
    text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// Pure formatting logic for promo summaries. Extracted from TelegramNotify
/// so the sender stays thin and focused on HTTP delivery only.
class PromoMessageFormatter {
  static const maxCharsPerMessage = 3500;

  static const _subCategoryOrder = ['Makanan', 'Minuman', 'Jajanan'];

  /// Builds the promo summary into one or more HTML-formatted Telegram
  /// messages, ONE MESSAGE PER SUB-CATEGORY (Makanan, Minuman, Jajanan,
  /// Lifestyle, ...). The title/subtitle header is prepended to the first
  /// category message.
  ///
  /// Returns a list of message strings, each ≤ [maxCharsPerMessage].
  List<String> formatSummary({
    required String title,
    String? subtitle,
    required List<Promo> promos,
  }) {
    final grouped = <String, List<Promo>>{};
    for (final p in promos) {
      grouped.putIfAbsent(p.category, () => []).add(p);
    }

    if (promos.isEmpty) {
      final header = _buildHeader(title, subtitle, 0);
      header.writeln('Tidak ditemukan promo yang relevan untuk pencarian ini.');
      return [header.toString()];
    }

    final categories = _orderedCategories(grouped.keys.toList());
    final messages = <String>[];

    for (var i = 0; i < categories.length; i++) {
      final category = categories[i];
      final msgs = formatCategory(category, grouped[category]!);
      if (i == 0 && msgs.isNotEmpty) {
        msgs[0] = _buildHeader(title, subtitle, promos.length).toString() + msgs[0];
      }
      messages.addAll(msgs);
    }

    return messages;
  }

  /// Formats a single sub-category into one or more messages (split on
  /// [maxCharsPerMessage] if a single category grows too large).
  List<String> formatCategory(String category, List<Promo> promos) {
    final messages = <String>[];
    var buffer = StringBuffer();

    buffer.writeln('━━━━━━━━━━━━━━━━━━━━');
    buffer.writeln(
        '${_subCategoryEmoji(category)} <b>${escapeHtml(category.toUpperCase())}</b> (${promos.length} promo)');
    buffer.writeln('━━━━━━━━━━━━━━━━━━━━\n');

    final merchantGroups = <String, List<Promo>>{};
    final merchantNames = <String, String>{};
    for (final p in promos) {
      final key = p.merchantKey;
      merchantGroups.putIfAbsent(key, () => []).add(p);
      merchantNames.putIfAbsent(key, () => p.merchant.trim());
    }

    var sectionNumber = 0;
    for (final group in merchantGroups.entries) {
      sectionNumber++;
      final merchantPromos = group.value;
      final merchantName = merchantNames[group.key]!;

      final entry = StringBuffer();
      if (merchantPromos.length == 1) {
        final p = merchantPromos.first;
        entry.writeln(
            '<b>$sectionNumber. ${escapeHtml(merchantName)}</b>');
        entry.writeln('💰 Diskon: ${escapeHtml(p.discount)}');
        entry.writeln('📝 Promo: ${escapeHtml(p.promoTitle)}');
        _appendTermsAndExpiry(entry, p);
        _appendBuzz(entry, p);
        _appendSourceLink(entry, p);
      } else {
        entry.writeln(
            '<b>$sectionNumber. ${escapeHtml(merchantName)}</b> (${merchantPromos.length} promo)');
        for (var j = 0; j < merchantPromos.length; j++) {
          final p = merchantPromos[j];
          entry.writeln(
              '🔹 <b>Promo ${j + 1}:</b> ${escapeHtml(p.promoTitle)}');
          entry.writeln('💰 Diskon: ${escapeHtml(p.discount)}');
          _appendTermsAndExpiry(entry, p);
          _appendSourceLink(entry, p);
        }
        _appendBuzz(entry, merchantPromos.first);
      }
      entry.writeln();

      if (buffer.length + entry.length > maxCharsPerMessage) {
        messages.add(buffer.toString());
        buffer = StringBuffer();
      }
      buffer.write(entry.toString());
    }

    if (buffer.isNotEmpty) {
      messages.add(buffer.toString());
    }
    return messages;
  }

  StringBuffer _buildHeader(String title, String? subtitle, int total) {
    final header = StringBuffer('📍 <b>${escapeHtml(title)}</b>\n');
    if (subtitle != null && subtitle.isNotEmpty) {
      header.writeln('<i>${escapeHtml(subtitle)}</i>\n');
    }
    if (total > 0) {
      header.writeln('Total $total promo ditemukan.\n');
    }
    return header;
  }

  List<String> _orderedCategories(List<String> keys) => [
        ..._subCategoryOrder.where(keys.contains),
        ...(keys.where((k) => !_subCategoryOrder.contains(k)).toList()..sort()),
      ];

  void _appendTermsAndExpiry(StringBuffer buf, Promo p) {
    buf.writeln(
      '📋 S&amp;K: ${p.terms.isNotEmpty ? escapeHtml(p.terms) : 'Tidak disebutkan di sumber'}',
    );
    buf.writeln('⏰ Berlaku s/d: ${escapeHtml(p.expiryDate)}');
  }

  void _appendBuzz(StringBuffer buf, Promo p) {
    if (p.buzzScore < 0) return;
    final platformsStr =
        p.buzzPlatforms.isNotEmpty ? ' (${p.buzzPlatforms.join(", ")})' : '';
    buf.writeln('📊 ${escapeHtml(p.buzzLabel)}$platformsStr');
  }

  void _appendSourceLink(StringBuffer buf, Promo p) {
    if (p.sourceLink.isEmpty) return;
    buf.writeln(
        '🔗 <a href="${escapeHtml(p.sourceLink)}">Lihat sumber</a>');
  }

  String _subCategoryEmoji(String category) {
    switch (category) {
      case 'Makanan':
        return '🍛';
      case 'Minuman':
        return '☕';
      case 'Jajanan':
        return '🍿';
      case 'Lifestyle':
        return '🛍';
      default:
        return '•';
    }
  }
}
