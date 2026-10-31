(function (root) {
  'use strict';

  const DEFAULT_SITE_SEARCHES = Object.freeze([
    Object.freeze({
      id: 'wikipedia',
      name: 'Wikipedia',
      keyword: 'w',
      url: 'https://en.wikipedia.org/w/index.php?search=%s',
    }),
    Object.freeze({ id: 'github', name: 'GitHub', keyword: 'gh', url: 'https://github.com/search?q=%s' }),
    Object.freeze({
      id: 'youtube',
      name: 'YouTube',
      keyword: 'yt',
      url: 'https://www.youtube.com/results?search_query=%s',
    }),
  ]);
  function siteSearchError(value) {
    if (!value || typeof value !== 'object') return 'Enter a name, keyword and search URL.';
    if (typeof value.name !== 'string' || !value.name.trim() || value.name.trim().length > 40)
      return 'Use a name of 1–40 characters.';
    if (typeof value.keyword !== 'string' || !/^[a-z0-9][a-z0-9_-]{0,23}$/i.test(value.keyword.trim()))
      return 'Use a keyword of 1–24 letters, numbers, underscores or hyphens.';
    if (typeof value.url !== 'string' || value.url.length > 2048 || value.url.split('%s').length !== 2)
      return 'Use a search URL containing exactly one %s in place of the query.';
    try {
      const parsed = new URL(value.url.replace('%s', 'zacro-search-placeholder'));
      const local = ['localhost', '127.0.0.1', '[::1]'].includes(parsed.hostname);
      if (parsed.protocol !== 'https:' && !(parsed.protocol === 'http:' && local))
        return 'Use an HTTPS search URL. HTTP is supported only for local development.';
      if (parsed.username || parsed.password) return 'Search URLs cannot contain account credentials.';
      if (
        parsed.host.includes('zacro-search-placeholder') ||
        parsed.hash.includes('zacro-search-placeholder') ||
        !(parsed.pathname + parsed.search).includes('zacro-search-placeholder')
      )
        return 'Place %s in the URL path or query, after the website address.';
      return '';
    } catch {
      return 'Enter a complete search URL, including https://.';
    }
  }
  function normalizeSiteSearches(input) {
    if (!Array.isArray(input)) return DEFAULT_SITE_SEARCHES.map((item) => ({ ...item }));
    const seen = new Set();
    const ids = new Set();
    const result = [];
    for (const value of input.slice(0, 100)) {
      if (siteSearchError(value)) continue;
      const keyword = value.keyword.trim().toLowerCase();
      if (seen.has(keyword)) continue;
      let id = typeof value.id === 'string' && /^[a-z0-9_-]{1,80}$/i.test(value.id) ? value.id : keyword;
      if (ids.has(id)) id = `search-${keyword}`;
      if (ids.has(id)) continue;
      seen.add(keyword);
      ids.add(id);
      result.push({ id, name: value.name.trim(), keyword, url: value.url.trim() });
      if (result.length === 20) break;
    }
    return result;
  }
  function siteSearchURL(engine, query) {
    if (siteSearchError(engine)) throw new Error('This site search is no longer available.');
    const text = String(query || '').trim();
    if (!text || text.length > 8000) throw new Error('Enter a search of 1–8,000 characters.');
    return engine.url.trim().replace('%s', encodeURIComponent(text.toWellFormed()));
  }
  function currentWebsiteSearch(pageURL, engines, searchEngine = 'google') {
    let page;
    try {
      page = new URL(pageURL);
      if (!['https:', 'http:'].includes(page.protocol) || !page.hostname) return null;
    } catch {
      return null;
    }
    const saved = normalizeSiteSearches(engines).find((engine) => new URL(engine.url).origin === page.origin);
    if (saved) return { ...saved, currentWebsite: true };
    const endpoint =
      {
        duckduckgo: 'https://duckduckgo.com/?q=',
        google: 'https://www.google.com/search?q=',
        bing: 'https://www.bing.com/search?q=',
        brave: 'https://search.brave.com/search?q=',
      }[searchEngine] || 'https://www.google.com/search?q=';
    return {
      id: 'current-website',
      name: page.hostname.slice(0, 40),
      keyword: 'site',
      currentWebsite: true,
      url: `${endpoint}${encodeURIComponent(`site:${page.hostname} `)}%s`,
    };
  }
  const api = Object.freeze({
    DEFAULT_SITE_SEARCHES,
    normalizeSiteSearches,
    siteSearchError,
    siteSearchURL,
    currentWebsiteSearch,
  });
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.ZacroSiteSearch = api;
})(globalThis);
