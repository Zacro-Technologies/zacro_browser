# Website sign-in

This covers signing into Google websites and other websites' **Continue with Google** flows. It does not add a Zacro account or an OAuth client on behalf of those websites.

Zacro keeps website cookies and storage in the selected browser profile. Regular profiles retain persistent website cookies and local storage across normal restarts; session-only cookies expire when that session ends. Private profiles use an in-memory session. Website accounts are separate from the optional AI connections.

## Redirects and popups

Website redirects, form POSTs and popup login flows use Chromium's real page session. Popups keep their opener relationship and cannot weaken sandbox, context isolation or web security. A popup can return a result with `postMessage` and close itself; when it was the active tab, Zacro returns to its surviving opener. Closing a background popup does not steal focus.

If a page in Peek opens a popup, Zacro promotes the original document into a tab before showing the popup. Its callback listener, form data, navigation history and Chromium session remain alive. Promotion adopts the existing page without reloading it or repeating its request. Popups from split view also retain their original page.

A favorite with a live popup is excluded from automatic and manual sleep because the original document may be waiting for a login callback. This protection ends when the popup closes. Closing the opener explicitly still follows the ordinary unsaved-work checks. Popup relationships are runtime state, never exported or restored as credentials.

The native regression suite uses local fixtures to exercise cross-origin callbacks, opener restoration, POST preservation, session isolation and sandbox settings. These checks establish browser mechanics, **not acceptance by Google or another identity provider**.

## Google

Google can reject sign-in inside an embedded browser. Its [account support guidance](https://support.google.com/accounts/answer/7675428?hl=en) and [OAuth policy](https://developers.google.com/identity/protocols/oauth2/policies) describe restrictions on unsupported and developer-controlled embedded user agents. Zacro uses Electron, so a working popup implementation alone cannot guarantee Google acceptance. Live Google sign-in remains unverified; Zacro does not bypass a provider's browser restrictions or import credentials from another browser.

**FedCM account selection is unsupported in the current runtime.** Source review of [Electron 45's browser client](https://github.com/electron/electron/blob/v45.0.0/shell/browser/electron_browser_client.h) and [Chromium 156's default identity controller](https://github.com/chromium/chromium/blob/156.0.8078.48/content/public/browser/webid/identity_request_dialog_controller.cc) shows that this runtime has no browser-owned account chooser: the default controller dismisses requests without presenting one. Any Google One Tap or button flow that requires that chooser remains unsupported. This is a separate engine capability from ordinary popup/redirect callbacks. Google's [compatibility guidance](https://developers.google.com/identity/gsi/web/guides/supported-browsers) recommends against disabling FedCM; Zacro does not apply such a flag or inject replacement identity responses.

**Page menu → Open in default browser** opens the current website in the system browser. A sign-in completed there stays in that browser's session; it does not silently transfer an account into Zacro.

Live acceptance must cover Google account login, an actual website's Google callback, account selection, sign-out, and restart in a dedicated test profile. A successful local fixture does not satisfy those checks. Full support also requires a runtime with the native identity interface and Google's acceptance of that browser.

## Local manual check

Run `npm run test:interactive`, navigate to the printed local origin plus `/popup-check`, and use the link menu to open that check in Peek. Select **Open test popup**, then **Return test result**. The original page should return with a passed result. This fixture uses only loopback pages and a fixed test message; it never requests credentials or contacts an identity provider.
