import 'dart:io';

import 'package:harness/config.dart';
import 'package:harness/core/promo_orchestrator.dart';
import 'package:harness/flows/promo_flow.dart';
import 'package:harness/services/serpapi_client.dart';
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

  final serpapi = SerpApiClient(apiKey: config.serpapiKey);
  final promoFlow = PromoFlow(geminiApiKey: config.geminiApiKey, serpapi: serpapi);
  final orchestrator = PromoOrchestrator(
    serpapi: serpapi,
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

    final allPromos = await orchestrator.runDefault(region: config.region);

    stdout.writeln('[harness] Extracted ${allPromos.length} promos in total.');

    final savedFile = await storage.saveWeekly(allPromos);
    stdout.writeln('[harness] History saved to: ${savedFile.path}');

    await telegram.sendPromoSummary(
      allPromos,
      title: 'Rangkuman Promo Mingguan',
      subtitle: config.region,
    );
    stdout.writeln('[harness] Telegram notification sent. Done.');
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
    serpapi.close();
    telegram.close();
  }
}
