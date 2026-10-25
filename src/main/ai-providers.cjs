'use strict';

const API_PROVIDERS = Object.freeze({
  openai: { name: 'OpenAI API', baseUrl: 'https://api.openai.com/v1', model: 'gpt-5-mini', research: true },
  anthropic: {
    name: 'Claude API',
    baseUrl: 'https://api.anthropic.com/v1',
    model: 'claude-sonnet-4-6',
    research: true,
  },
  compatible: { name: 'OpenAI-compatible API', baseUrl: '', model: '', research: false },
  openrouter: {
    name: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    model: 'openai/gpt-5-mini',
    research: true,
  },
});
const MAX_RESPONSE = 2 * 1024 * 1024;
const MODEL = /^[a-zA-Z0-9][a-zA-Z0-9._:/@+-]{0,159}$/;

class ProviderError extends Error {
  constructor(message, code = 'PROVIDER') {
    super(message);
    this.code = code;
  }
}

function loopback(url) {
  return (
    url.hostname === 'localhost' ||
    url.hostname === '[::1]' ||
    /^127\.(?:\d{1,3}\.){2}\d{1,3}$/.test(url.hostname)
  );
}

function normalizeBaseUrl(provider, value) {
  const spec = API_PROVIDERS[provider];
  if (!spec) throw new ProviderError('Choose a supported API provider.', 'INPUT');
  if (provider !== 'compatible') {
    if (
      value !== undefined &&
      value !== '' &&
      (typeof value !== 'string' || value.replace(/\/+$/, '') !== spec.baseUrl)
    )
      throw new ProviderError(
        'This provider uses its official endpoint. Choose OpenAI-compatible for a custom server.',
        'ENDPOINT',
      );
    return spec.baseUrl;
  }
  if (typeof value !== 'string' || value.length > 2048 || /[\x00-\x20\x7f\\]/.test(value))
    throw new ProviderError('Enter an HTTPS API base URL, including its API path such as /v1.', 'ENDPOINT');
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new ProviderError('Enter a valid API base URL.', 'ENDPOINT');
  }
  if (
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    !(url.protocol === 'https:' || (url.protocol === 'http:' && loopback(url)))
  )
    throw new ProviderError(
      'API endpoints require HTTPS, except HTTP on localhost or a loopback address. Embedded credentials, query strings and fragments are not allowed.',
      'ENDPOINT',
    );
  return url.href.replace(/\/+$/, '');
}

function validateModel(model) {
  if (typeof model !== 'string' || !MODEL.test(model))
    throw new ProviderError('Enter a valid model ID from your provider.', 'MODEL');
  return model;
}

function safeUrl(value) {
  try {
    if (typeof value !== 'string' || value.length > 8192) return null;
    const url = new URL(value);
    return ['https:', 'http:'].includes(url.protocol) && !url.username && !url.password ? url.href : null;
  } catch {
    return null;
  }
}

function usageOf(value = {}) {
  const result = {};
  for (const key of ['input_tokens', 'output_tokens', 'total_tokens', 'prompt_tokens', 'completion_tokens'])
    if (Number.isFinite(value[key]) && value[key] >= 0) result[key] = value[key];
  if (Number.isFinite(value.server_tool_use?.web_search_requests))
    result.web_search_requests = value.server_tool_use.web_search_requests;
  return result;
}

function parseAnswer(provider, data) {
  let answer = '';
  const citations = [],
    sources = [];
  const source = (item) => {
    const url = safeUrl(item?.url);
    if (!url) return null;
    const entry = {
      url,
      title: typeof item.title === 'string' ? item.title.slice(0, 300) : new URL(url).hostname,
    };
    if (!sources.some((item) => item.url === url)) sources.push(entry);
    return entry;
  };
  const append = (text, annotations = []) => {
    if (typeof text !== 'string') return;
    const offset = answer.length;
    answer += text;
    for (const item of annotations) {
      const citation = item.url_citation || item;
      const entry = source(citation);
      if (
        entry &&
        Number.isInteger(citation.start_index) &&
        Number.isInteger(citation.end_index) &&
        citation.start_index >= 0 &&
        citation.end_index > citation.start_index &&
        citation.end_index <= text.length
      )
        citations.push({ ...entry, start: offset + citation.start_index, end: offset + citation.end_index });
    }
  };
  let searchError = false;
  if (provider === 'openai') {
    if (data.status === 'failed' || data.error)
      throw new ProviderError(
        'OpenAI could not complete this response. Check the selected model and account access.',
        'PROVIDER',
      );
    if (data.status === 'incomplete')
      throw new ProviderError(
        'The response reached its output limit. Ask a narrower question.',
        'INCOMPLETE',
      );
    for (const item of data.output || []) {
      if (item.type === 'message')
        for (const part of item.content || []) {
          if (part.type === 'output_text') append(part.text, part.annotations);
          if (part.type === 'refusal') append(part.refusal);
        }
      if (item.type === 'web_search_call') {
        source(item.action);
        for (const value of item.action?.sources || []) source(value);
      }
      if (/function_call|computer_call|mcp_call|shell_call/.test(item.type || ''))
        throw new ProviderError('The provider requested a tool that Zacro does not permit.', 'TOOL_POLICY');
    }
  } else if (provider === 'anthropic') {
    if (['max_tokens', 'pause_turn'].includes(data.stop_reason))
      throw new ProviderError(
        'Claude did not finish within this request’s limit. Ask a narrower question.',
        'INCOMPLETE',
      );
    for (const part of data.content || []) {
      if (part.type === 'tool_use')
        throw new ProviderError('Claude requested a tool that Zacro does not permit.', 'TOOL_POLICY');
      if (part.type === 'text') {
        append(part.text);
        for (const citation of part.citations || []) {
          const entry = source(citation);
          if (!entry) continue;
          const marker = ` [${sources.findIndex((item) => item.url === entry.url) + 1}]`;
          const start = answer.length + 1;
          answer += marker;
          citations.push({
            ...entry,
            start,
            end: answer.length,
            quote: typeof citation.cited_text === 'string' ? citation.cited_text.slice(0, 180) : '',
          });
        }
      }
      if (part.type === 'web_search_tool_result') {
        if (Array.isArray(part.content)) part.content.forEach(source);
        else if (part.content?.type === 'web_search_tool_result_error') searchError = true;
      }
    }
  } else {
    const choice = data.choices?.[0];
    if (data.error)
      throw new ProviderError(
        'The provider could not complete the response. Check your model and account access.',
        'PROVIDER',
      );
    if (choice?.finish_reason === 'length')
      throw new ProviderError(
        'The response reached its output limit. Ask a narrower question.',
        'INCOMPLETE',
      );
    if (choice?.message?.tool_calls?.length || choice?.message?.function_call)
      throw new ProviderError('The provider requested a tool that Zacro does not permit.', 'TOOL_POLICY');
    append(choice?.message?.content, provider === 'openrouter' ? choice?.message?.annotations : []);
  }
  if (!answer.trim())
    throw new ProviderError(
      'The provider returned no text answer. Check model compatibility or try a more specific question.',
      'EMPTY',
    );
  return {
    answer,
    sources: sources.slice(0, 20),
    citations,
    usage: usageOf(data.usage),
    searchError,
    // Claude search follow-ups need the provider's opaque search blocks intact.
    historyContent: provider === 'anthropic' ? data.content : answer,
  };
}

class APIClient {
  constructor({ fetch: fetchImpl = globalThis.fetch, timeoutMs = 120000 } = {}) {
    this.fetch = fetchImpl;
    this.timeoutMs = timeoutMs;
  }

  async request({ provider, baseUrl, key, route, body, signal }) {
    const endpoint = normalizeBaseUrl(provider, baseUrl);
    const controller = new AbortController();
    const abort = () => controller.abort(signal.reason || new ProviderError('Request stopped.', 'CANCELLED'));
    if (signal?.aborted) abort();
    else signal?.addEventListener('abort', abort, { once: true });
    const timer = setTimeout(
      () => controller.abort(new ProviderError('The provider took too long. Try again.', 'TIMEOUT')),
      this.timeoutMs,
    );
    timer.unref?.();
    let response, reader;
    const cancelBody = () => {
      reader?.cancel().catch(() => {});
    };
    controller.signal.addEventListener('abort', cancelBody, { once: true });
    try {
      if (controller.signal.aborted) throw controller.signal.reason;
      if (!key && !(provider === 'compatible' && loopback(new URL(endpoint))))
        throw new ProviderError('Save an API key for this provider first.', 'NOT_CONFIGURED');
      if (key && (typeof key !== 'string' || /[\x00-\x20\x7f]/.test(key)))
        throw new ProviderError('The API key is invalid.', 'AUTH');
      const headers = { accept: 'application/json', ...(body ? { 'content-type': 'application/json' } : {}) };
      if (provider === 'anthropic') {
        headers['x-api-key'] = key;
        headers['anthropic-version'] = '2023-06-01';
      } else if (key) headers.authorization = `Bearer ${key}`;
      response = await this.fetch(`${endpoint}/${route}`, {
        method: body ? 'POST' : 'GET',
        headers,
        ...(body ? { body: JSON.stringify(body) } : {}),
        redirect: 'error',
        credentials: 'omit',
        cache: 'no-store',
        signal: controller.signal,
      });
      if (controller.signal.aborted) throw controller.signal.reason;
      if (response.status >= 300 && response.status < 400)
        throw new ProviderError(
          'The API endpoint redirected. Credentials were not forwarded; use its final API base URL.',
          'REDIRECT',
        );
      if (!response.ok) {
        if ([401, 403].includes(response.status))
          throw new ProviderError(
            'The provider rejected this API key or account access. Check the key and its permissions.',
            'AUTH',
          );
        if (response.status === 429)
          throw new ProviderError(
            'The provider’s usage or rate limit was reached. Check its billing and limits, then try again.',
            'LIMIT',
          );
        if ([400, 404, 422].includes(response.status))
          throw new ProviderError(
            'The provider rejected this model, endpoint or feature. Check your model ID and API compatibility.',
            'MODEL',
          );
        throw new ProviderError(
          `The provider is unavailable (HTTP ${response.status}). Try again later.`,
          'PROVIDER',
        );
      }
      if (Number(response.headers.get('content-length')) > MAX_RESPONSE)
        throw new ProviderError('The provider response was too large.', 'RESPONSE_SIZE');
      const contentType = response.headers.get('content-type') || '';
      if (!/application\/(?:[a-z0-9.+-]*\+)?json\b/i.test(contentType))
        throw new ProviderError(
          'The endpoint did not return a JSON API response. Check its API base URL.',
          'PROTOCOL',
        );
      reader = response.body?.getReader();
      if (!reader) throw new ProviderError('The provider returned an empty response.', 'EMPTY');
      const chunks = [];
      let bytes = 0;
      while (true) {
        const { done, value } = await reader.read();
        if (controller.signal.aborted) throw controller.signal.reason;
        if (done) break;
        bytes += value.byteLength;
        if (bytes > MAX_RESPONSE)
          throw new ProviderError('The provider response was too large.', 'RESPONSE_SIZE');
        chunks.push(value);
      }
      try {
        return JSON.parse(Buffer.concat(chunks).toString('utf8'));
      } catch {
        throw new ProviderError('The provider returned invalid JSON.', 'PROTOCOL');
      }
    } catch (error) {
      if (controller.signal.aborted) throw controller.signal.reason;
      if (error instanceof ProviderError) throw error;
      throw new ProviderError(
        'Unable to reach the API endpoint. Check its address, certificate and your connection. Redirects are not followed.',
        'NETWORK',
      );
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener('abort', abort);
      controller.signal.removeEventListener('abort', cancelBody);
      if (reader) await reader.cancel().catch(() => {});
      else await response?.body?.cancel().catch(() => {});
    }
  }

  async test(config) {
    const data = await this.request({
      ...config,
      route: config.provider === 'openrouter' ? 'key' : 'models',
    });
    const models = Array.isArray(data.data)
      ? data.data
          .flatMap((item) =>
            MODEL.test(item.id || '')
              ? [{ id: item.id, name: String(item.display_name || item.id).slice(0, 160) }]
              : [],
          )
          .slice(0, 500)
      : [];
    return {
      ok: true,
      models,
      message: 'Connected. No inference request was made.',
      ...(models.length && !models.some((model) => model.id === config.model)
        ? {
            warning:
              'Your configured model was not in the returned catalog. Check its exact ID before asking a question.',
          }
        : {}),
    };
  }

  async run(config) {
    const { provider, instructions, messages, research } = config;
    const model = validateModel(config.model);
    let body, route;
    if (provider === 'openai') {
      route = 'responses';
      body = {
        model,
        instructions,
        input: messages,
        store: false,
        max_output_tokens: 4096,
        ...(research ? { tools: [{ type: 'web_search' }], include: ['web_search_call.action.sources'] } : {}),
      };
    } else if (provider === 'anthropic') {
      route = 'messages';
      body = {
        model,
        system: instructions,
        messages,
        max_tokens: 4096,
        ...(research ? { tools: [{ type: 'web_search_20250305', name: 'web_search', max_uses: 5 }] } : {}),
      };
    } else {
      route = 'chat/completions';
      body = {
        model,
        messages: [{ role: 'system', content: instructions }, ...messages],
        max_tokens: 4096,
        stream: false,
        ...(provider === 'openrouter'
          ? {
              provider: { allow_fallbacks: false },
              ...(research ? { plugins: [{ id: 'web', max_results: 5 }] } : {}),
            }
          : {}),
      };
    }
    const data = await this.request({ ...config, route, body });
    return parseAnswer(provider, data);
  }
}

module.exports = {
  APIClient,
  API_PROVIDERS,
  ProviderError,
  normalizeBaseUrl,
  validateModel,
  parseAnswer,
  loopback,
  MAX_RESPONSE,
};
