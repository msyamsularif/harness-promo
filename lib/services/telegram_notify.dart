import 'package:http/http.dart' as http;

import '../models/promo.dart';
import 'telegram_formatter.dart';

/// Sends formatted promo summaries to Telegram.
///
/// NOTE: all user-facing text in this file is written in Bahasa Indonesia
/// on purpose — this is the actual content delivered to the end user via
/// Telegram, which is explicitly allowed (and expected) to stay Indonesian
/// even though the rest of the codebase's comments/docs are in English.
class TelegramNotify {
  final String botToken;
  final String chatId;
  final http.Client _http;
  final PromoMessageFormatter _formatter = PromoMessageFormatter();

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
    final messages = _formatter.formatSummary(
      title: title,
      subtitle: subtitle,
      promos: promos,
    );
    for (final msg in messages) {
      await _sendRaw(msg);
    }
  }

  /// Sends a plain text message (used by the bot listener for status,
  /// error, or usage-instruction replies). The text is assumed to already
  /// be safely escaped by the caller if it contains dynamic data.
  Future<void> sendPlainMessage(String text) => _sendRaw(text);

  Future<void> sendError(String errorMessage) async {
    await _sendRaw(
        '⚠️ <b>Harness gagal jalan</b>\n${escapeHtml(errorMessage)}');
  }

  Future<void> _sendRaw(String text) async {
    final uri = Uri.https('api.telegram.org', '/bot$botToken/sendMessage');

    final res = await _http.post(uri, body: {
      'chat_id': chatId,
      'text': text,
      'parse_mode': 'HTML',
      'disable_web_page_preview': 'true',
    });

    if (res.statusCode != 200) {
      throw Exception(
          'Failed to send to Telegram (${res.statusCode}): ${res.body}');
    }
  }

  void close() => _http.close();
}
