# Execution evidence

Captured on October 29, 2026 (JST). JSON timestamps use UTC. These records contain no account identifiers, credentials, profiles or authentication traffic.

| Record                                                                       | What was observed                                                                                            | Limit                                                                                                             |
| ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------- |
| [Windows source](windows-native-source.json)                                 | Exact Chromium/depot revisions and all nine reviewed branding file hashes verified against the full checkout | Dependencies and the branded executable have not been built; required Windows toolchain is missing                |
| [Brave mechanics](mechanics-brave-win32-x64-reference.json)                  | Nine local browser checks passed in separate fixture profiles                                                | Automated loopback checks; no Google account acceptance                                                           |
| [Chromium snapshot mechanics](mechanics-chromium-win32-x64-engine-only.json) | Startup failed before the fixture document was requested                                                     | Chromium 159 upstream snapshot; no conclusion about Google's response or the Chromium 156 branded build           |
| [Human reference matrix](manual-reference-results.json)                      | The user reported a visible Google password field in Windows Brave                                           | Only that preliminary reference step passed; authenticated login, Gmail, Drive and all Mac checks remain untested |

The source-built Zacro candidate has its own [acceptance recorder](../build/NATIVE-BUILD.md#check-google-manually), bound to a compiled runtime's full integrity hash. These reference observations cannot populate that record. Mac execution requires access to a native Mac; downloading Mac archives on Windows is not a Mac test.

The local Windows tooling suite completed with **107 passed, four Mac capability skips and no failures** (111 tests). This includes guard tests using mocked native tools, actual pinned reference-file checks and local filesystem/process tests; it does not compile Chromium. The existing managed Python installation was separately verified as Python 3.11.8 without downloading or running a new bootstrap.

```powershell
$env:ZACRO_BRANDING_REFERENCES='C:\zacro-google-prototype\source-references\native-d0c02bfad08ec92a6ffcf989e53cd995e6381a4c'
node --test experiments/google-browser-compat/tests/*.test.cjs experiments/google-browser-compat/native-branding/tests/*.test.cjs
```
