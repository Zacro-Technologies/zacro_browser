# Optional AI assistance

Zacro works without an AI connection. Settings accepts an OpenAI or Anthropic API key and an optional model identifier. Calls are made directly from the main process to the selected provider over HTTPS. API requests and hosted web searches are billed by that provider; a Zacro account does not include usage. Connecting a key stores it locally and does not make a test inference request.

The current integration supports API authentication only. It does not advertise ChatGPT or Claude subscription entitlement. Subscription sign-in must use a provider-approved integration with its own entitlement, eligibility, usage, and distribution review before it can ship.

## Workflows

- **Research:** Ctrl/Command + Enter submits a question. OpenAI uses the Responses API's hosted `web_search` tool. Claude uses the Messages API's `web_search_20250305` tool, limited to four searches per request. This does not share open pages, browsing history, cookies, passwords, or downloads. The answer is displayed before any source tab is opened.
- **Open sources:** The host opens only cited HTTP(S) sources after a separate user action. Source metadata comes from provider citation annotations, not URLs guessed from answer text. The host limits the number opened and reuses matching tabs in the current Space. If there are no supporting sources, ordinary search is offered and the answer is marked unverified.
- **Ask pages and PDFs:** Choosing the current page or a group of up to six tabs explicitly shares readable text from those tabs in the current profile. Research tools are disabled for that request. Each shared extract is capped at 20,000 characters, with a 60,000-character total. Answers may cite numbered paragraphs; valid identifiers resolve to the actual shared paragraph and a text-fragment link back to the evidence. PDF citations link to the physical PDF page. The extraction cannot prove that a model's claim follows from its cited paragraph, so users can inspect it.
- **Follow-ups:** Context remains in memory, separately for each browser profile. Changing between research and selected-page scopes starts a new conversation. Conversations are bounded to eight turns and 160,000 serialized characters. Closing the application discards them.
- **Download names:** A user-requested suggestion sends only the original filename, source URL, and page title. It does not upload or read the file. The result is sanitized and the original extension is retained; the host previews/applies the rename, handles filename collisions, and supports undo.
- **Stop:** The current provider request can be cancelled. A two-minute deadline stops stalled requests. Cancelling cannot retract data the provider has already received or guarantee that the provider incurred no charge.

Private profiles are excluded from AI. Tab IDs are validated against the current profile before extraction, and the active profile is checked again before sending and publishing results. Selecting Current page in an empty Space fails with a clear context error; it never silently changes to hosted web research. Page content and retrieved web content are treated as untrusted evidence. The assistant has no tools to submit forms, send messages, buy, delete, execute code, or control the local filesystem.

Web page text is extracted in an isolated JavaScript world with form controls, editable surfaces, and hidden content removed. Pages can still contain personal information in visible text; choosing a page shares that text. Remote PDFs are fetched only after the user selects their tab as context, using that tab's browser profile. PDF.js extracts static page text locally in a worker with a 20 MB input limit, 100-page/60,000-character parser limits, a 20-second deadline, and a bounded JavaScript heap. It does not render pages, execute PDF actions, read form annotations, follow links, or upload the raw file. Password-protected and image-only PDFs are rejected clearly; no OCR is performed. Text order and font extraction can be imperfect, and truncated context is identified.

## Credentials and privacy

The main process encrypts the connection using Electron `safeStorage` and writes an encrypted credential file outside the browsing-state export. The newer asynchronous encryption API is preferred; the older API remains a compatibility path. Encryption must be available, and Linux's `basic_text` fallback is rejected. The key never appears in renderer snapshots, public status, error events, or ordinary export/sync data. Disconnect deletes the encrypted file and clears in-memory conversations. File deletion does not promise forensic erasure from backups or storage media.

OpenAI requests use `store: false`. This controls Responses storage and is not a blanket claim about provider retention, abuse monitoring, or contractual privacy. Provider policies and the user's account settings still apply. Claude conversation follow-ups preserve provider-issued encrypted search blocks as required by that API.

Provider endpoints are fixed in code; API keys are never sent to a user-supplied base URL or redirected host. Redirects are rejected. Responses are capped at 2 MiB. Provider error bodies are not displayed because they can echo sensitive request data. Authentication, model, quota, timeout, and network failures have distinct user-facing handling. There are no automatic retries or silent provider/billing fallbacks.

## Current limits and release gates

Raw file uploads, OCR, password unlocking, subscription sign-in, browser form preparation, and consequential browser-agent actions are not implemented. Protected documents, scanned PDFs, and unloaded pages may not expose readable text; the user receives a clear error. Ask Peek is possible only after promotion to a regular tab. Semantic history search and recurring browser tasks are not implemented. No AI capability should be described as a complete implementation of all README proposals.

No paid provider requests are made by automated tests. Before a public release, owners must run consented live API smoke tests for their supported model matrix, check citations and source opening with real responses, verify secure storage on each target OS, and evaluate prompt-injection resistance and evidence quality. Hosted search ranking is the provider's; Zacro asks for primary evidence and corroboration but does not independently crawl or score every source.

## Implementation references

The implementation follows the [OpenAI web search guide](https://developers.openai.com/api/docs/guides/tools-web-search), including citation annotations and hosted search, and the [Claude web search guide](https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool), including citations, encrypted follow-up blocks, server-tool errors, and usage. The default OpenAI model is [`gpt-5-mini`](https://developers.openai.com/api/docs/models/gpt-5-mini); the Claude default is `claude-sonnet-4-6`. Both are configurable and provider availability can change. Documentation was checked on October 24, 2026.

PDF extraction follows the [PDF.js document API](https://mozilla.github.io/pdf.js/api/draft/module-pdfjsLib.html) and [official Node text-extraction example](https://github.com/mozilla/pdf.js/blob/master/examples/node/getinfo.mjs). It loads the pinned package's legacy module and its local font/CMap resources.

Run isolated tests with `node --test test/ai.test.cjs test/pdf.test.cjs`. Tests cover encrypted persistence, source and filename validation, profile boundaries, selected-page consent, cancellation, quotas, provider payloads, follow-ups, paragraph/PDF-page citation extraction, and genuine PDF parsing without external network or inference calls.
