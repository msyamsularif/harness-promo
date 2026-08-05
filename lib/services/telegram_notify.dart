import 'package:http/http.dart' as http;

import '../models/promo.dart';
import '../core/promo_orchestrator.dart' show categoryParentMap;

/// Formats and sends promo summaries to Telegram.
///
/// NOTE: all user-facing text in this file is written in Bahasa Indonesia
/// on purpose — this is the actual content delivered to the end user via
/// Telegram, which is explicitly allowed (and expected) to stay Indonesian
/// even though the rest of the codebase's comments/docs are in English.
class TelegramNotify {
  final String botToken;
  final String chatId;
  final http.Client _http;

  static const _maxCharsPerMessage = 3500;

  // Display order for parent categories and F&B sub-categories.
  static const _parentOrder = ['F&B', 'Lifestyle'];
  static const _subCategoryOrder = ['Makanan', 'Minuman', 'Jajanan'];

  TelegramNotify({
    required this.botToken,
    required this.chatId,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  /// Sends a promo summary, neatly grouped: F&B (with Makanan/Minuman/
  /// Jajanan sub-sections) then Lifestyle.
  ///
  /// [title] main title (e.g. "Rangkuman Promo Mingguan").
  /// [subtitle] optional second line (e.g. "Jabodetabek").
  Future<void> sendPromoSummary(
    List<Promo> promos, {
    String title = 'Rangkuman Promo Mingguan',
    String? subtitle,
  }) async {
    final messages = _buildMessages(title: title, subtitle: subtitle, promos: promos);
    for (final msg in messages) {
      await _sendRaw(msg);
    }
  }

  /// Sends a plain text message (used by the bot listener for status,
  /// error, or usage-instruction replies). The text is assumed to already
  /// be safely escaped by the caller if it contains dynamic data.
  Future<void> sendPlainMessage(String text) => _sendRaw(text);

  Future<void> sendError(String errorMessage) async {
    await _sendRaw('⚠️ <b>Harness gagal jalan</b>\n${_escapeHtml(errorMessage)}');
  }

  List<String> _buildMessages({
    required String title,
    String? subtitle,
    required List<Promo> promos,
  }) {
    final grouped = <String, List<Promo>>{};
    for (final p in promos) {
      grouped.putIfAbsent(p.category, () => []).add(p);
    }

    final messages = <String>[];

    final header = StringBuffer('📍 <b>${_escapeHtml(title)}</b>\n');
    if (subtitle != null && subtitle.isNotEmpty) {
      header.writeln('<i>${_escapeHtml(subtitle)}</i>\n');
    }

    if (promos.isEmpty) {
      header.writeln('Tidak ditemukan promo yang relevan untuk pencarian ini.');
      messages.add(header.toString());
      return messages;
    }

    header.writeln('Total ${promos.length} promo ditemukan.\n');

    // Group sub-categories under their parent (F&B/Lifestyle).
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
          '${_parentEmoji(parent)} <b>KATEGORI: ${_escapeHtml(parent.toUpperCase())}</b>  ($totalParent promo)');
      buffer.writeln('━━━━━━━━━━━━━━━━━━━━\n');

      // Sub-header is only shown when this parent has more than one
      // sub-category (i.e. F&B).
      final showSubHeader = categoryKeys.length > 1;

      for (final category in categoryKeys) {
        final items = grouped[category]!;

        if (showSubHeader) {
          buffer.writeln(
              '${_subCategoryEmoji(category)} <b>${_escapeHtml(category)}</b> (${items.length})\n');
        }

        for (var i = 0; i < items.length; i++) {
          final p = items[i];
          final entry = StringBuffer()
            ..writeln('<b>${i + 1}. ${_escapeHtml(p.merchant)}</b>')
            ..writeln('💰 Diskon: ${_escapeHtml(p.discount)}')
            ..writeln('📝 Promo: ${_escapeHtml(p.promoTitle)}');

          entry.writeln(
            '📋 S&amp;K: ${p.terms.isNotEmpty ? _escapeHtml(p.terms) : 'Tidak disebutkan di sumber'}',
          );
          entry.writeln('⏰ Berlaku s/d: ${_escapeHtml(p.expiryDate)}');

          if (p.buzzScore >= 0) {
            final platformsStr = p.buzzPlatforms.isNotEmpty
                ? ' (${p.buzzPlatforms.join(", ")})'
                : '';
            entry.writeln('📊 ${_escapeHtml(p.buzzLabel)}$platformsStr');
          }

          if (p.sourceLink.isNotEmpty) {
            entry.writeln('🔗 <a href="${_escapeHtml(p.sourceLink)}">Lihat sumber</a>');
          }
          entry.writeln();

          if (buffer.length + entry.length > _maxCharsPerMessage) {
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

  // Telegram HTML mode only needs these 3 characters escaped (much simpler
  // & safer than MarkdownV2). Order matters: '&' first, then '<' and '>',
  // so the resulting entities don't get double-escaped.
  String _escapeHtml(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  Future<void> _sendRaw(String text) async {
    final uri = Uri.https('api.telegram.org', '/bot$botToken/sendMessage');

    final res = await _http.post(uri, body: {
      'chat_id': chatId,
      'text': text,
      'parse_mode': 'HTML',
      'disable_web_page_preview': 'true',
    });

    if (res.statusCode != 200) {
      throw Exception('Failed to send to Telegram (${res.statusCode}): ${res.body}');
    }
  }

  void close() => _http.close();
}
