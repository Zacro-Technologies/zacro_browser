# Third-party software

Zacro's original source is licensed under the MIT license in `LICENSE`.

The distributed browser also contains third-party software with its own licenses:

- **Electron**, copyright Electron contributors, MIT license. Its executable, runtime files and license are included by electron-builder.
- **Chromium, Blink, V8 and their dependencies**, copyright their respective contributors, with BSD-style and other licenses. The packaged application includes Electron's generated `LICENSES.chromium.html`; retain it when redistributing the browser.
- **PDF.js (`pdfjs-dist`)**, copyright Mozilla Foundation and contributors, Apache License 2.0. Its license is included in the packaged dependency. Zacro uses it for local PDF text extraction.
- **Optional `@napi-rs/canvas` dependencies** of PDF.js, with their package license and bundled native-library notices. These remain subject to their own terms.

Development-only tooling (Playwright, electron-builder and their dependency trees) is described in `package-lock.json` and the corresponding packages' license files. It is not an assertion that all transitive dependencies share Zacro's license. Review the exact packaged dependency set and retain the generated notices before public distribution.

Zacro is an independent project. Chromium, Electron, OpenAI, Anthropic, Arc, and other referenced names are the property of their respective owners; use here does not imply sponsorship or affiliation.
