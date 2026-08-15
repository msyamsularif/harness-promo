import 'dart:convert';
import 'dart:io';

import 'package:harness/config.dart';
import 'package:harness/core/promo_orchestrator.dart';
import 'package:harness/flows/promo_flow.dart';
import 'package:harness/services/search_fallback_client.dart';
import 'package:harness/services/telegram_notify.dart';
import 'package:harness/storage/seen_promos_store.dart';
import 'package:http/http.dart' as http;

/// Parses and executes incoming bot commands, separating command logic
/// from the long-polling loop.
class BotCommandHandler {
  final PromoOrchestrator _orchestrator;
  final TelegramNotify _telegram;

  BotCommandHandler({
    required PromoOrchestrator orchestrator,
    required TelegramNotify telegram,
  })  : _orchestrator = orchestrator,
        _telegram = telegram;

  Future<void> handle(String text) async {
    if (text.startsWith('/help') || text.startsWith('/start')) {
      await _telegram.sendPlainMessage(_helpText);
      return;
    }

    if (!text.startsWith('/promo')) {
      // Ignore messages that aren't a recognized command, so the bot
      // doesn't reply noisily to every casual chat.
      return;
    }

    final args = text.replaceFirst('/promo', '').trim();
    if (args.isEmpty) {
      await _telegram.sendPlainMessage(
        'Format: <code>/promo &lt;lokasi&gt; [fnb|makanan|minuman|jajanan|lifestyle]</code>\n'
        'Contoh: <code>/promo Bandung</code>\n'
        'Contoh: <code>/promo Surabaya fnb</code>\n'
        'Contoh: <code>/promo Malang minuman</code>',
      );
      return;
    }

    final parts = args.split(RegExp(r'\s+'));
    List<String>? categoryFilter;
    var locationParts = parts;

    final lastWord = parts.last.toLowerCase();
    switch (lastWord) {
      case 'fnb':
      case 'f&b':
        categoryFilter = ['Makanan', 'Minuman', 'Jajanan'];
        locationParts = parts.sublist(0, parts.length - 1);
        break;
      case 'makanan':
        categoryFilter = ['Makanan'];
        locationParts = parts.sublist(0, parts.length - 1);
        break;
      case 'minuman':
        categoryFilter = ['Minuman'];
        locationParts = parts.sublist(0, parts.length - 1);
        break;
      case 'jajanan':
        categoryFilter = ['Jajanan'];
        locationParts = parts.sublist(0, parts.length - 1);
        break;
      case 'lifestyle':
        categoryFilter = ['Lifestyle'];
        locationParts = parts.sublist(0, parts.length - 1);
        break;
    }

    final location = locationParts.join(' ').trim();
    if (location.isEmpty) {
      await _telegram.sendPlainMessage(
          'Lokasi tidak boleh kosong. Contoh: <code>/promo Bandung</code>');
      return;
    }

    final categoryLabel =
        categoryFilter != null ? ' (${categoryFilter.join(', ')})' : '';
    await _telegram.sendPlainMessage(
        '🔎 Mencari promo untuk "$location"$categoryLabel... mohon tunggu sebentar.');

    try {
      final promos = await _orchestrator.runForLocation(
        location,
        categoryList: categoryFilter,
      );

      await _telegram.sendPromoSummary(
        promos,
        title: 'Promo untuk "$location"',
        subtitle: 'Hasil pencarian on-demand',
      );
    } catch (e) {
      await _telegram.sendError('Gagal mencari promo untuk "$location": $e');
    }
  }
}

const _helpText = '''
🤖 <b>Harness Promo Bot</b>

Perintah yang tersedia:
<code>/promo &lt;lokasi&gt;</code> — cari semua kategori (Makanan, Minuman, Jajanan, Lifestyle)
<code>/promo &lt;lokasi&gt; fnb</code> — cari Makanan, Minuman, &amp; Jajanan saja
<code>/promo &lt;lokasi&gt; makanan</code> — cari promo Makanan saja
<code>/promo &lt;lokasi&gt; minuman</code> — cari promo Minuman (termasuk kopi) saja
<code>/promo &lt;lokasi&gt; jajanan</code> — cari promo Jajanan/snack saja
<code>/promo &lt;lokasi&gt; lifestyle</code> — cari promo Lifestyle saja

Contoh:
<code>/promo Bandung</code>
<code>/promo Surabaya fnb</code>
<code>/promo Malang minuman</code>

Catatan: rangkuman mingguan otomatis (wilayah Jabodetabek) tetap jalan
terpisah lewat cron, tidak terpengaruh oleh bot ini.
''';

/// Entry point SEPARATE from the weekly cron job (bin/harness.dart).
///
/// This process runs CONTINUOUSLY (long polling against Telegram
/// getUpdates), waiting for the user to send a command such as:
///   /promo Bandung
///   /promo Surabaya fnb
///   /promo Malang minuman
///   /help
///
/// How to run: SEE README section "Bot listener (on-demand)" — run as a
/// background process (e.g. via systemd or nohup), NOT via crontab.
Future<void> main() async {
  late final Config config;
  try {
    config = Config.load();
  } catch (e) {
    stderr.writeln('Failed to load configuration: $e');
    exit(1);
  }

  final search = buildSearchClient(
    tavilyApiKey: config.tavilyApiKey,
    serperApiKey: config.serperApiKey,
    serpapiApiKey: config.serpapiKey,
  );
  final promoFlow = PromoFlow(
      geminiApiKey: config.geminiApiKey,
      openRouterApiKey: config.openRouterApiKey,
      fallbackModel: config.fallbackModel,
      search: search);
  final orchestrator = PromoOrchestrator(
    search: search,
    promoFlow: promoFlow,
    enableBuzzCheck: config.enableBuzzCheck,
    enableLinkValidation: config.enableLinkValidation,
    dedupStore: SeenPromosStore(outputDir: config.outputDir),
  );
  final telegram = TelegramNotify(
    botToken: config.telegramBotToken,
    chatId: config.telegramChatId,
  );
  final handler = BotCommandHandler(
    orchestrator: orchestrator,
    telegram: telegram,
  );

  final offsetFile = File('.bot_offset');
  int offset = 0;
  if (offsetFile.existsSync()) {
    offset = int.tryParse(offsetFile.readAsStringSync().trim()) ?? 0;
  }

  stdout.writeln('[bot_listener] Starting Telegram polling... (Ctrl+C to stop)');

  while (true) {
    try {
      final updates = await _getUpdates(config.telegramBotToken, offset);

      for (final update in updates) {
        offset = (update['update_id'] as int) + 1;
        offsetFile.writeAsStringSync(offset.toString());

        final message = update['message'] as Map<String, dynamic>?;
        if (message == null) continue;

        final msgChatId = message['chat']?['id']?.toString();
        final text = (message['text'] as String?)?.trim() ?? '';

        // Only process messages from the configured chat (TG_CHAT_ID),
        // so the bot doesn't respond to other chats/people.
        if (msgChatId != config.telegramChatId) continue;
        if (text.isEmpty) continue;

        await handler.handle(text);
      }
    } catch (e, st) {
      stderr.writeln('[bot_listener] Error while polling: $e\n$st');
      await Future<void>.delayed(const Duration(seconds: 5));
    }
  }
}

Future<List<dynamic>> _getUpdates(String token, int offset) async {
  final uri = Uri.https('api.telegram.org', '/bot$token/getUpdates', {
    'offset': offset.toString(),
    'timeout': '30', // long polling: wait up to 30s for new updates
  });

  // Slightly longer than the long-poll timeout param above.
  final res = await http.get(uri).timeout(const Duration(seconds: 40));

  if (res.statusCode != 200) {
    throw Exception('getUpdates failed (${res.statusCode}): ${res.body}');
  }

  final body = jsonDecode(res.body) as Map<String, dynamic>;
  return (body['result'] as List<dynamic>?) ?? [];
}
