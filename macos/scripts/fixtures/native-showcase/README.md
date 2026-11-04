# Local browser showcase

Original, self-contained demo pages for native Zacro screenshots. They use local CSS and SVG artwork, with no accounts or external requests.

From the repository root:

```sh
python3 -m http.server 8080 --bind 127.0.0.1 --directory macos/scripts/fixtures/native-showcase
```

Open `http://127.0.0.1:8080/index.html` in a disposable browser profile. The pages link to one another and include a note field for checking retained content. Shift-click a link to open Peek.

The README gallery uses a light Space with primary `#486786`, secondary `#78B8A2`, intensity 65%, blend 50%, grain 24%, tint opacity 100% and blur 0%. Opaque tint keeps other desktop windows out of the captures. Capture the complete browser window without compositing or retouching its interface; preserve any operating-system sharing indicator.
