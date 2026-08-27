import 'dart:convert';
import 'dart:io';

import 'package:intl/intl.dart';

import '../models/promo.dart';

/// Saves weekly promo history as JSON files in external/local storage,
/// one file per week so it's easy to browse manually if needed.
class PromoStorage {
  final Directory outputDir;

  PromoStorage({required String outputPath})
      : outputDir = Directory(outputPath);

  Future<File> saveWeekly(List<Promo> promos) async {
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }

    final dateStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final file = File('${outputDir.path}/promo_$dateStr.json');

    final payload = {
      'generated_at': DateTime.now().toIso8601String(),
      'promo_count': promos.length,
      'promos': promos.map((p) => p.toJson()).toList(),
    };

    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );

    return file;
  }

  /// Loads the most recent weekly promo history file from [outputDir].
  /// Returns an empty list if the directory does not exist, contains no
  /// valid history files, or the latest file cannot be parsed.
  Future<List<Promo>> loadLatestWeekly() async {
    if (!await outputDir.exists()) {
      return [];
    }

    final files = await outputDir
        .list()
        .where((entity) =>
            entity is File &&
            entity.path.endsWith('.json') &&
            _fileName(entity.path).startsWith('promo_'))
        .cast<File>()
        .toList();

    if (files.isEmpty) {
      return [];
    }

    // Filenames are `promo_YYYY-MM-DD.json`, so descending lexical order
    // picks the most recent date.
    files.sort((a, b) => b.path.compareTo(a.path));

    try {
      final latest = files.first;
      final content = await latest.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final promosJson = json['promos'] as List<dynamic>?;
      if (promosJson == null) {
        stderr.writeln('[storage] No "promos" key in ${latest.path}');
        return [];
      }
      return promosJson
          .map((p) => Promo.fromJson(p as Map<String, dynamic>))
          .toList();
    } catch (e) {
      stderr.writeln('[storage] Failed to load latest history: $e');
      return [];
    }
  }

  String _fileName(String path) => path.split(Platform.pathSeparator).last;
}
