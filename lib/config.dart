import 'dart:io';

import 'package:dotenv/dotenv.dart';

/// Loads configuration from a ".env" file (if present, for local
/// development) or from OS environment variables (for cron/service runs).
class Config {
  final String geminiApiKey;
  final String? groqApiKey;
  final String serpapiKey;
  final String telegramBotToken;
  final String telegramChatId;
  final String outputDir;

  /// Main region for the default weekly search (cron), e.g. "Jabodetabek".
  final String region;

  /// Enables the "how much is this being talked about" social buzz check.
  /// Adds 1 extra SerpApi call per promo — disable via .env
  /// (ENABLE_BUZZ_CHECK=false) to save quota.
  final bool enableBuzzCheck;

  /// Enables filtering out promos whose source link is unreachable.
  /// Disable via .env (ENABLE_LINK_VALIDATION=false) if this causes too
  /// many false negatives (some sites block bot-like requests).
  final bool enableLinkValidation;

  Config._({
    required this.geminiApiKey,
    required this.groqApiKey,
    required this.serpapiKey,
    required this.telegramBotToken,
    required this.telegramChatId,
    required this.outputDir,
    required this.region,
    required this.enableBuzzCheck,
    required this.enableLinkValidation,
  });

  factory Config.load() {
    final env = DotEnv(includePlatformEnvironment: true);
    final envFile = File('.env');
    if (envFile.existsSync()) {
      env.load(['.env']);
    }

    String require(String key) {
      final value = env[key];
      if (value == null || value.isEmpty) {
        throw Exception(
            'Environment variable "$key" is not set. Check your .env file or crontab.');
      }
      return value;
    }

    String orDefault(String key, String defaultValue) {
      final value = env[key];
      if (value == null || value.trim().isEmpty) return defaultValue;
      return value;
    }

    bool boolOrDefault(String key, bool defaultValue) {
      final value = env[key];
      if (value == null || value.trim().isEmpty) return defaultValue;
      return value.trim().toLowerCase() != 'false';
    }

    return Config._(
      geminiApiKey: require('GEMINI_API_KEY'),
      groqApiKey: env['GROQ_API_KEY'],
      serpapiKey: require('SERPAPI_KEY'),
      telegramBotToken: require('TG_BOT_TOKEN'),
      telegramChatId: require('TG_CHAT_ID'),
      outputDir: orDefault('OUTPUT_DIR', './harness-data'),
      region: orDefault('REGION', 'Jabodetabek'),
      enableBuzzCheck: boolOrDefault('ENABLE_BUZZ_CHECK', true),
      enableLinkValidation: boolOrDefault('ENABLE_LINK_VALIDATION', true),
    );
  }
}
