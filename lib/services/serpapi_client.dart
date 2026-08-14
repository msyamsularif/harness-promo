import 'dart:convert';
import 'package:http/http.dart' as http;

/// Abstract interface for promo search services. Allows swapping SerpApi
/// for a different backend without changing consumers.
abstract class SearchService {
  Future<List<SearchResult>> search(String query, {int maxResults = 10});

  void close();
}

/// A single raw search result from SerpApi, before it's summarized by AI.
class SearchResult {
  final String title;
  final String snippet;
  final String link;

  SearchResult({required this.title, required this.snippet, required this.link});

  /// Returns a cleaned copy: whitespace collapsed, common HTML entities
  /// decoded, and the snippet capped at [maxSnippetLength]. This keeps the
  /// data fed into Gemini/OpenRouter tidy regardless of which provider produced
  /// it (Tavily `content` tends to be much longer than SerpApi `snippet`).
  SearchResult normalized({int maxSnippetLength = 500}) => SearchResult(
        title: _cleanText(title),
        snippet: _cleanText(snippet, maxLength: maxSnippetLength),
        link: link.trim(),
      );

  @override
  String toString() => 'Title: $title\nSnippet: $snippet\nLink: $link';
}

/// Collapses runs of whitespace (including newlines) into single spaces,
/// decodes common HTML entities, trims, and optionally caps the length.
/// `&amp;` is decoded LAST so an entity like `&amp;lt;` isn't double-decoded.
String _cleanText(String raw, {int? maxLength}) {
  var text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  text = text
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&');
  if (maxLength != null && text.length > maxLength) {
    text = text.substring(0, maxLength).trimRight();
  }
  return text;
}

class SerpApiClient implements SearchService {
  final String apiKey;
  final http.Client _http;

  static const _timeout = Duration(seconds: 30);

  SerpApiClient({required this.apiKey, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  /// Searches for promos via Google Search (through SerpApi), restricted
  /// to recent results.
  ///
  /// [query] e.g. "promo makanan minuman terbaru Indonesia".
  /// [maxResults] number of top results to fetch (default 10).
  @override
  Future<List<SearchResult>> search(String query, {int maxResults = 10}) async {
    final uri = Uri.https('serpapi.com', '/search.json', {
      'engine': 'google',
      'q': query,
      'google_domain': 'google.co.id',
      'gl': 'id',
      'hl': 'id',
      'tbs': 'qdr:w', // restrict to results from the last week
      'num': maxResults.toString(),
      'api_key': apiKey,
    });

    final res = await _http.get(uri).timeout(_timeout);

    if (res.statusCode != 200) {
      throw Exception(
          'SerpApi request failed (${res.statusCode}) for query "$query": ${res.body}');
    }

    final body = jsonDecode(res.body) as Map<String, dynamic>;

    if (body.containsKey('error')) {
      throw Exception('SerpApi error for query "$query": ${body['error']}');
    }

    final organic = (body['organic_results'] as List<dynamic>?) ?? [];

    return organic.map((item) {
      final map = item as Map<String, dynamic>;
      return SearchResult(
        title: map['title']?.toString() ?? '',
        snippet: map['snippet']?.toString() ?? '',
        link: map['link']?.toString() ?? '',
      );
    }).toList();
  }

  void close() => _http.close();
}
