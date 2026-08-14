import 'dart:convert';
import 'package:http/http.dart' as http;

import 'serpapi_client.dart';

/// [SearchService] backed by Tavily (https://tavily.com), an LLM-focused
/// search API. Maps Tavily's `results[]` (title/content/url) onto the
/// shared [SearchResult] shape so it can slot into the fallback chain.
class TavilyClient implements SearchService {
  final String apiKey;
  final http.Client _http;

  static const _timeout = Duration(seconds: 30);

  TavilyClient({required this.apiKey, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  @override
  Future<List<SearchResult>> search(String query, {int maxResults = 10}) async {
    // `country: indonesia` + `time_range: w` mirror the geo/last-week
    // intent of the existing SerpApi call. `search_depth: basic` keeps the
    // cost at 1 credit per request.
    final res = await _http
        .post(
          Uri.https('api.tavily.com', '/search'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'api_key': apiKey,
            'query': query,
            'search_depth': 'basic',
            'topic': 'general',
            'country': 'indonesia',
            'time_range': 'w',
            'max_results': maxResults,
            'include_answer': false,
          }),
        )
        .timeout(_timeout);

    if (res.statusCode != 200) {
      throw Exception(
          'Tavily request failed (${res.statusCode}) for query "$query": ${res.body}');
    }

    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    final results = (decoded['results'] as List<dynamic>?) ?? [];

    return results.map((item) {
      final map = item as Map<String, dynamic>;
      return SearchResult(
        title: map['title']?.toString() ?? '',
        snippet: map['content']?.toString() ?? '',
        link: map['url']?.toString() ?? '',
      );
    }).toList();
  }

  @override
  void close() => _http.close();
}
