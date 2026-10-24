# Optional Codex assistance

Zacro uses the signed-in user's Codex allowance through the official, bundled `@openai/codex` app-server. Choose **Sign in with ChatGPT** in Settings or Ask Zacro, then finish the official sign-in in your system browser. Zacro manages this connection separately from a developer's Codex desktop or command-line setup. Browsing works without signing in.

There is no API-key field, Claude connection, or separate API-billing fallback. Account eligibility, available models and Codex usage limits still apply; a subscription does not mean unlimited use. Connecting or refreshing account status does not submit a model question. The model selector uses the catalog returned by the Codex connection, which is not a guarantee that every listed model is available to every account. A failed or exhausted request is shown as an error instead of being routed to an API key.

The sign-in and request paths are implemented. Protocol tests use a controlled app-server transport. The real bundled runtime also passed a signed-out handshake and authentication-start/cancel check, without opening a sign-in browser, using personal credentials or running inference. Completing ChatGPT sign-in, checking account access, and validating real answers remains a user-assisted acceptance step.

## Workflows

- **Research:** Ctrl/Command + Enter submits a question with hosted web search enabled. This does not share open pages, browsing history, cookies, passwords, or downloads. The answer appears before source tabs are opened.
- **Open sources:** A separate action opens a bounded set of HTTP(S) evidence URLs returned in completed Codex web-search actions/results, reusing matching tabs in the current Space. A model-written URL alone does not qualify as research evidence. Answer links are recognized as citations only when they match returned evidence URLs. Missing evidence produces an unverified-answer notice and an ordinary-search option; returned URLs are not a guarantee of factual support.
- **Ask pages and PDFs:** Choosing the current page or up to six tabs explicitly shares readable text from those tabs in the current profile. Hosted web search is disabled for that request. Each shared extract is capped at 20,000 characters, with a 60,000-character total. Answers may cite numbered paragraphs; valid identifiers resolve to the shared paragraph and a text-fragment link. PDF citations link to the physical PDF page. The user can inspect evidence; a valid citation identifier does not prove that the model's claim follows from it.
- **Follow-ups:** Conversation context remains in browser-process memory, separately for each browser profile. Switching between research and selected-page scopes starts a new conversation. Context is bounded to eight turns and 160,000 serialized characters. New ephemeral Codex threads receive the bounded context for each request. Closing the application discards Zacro's in-memory conversations.
- **Download names:** A requested suggestion sends only the original filename, source URL, and page title, with search disabled. It does not read or upload the file. The result is sanitized and the original extension is retained. Zacro handles filename collisions and supports undo.
- **Stop:** Cancelling interrupts the turn; a stalled interruption terminates Zacro's own runtime process. A two-minute request deadline stops stalled answers. Cancellation cannot retract data already received or guarantee that no account allowance was used.

Private profiles are excluded from AI. Tab IDs are validated against the current profile before extraction, and the active profile is checked again before sending and publishing results. Current page in an empty Space produces a context error instead of silently switching to web research. Page content and search results are untrusted evidence, not instructions authorizing actions.

Web page text is extracted in an isolated JavaScript world with form controls, editable surfaces, and hidden content removed. Visible page text can still contain personal information; selecting a page shares that text. Remote PDFs are fetched only after the user selects their tab as context, using that tab's browser profile. PDF.js extracts static text locally in a worker with a 20 MB input limit, 100-page/60,000-character parser limits, a 20-second deadline, and a bounded JavaScript heap. It does not execute PDF actions, read form annotations, follow links, or upload the raw file. Password-protected and image-only PDFs are rejected; no OCR is performed. Text order and font extraction can be imperfect, and truncated context is identified.

## Credentials and privacy

The main process launches the pinned Codex runtime over private standard input/output. Its `CODEX_HOME` and working directory live inside Zacro's application-data directory, separate from a developer's existing Codex configuration. The child receives an environment allowlist, excluding inherited API keys, access tokens, provider endpoints, shell startup options, and arbitrary credentials. Existing legacy Zacro API credential files are not opened or imported.

Codex is configured for ChatGPT authentication and its OS keyring credential backend, with no plaintext-file fallback. The isolated Codex home gives this connection a separate keyring identity. Zacro's renderer receives connection state, account email/plan information and model choices, never authentication tokens. Credentials are excluded from browsing-state exports. Disconnect cancels the current request, invokes Codex logout and clears Zacro's conversations. This does not promise forensic erasure from backups or storage media.

Requests use ephemeral threads and disable command-history persistence and analytics. These settings limit the local application's conversation persistence; they are not a blanket claim about OpenAI retention, operational runtime records, or account privacy settings. OpenAI's policies and the user's account settings still apply. This integration does not make the old Responses API `store: false` claim.

## Runtime restrictions

The app-server runs from an empty Zacro-owned workspace with project-document discovery disabled. Shell execution, image viewing, browser/computer automation, plugins, memory, and additional agents are disabled. Discovered skills are disabled before use; any MCP inventory or skill-discovery error rejects the connection. Unexpected server tool/approval requests are rejected, and an unexpected tool event terminates the active runtime.

Both `thread/start` and `turn/start` explicitly select **no execution environments**. This matters because a read-only sandbox alone can still permit local-file reads. In the pinned Codex 0.164.0 implementation, the patch handler must resolve a selected environment before obtaining a filesystem; an empty environment selection rejects it first. Read-only sandboxing and never-approve policy remain additional restrictions. Hosted web search is enabled only for research, not page/PDF questions or download naming.

The assistant cannot control browser tabs, submit forms, send messages, buy, delete, run commands, or use local files as model tools. Browser-controlled extraction and source opening are separate, explicit user actions with profile checks. These controls require regression review whenever the Codex runtime or protocol changes; they do not substitute for an independent security audit.

Transport messages and accumulated streamed answers are bounded to 4 MiB. The renderer receives sanitized errors rather than raw runtime diagnostics, which may contain account or prompt data. Authentication, account-limit, cancellation, timeout and protocol failures have explicit paths. There are no automatic inference retries or silent billing fallbacks.

## Current limits and release gates

Raw file uploads, OCR, password unlocking, selected-text questions, browser form preparation, and consequential browser-agent actions are not implemented. Protected documents, scanned PDFs, and unloaded pages may not expose readable text. Ask Peek requires promotion to a regular tab. Semantic history search and recurring browser tasks remain planned. No AI capability should be described as a complete implementation of every README proposal.

Before public release, the user or release owner must complete live sign-in and verify account access, model requests, web-search evidence, source opening, cancellation and account limits. Verify keyring behavior on every target OS and evaluate prompt-injection resistance and evidence quality. Automated tests make no live inference calls. Search ranking is the provider's; Zacro does not independently crawl or score every source.

This is a local open-source integration. OpenAI's current app-server documentation distinguishes that use from commercial or hosted services, which require the supported Sign in with ChatGPT integration. A paid or hosted distribution must complete that authentication and distribution review before release; the Codex runtime's Apache license does not grant service access independently of OpenAI's terms.

## Implementation references

The integration follows the official [Codex app-server protocol and authentication documentation](https://learn.chatgpt.com/docs/app-server), [authentication guidance](https://learn.chatgpt.com/docs/auth), [configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference), and [security model](https://learn.chatgpt.com/docs/security). The reviewed runtime is pinned to `@openai/codex` 0.164.0; its experimental empty-environment protocol must be checked before upgrading. Documentation was reviewed on October 24, 2026.

PDF extraction follows the [PDF.js document API](https://mozilla.github.io/pdf.js/api/draft/module-pdfjsLib.html) and [official Node text-extraction example](https://github.com/mozilla/pdf.js/blob/master/examples/node/getinfo.mjs), using the pinned package's local module and font/CMap resources.

Run `npm test` for local protocol, credential-isolation, source-validation, profile, consent, cancellation and PDF checks; `npm run test:e2e` covers the real browser UI and native page behavior. See the [validation record](VALIDATION.md) for completed checks and remaining acceptance.
