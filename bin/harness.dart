import 'dart:io';

import 'package:harness/config.dart';
import 'package:harness/core/promo_orchestrator.dart';
import 'package:harness/flows/promo_flow.dart';
import 'package:harness/services/search_fallback_client.dart';
import 'package:harness/services/telegram_formatter.dart';
import 'package:harness/services/telegram_notify.dart';
import 'package:harness/storage/promo_storage.dart';

/// Entry point for the weekly cron job. Searches for Makanan, Minuman,
/// Jajanan, and Lifestyle promos for a single main region (default:
/// Jabodetabek).
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
  );
  final storage = PromoStorage(outputPath: config.outputDir);
  final telegram = TelegramNotify(
    botToken: config.telegramBotToken,
    chatId: config.telegramChatId,
  );

  try {
    stdout.writeln('[harness] Searching promos for region: ${config.region}');

    // Let the user know the run is in progress (it can take a few minutes).
    await telegram.sendPlainMessage(
        '🔎 <b>Harness Promo</b>\n'
        'Sedang mencari promo mingguan untuk <i>${escapeHtml(config.region)}</i>... '
        'mohon tunggu sebentar.');

    final allPromos = await orchestrator.runDefault(
      region: config.region,
      onCategoryComplete: (category, promos) async {
        if (promos.isEmpty) {
          await telegram.sendPlainMessage(
              '${escapeHtml(category)}: tidak ditemukan promo.');
          return;
        }
        await telegram.sendCategorySummary(category, promos);
      },
    );

    stdout.writeln('[harness] Extracted ${allPromos.length} promos in total.');

    final savedFile = await storage.saveWeekly(allPromos);
    stdout.writeln('[harness] History saved to: ${savedFile.path}');

    stdout.writeln('[harness] Done.');
  } catch (e, stackTrace) {
    stderr.writeln('[harness] ERROR: $e\n$stackTrace');
    try {
      await telegram.sendError(e.toString());
    } catch (_) {
      // If sending the error notification also fails (e.g. bad token),
      // just rely on stderr / the cron log.txt.
    }
    exit(1);
  } finally {
    search.close();
    telegram.close();
  }
}
