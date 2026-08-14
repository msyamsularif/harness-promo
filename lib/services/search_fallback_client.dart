import 'dart:io';

import 'serpapi_client.dart';
import 'serper_client.dart';
import 'tavily_client.dart';

/// A [SearchService] that tries a list of providers in priority order and
/// falls through to the next one when the current provider errors (rate
/// limit, plan limit, timeout, network error, etc.).
///
/// Priority is fixed at construction time as Tavily > Serper > SerpApi,
/// with providers that have no API key simply omitted from the chain. An
/// EMPTY result set does NOT trigger a fallback — it is treated as a
/// legitimate "no results found" answer and returned as-is.
class SearchFallbackClient implements SearchService {
  final List<SearchService> _providers;

  SearchFallbackClient({required List<SearchService> providers})
      : _providers = providers;

  @override
  Future<List<SearchResult>> search(String query, {int maxResults = 10}) async {
    if (_providers.isEmpty) {
      throw Exception(
          'No search provider configured. Set at least one of TAVILY_API_KEY, '
          'SERPER_API_KEY, or SERPAPI_KEY.');
    }

    Object? lastError;
    for (var i = 0; i < _providers.length; i++) {
      final provider = _providers[i];
      try {
        final results = await provider.search(query, maxResults: maxResults);
        final cleaned = _cleanResults(results);
        if (i > 0) {
          stderr.writeln('[search] query "$query" served by '
              '${provider.runtimeType} (${cleaned.length} results) — '
              'recovered after $i failed provider(s).');
        } else {
          stderr.writeln('[search] query "$query" served by '
              '${provider.runtimeType} (${cleaned.length} results).');
        }
        return cleaned;
      } catch (e) {
        lastError = e;
        final next = (i + 1 < _providers.length)
            ? ' — falling back to ${_providers[i + 1].runtimeType}'
            : '';
        stderr.writeln(
            '[search] Provider ${provider.runtimeType} failed for query '
            '"$query": $e$next');
      }
    }

    throw Exception(
        'All search providers failed for query "$query": $lastError');
  }

  @override
  void close() {
    for (final provider in _providers) {
      try {
        provider.close();
      } catch (_) {
        // Best-effort cleanup; a provider failing to close is not fatal.
      }
    }
  }

  /// Normalizes each result and drops entries that carry no usable content
  /// at all (empty title, snippet, AND link). An empty link is still kept
  /// if the title/snippet has content, since the text may still help the
  /// model extract a promo from another source.
  List<SearchResult> _cleanResults(List<SearchResult> results) => results
      .map((r) => r.normalized())
      .where((r) => r.title.isNotEmpty || r.snippet.isNotEmpty || r.link.isNotEmpty)
      .toList();
}

/// Builds the fallback search chain from the configured API keys, in the
/// fixed priority order Tavily > Serper > SerpApi. Providers whose key is
/// null/empty are skipped.
SearchFallbackClient buildSearchClient({
  String? tavilyApiKey,
  String? serperApiKey,
  String? serpapiApiKey,
}) {
  final providers = <SearchService>[];

  if (tavilyApiKey != null && tavilyApiKey.isNotEmpty) {
    providers.add(TavilyClient(apiKey: tavilyApiKey));
  }
  if (serperApiKey != null && serperApiKey.isNotEmpty) {
    providers.add(SerperClient(apiKey: serperApiKey));
  }
  if (serpapiApiKey != null && serpapiApiKey.isNotEmpty) {
    providers.add(SerpApiClient(apiKey: serpapiApiKey));
  }

  return SearchFallbackClient(providers: providers);
}
