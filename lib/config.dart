import 'dart:io';

import 'package:dotenv/dotenv.dart';

/// Loads configuration from a ".env" file (if present, for local
/// development) or from OS environment variables (for cron/service runs).
class Config {
  final String geminiApiKey;
  final String? openRouterApiKey;
  final String? fallbackModel;
  final String? tavilyApiKey;
  final String? serperApiKey;
  final String? serpapiKey;
  final String telegramBotToken;
  final String telegramChatId;
  final String outputDir;

  /// Main region for the default weekly search (cron), e.g. "Jabodetabek".
  final String region;

  /// Enables the "how much is this being talked about" social buzz check.
  /// Adds 1 extra SerpApi call per promo — disable via .env
  /// (ENABLE_BUZZ_CHECK=false) to save quota.
  final bool enableBuzzCheck;

  /// Caps the number of merchants buzz-checked per sub-category (0 = no
  /// cap). Set via `BUZZ_MAX_MERCHANTS`. Lower values save search-provider
  /// calls at the cost of showing the buzz signal for fewer merchants.
  final int buzzMaxMerchants;

  /// Enables the LLM-based cross-week dedup pass (layer 2). When true, after
  /// the deterministic merchant-key dedup, the flow asks Gemini once per run
  /// to flag fuzzy duplicates (abbreviations, reworded merchant names).
  /// Costs 1 extra Gemini call per run. Set via `ENABLE_LLM_DEDUP`.
  final bool enableLlmDedup;

  /// Enables filtering out promos whose source link is unreachable.
  /// Disable via .env (ENABLE_LINK_VALIDATION=false) if this causes too
  /// many false negatives (some sites block bot-like requests).
  final bool enableLinkValidation;

  Config._({
    required this.geminiApiKey,
    required this.openRouterApiKey,
    required this.fallbackModel,
    required this.tavilyApiKey,
    required this.serperApiKey,
    required this.serpapiKey,
    required this.telegramBotToken,
    required this.telegramChatId,
    required this.outputDir,
    required this.region,
    required this.enableBuzzCheck,
    required this.buzzMaxMerchants,
    required this.enableLlmDedup,
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

    int intOrDefault(String key, int defaultValue) {
      final value = env[key];
      if (value == null || value.trim().isEmpty) return defaultValue;
      return int.tryParse(value.trim()) ?? defaultValue;
    }

    String? optional(String key) {
      final value = env[key];
      if (value == null || value.trim().isEmpty) return null;
      return value.trim();
    }

    final tavilyApiKey = optional('TAVILY_API_KEY');
    final serperApiKey = optional('SERPER_API_KEY');
    final serpapiKey = optional('SERPAPI_KEY');

    // At least one search provider must be configured, otherwise there is
    // nothing to power the `searchPromo` tool / buzz checks.
    if (tavilyApiKey == null && serperApiKey == null && serpapiKey == null) {
      throw Exception(
          'No search provider configured. Set at least one of TAVILY_API_KEY, '
          'SERPER_API_KEY, or SERPAPI_KEY in your .env file or crontab.');
    }

    return Config._(
      geminiApiKey: require('GEMINI_API_KEY'),
      openRouterApiKey: optional('OPENROUTER_API_KEY'),
      fallbackModel: optional('FALLBACK_MODEL'),
      tavilyApiKey: tavilyApiKey,
      serperApiKey: serperApiKey,
      serpapiKey: serpapiKey,
      telegramBotToken: require('TG_BOT_TOKEN'),
      telegramChatId: require('TG_CHAT_ID'),
      outputDir: orDefault('OUTPUT_DIR', './harness-data'),
      region: orDefault('REGION', 'Jabodetabek'),
      enableBuzzCheck: boolOrDefault('ENABLE_BUZZ_CHECK', true),
      buzzMaxMerchants: intOrDefault('BUZZ_MAX_MERCHANTS', 0),
      enableLlmDedup: boolOrDefault('ENABLE_LLM_DEDUP', false),
      enableLinkValidation: boolOrDefault('ENABLE_LINK_VALIDATION', true),
    );
  }
}
