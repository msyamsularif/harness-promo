import 'dart:convert';
import 'package:http/http.dart' as http;

import 'serpapi_client.dart';

/// [SearchService] backed by Serper.dev (https://serper.dev), a Google
/// Search API. Maps Serper's `organic[]` (title/link/snippet) onto the
/// shared [SearchResult] shape so it can slot into the fallback chain.
class SerperClient implements SearchService {
  final String apiKey;
  final http.Client _http;

  static const _timeout = Duration(seconds: 30);

  SerperClient({required this.apiKey, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  @override
  Future<List<SearchResult>> search(String query, {int maxResults = 10}) async {
    final res = await _http
        .post(
          Uri.https('google.serper.dev', '/search'),
          headers: {
            'X-API-KEY': apiKey,
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'q': query,
            'gl': 'id',
            'hl': 'id',
            'tbs': 'qdr:w',
            'num': maxResults,
          }),
        )
        .timeout(_timeout);

    if (res.statusCode != 200) {
      throw Exception(
          'Serper request failed (${res.statusCode}) for query "$query": ${res.body}');
    }

    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    final organic = (decoded['organic'] as List<dynamic>?) ?? [];

    return organic.map((item) {
      final map = item as Map<String, dynamic>;
      return SearchResult(
        title: map['title']?.toString() ?? '',
        snippet: map['snippet']?.toString() ?? '',
        link: map['link']?.toString() ?? '',
      );
    }).toList();
  }

  @override
  void close() => _http.close();
}
