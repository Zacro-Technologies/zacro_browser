# Third-party software

Zacro's original source is licensed under the MIT license in `LICENSE`.

The distributed browser also contains third-party software with its own licenses:

- **Electron**, copyright Electron contributors, MIT license. Its executable, runtime files and license are included by electron-builder.
- **Chromium, Blink, V8 and their dependencies**, copyright their respective contributors, with BSD-style and other licenses. The packaged application includes Electron's generated `LICENSES.chromium.html`; retain it when redistributing the browser.
- **PDF.js (`pdfjs-dist`)**, copyright Mozilla Foundation and contributors, Apache License 2.0. Its license is included in the packaged dependency. Zacro uses it for local PDF text extraction.
- **yauzl 3.4.0**, copyright Josh Wolfe, and **pend 1.2.0**, copyright Andrew Kelley, MIT licenses. Zacro uses yauzl's bounded ZIP entry reader for extension archives; Zacro separately verifies signatures and enforces extraction limits and portable path rules. Their licenses are included with the packaged dependencies.
- **OpenAI Codex (`@openai/codex` and its platform runtime)**, copyright OpenAI and contributors, Apache License 2.0. Zacro uses its local app-server for optional ChatGPT subscription sign-in and inference. The upstream license is included at `assets/CODEX-LICENSE.txt`; the native runtime's applicable bundled notices accompany its vendor files. Retain those files when redistributing it. Its software license does not grant unrestricted access to OpenAI services.
- **Optional `@napi-rs/canvas` dependencies** of PDF.js, with their package license and bundled native-library notices. These remain subject to their own terms.

Development-only tooling (Playwright, electron-builder and their dependency trees) is described in `package-lock.json` and the corresponding packages' license files. It is not an assertion that all transitive dependencies share Zacro's license. Review the exact packaged dependency set and retain the generated notices before public distribution.

Zacro is an independent project. Chromium, Electron, OpenAI, Anthropic, Arc, and other referenced names are the property of their respective owners; use here does not imply sponsorship or affiliation.
