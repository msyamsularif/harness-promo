import '../core/promo_constants.dart';
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

  static const _parentOrder = ['F&B', 'Lifestyle'];
  static const _subCategoryOrder = ['Makanan', 'Minuman', 'Jajanan'];

  /// Builds promo summary into one or more HTML-formatted Telegram messages,
  /// grouped by parent category (F&B then Lifestyle) with sub-category
  /// sections and per-merchant grouping.
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

    final messages = <String>[];

    final header = StringBuffer('📍 <b>${escapeHtml(title)}</b>\n');
    if (subtitle != null && subtitle.isNotEmpty) {
      header.writeln('<i>${escapeHtml(subtitle)}</i>\n');
    }

    if (promos.isEmpty) {
      header.writeln('Tidak ditemukan promo yang relevan untuk pencarian ini.');
      messages.add(header.toString());
      return messages;
    }

    header.writeln('Total ${promos.length} promo ditemukan.\n');

    final parents = <String, List<String>>{};
    for (final category in grouped.keys) {
      final parent = categoryParentMap[category] ?? category;
      parents.putIfAbsent(parent, () => []).add(category);
    }

    final orderedParents = [
      ..._parentOrder.where(parents.containsKey),
      ...(parents.keys.where((p) => !_parentOrder.contains(p)).toList()..sort()),
    ];

    var isFirstSection = true;

    for (final parent in orderedParents) {
      var categoryKeys = parents[parent]!;
      categoryKeys = [
        ..._subCategoryOrder.where(categoryKeys.contains),
        ...categoryKeys.where((k) => !_subCategoryOrder.contains(k)),
      ];

      final totalParent =
          categoryKeys.fold<int>(0, (sum, k) => sum + grouped[k]!.length);

      var buffer = StringBuffer();
      if (isFirstSection) {
        buffer.write(header.toString());
        isFirstSection = false;
      }

      buffer.writeln('━━━━━━━━━━━━━━━━━━━━');
      buffer.writeln(
          '${_parentEmoji(parent)} <b>KATEGORI: ${escapeHtml(parent.toUpperCase())}</b>  ($totalParent promo)');
      buffer.writeln('━━━━━━━━━━━━━━━━━━━━\n');

      final showSubHeader = categoryKeys.length > 1;

      for (final category in categoryKeys) {
        final items = grouped[category]!;

        if (showSubHeader) {
          buffer.writeln(
              '${_subCategoryEmoji(category)} <b>${escapeHtml(category)}</b> (${items.length})\n');
        }

        final merchantGroups = <String, List<Promo>>{};
        final merchantNames = <String, String>{};
        for (final p in items) {
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

        buffer.writeln();
      }

      messages.add(buffer.toString());
    }

    return messages;
  }

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

  String _parentEmoji(String parent) {
    switch (parent) {
      case 'F&B':
        return '🍽';
      case 'Lifestyle':
        return '🛍';
      default:
        return '📦';
    }
  }

  String _subCategoryEmoji(String category) {
    switch (category) {
      case 'Makanan':
        return '🍛';
      case 'Minuman':
        return '☕';
      case 'Jajanan':
        return '🍿';
      default:
        return '•';
    }
  }
}
