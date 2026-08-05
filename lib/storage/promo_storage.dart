import 'dart:convert';
import 'dart:io';

import 'package:intl/intl.dart';

import '../models/promo.dart';

/// Saves weekly promo history as JSON files in external/local storage,
/// one file per week so it's easy to browse manually if needed.
class PromoStorage {
  final Directory outputDir;

  PromoStorage({required String outputPath}) : outputDir = Directory(outputPath);

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
}
