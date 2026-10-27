# Website sign-in

Zacro keeps website cookies and storage in the selected browser profile. Regular profiles persist them; private profiles use an in-memory session. Website accounts are separate from the optional AI connections and from any future Zacro account or sync service.

## Redirects and popups

Website redirects, form POSTs and popup login flows use Chromium's real page session. Popups keep their opener relationship and cannot weaken sandbox, context isolation or web security. A popup can return a result with `postMessage` and close itself; when it was the active tab, Zacro returns to its surviving opener. Closing a background popup does not steal focus.

A favorite with a live popup is excluded from automatic and manual sleep because the original document may be waiting for a login callback. This protection ends when the popup closes. Closing the opener explicitly still follows the ordinary unsaved-work checks. Popup relationships are runtime state, never exported or restored as credentials.

The native regression suite uses local fixtures to exercise cross-origin callbacks, opener restoration, POST preservation, session isolation and sandbox settings. These checks establish browser mechanics, **not acceptance by Google or another identity provider**.

## Google

Google can reject sign-in inside an embedded browser. Its [account support guidance](https://support.google.com/accounts/answer/7675428?hl=en) and [OAuth policy](https://developers.google.com/identity/protocols/oauth2/policies) describe restrictions on unsupported and developer-controlled embedded user agents. Zacro uses Electron, so a working popup implementation alone cannot guarantee Google acceptance. Live Google sign-in remains unverified; Zacro does not bypass a provider's browser restrictions or import credentials from another browser.

**Page menu → Open in default browser** opens the current website in the system browser. A sign-in completed there stays in that browser's session; it does not silently transfer an account into Zacro.

A future **Sign in to Zacro with Google** is a different feature. It requires a registered Google OAuth client, a defined account service and the [system-browser native-app flow](https://developers.google.com/identity/protocols/oauth2/native-app), with validated state and PKCE. That account feature is not implemented in 0.7.
