#!/usr/bin/env node
// Executes the exact DOM adapters against deterministic event fixtures. This is
// source-policy evidence, not native binding or trusted hardware-input evidence.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../..');
const original = fs.readFileSync(path.join(root, 'src/main/guest-preload.cjs'), 'utf8');
const swift = fs.readFileSync(path.join(root, 'macos/Sources/ZacroApp/NativePeekLinkBridge.swift'), 'utf8');
const match = swift.match(/return #"""\n([\s\S]*?)\n    """#/);
if (!match) throw new Error('Cannot locate the exact isolated-world DOM adapter');
const native = match[1].replace('\\#(name)', JSON.stringify('testBinding'));
new vm.Script(native);
const fixtures = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/peek-link-cases.json'), 'utf8'));
const defaults = { sourceURL: 'https://source.example/current', url: 'https://other.example/page',
  pinnedURL: null, trusted: true, button: 0, shift: false, alt: false, control: false, meta: false,
  download: false, defaultPrevented: false, target: '', rel: '', x: 23, y: 45 };

function run(code, item, isNative, lifecycle) {
  const listeners = [], messages = [], registrations = new Map();
  const context = { URL, AbortController, location: { href: item.sourceURL },
    document: { readyState: 'loading', body: null },
    addEventListener(type, callback, options) { listeners.push({ type, callback, capture: options === true || options?.capture, signal: options?.signal }); },
    require(name) {
      if (name !== 'electron') throw new Error('Unexpected module');
      return { ipcRenderer: {
        on(name, callback) { registrations.set(name, callback); },
        send(name, value) { messages.push({ kind: name === 'zacro:peek-link' ? 'modified' : 'pinned', value }); },
      } };
    },
    testBinding(value) { const parsed = JSON.parse(value); messages.push({ kind: parsed.kind, value: parsed }); },
  };
  context.window = context; context.top = lifecycle === 'subframe' ? {} : context;
  vm.createContext(context); vm.runInContext(code, context, { timeout: 1000 });
  let pinned = item.pinnedURL;
  if (pinned && !/^https?:$/.test(new URL(pinned).protocol)) pinned = null;
  if (isNative) context.__zacroPeekState?.arm({ nonce: 'fixture', sourceURL: item.sourceURL, pinnedURL: pinned });
  else registrations.get('zacro:pin-state')({}, { documentId: 'fixture', pinnedUrl: pinned });
  if (lifecycle === 'unarmed') context.__zacroPeekState.arm(null);
  if (lifecycle === 'disposed') context.__zacroPeekState.dispose();
  if (lifecycle === 'changed-document') context.location.href = 'https://source.example/another-document';
  if (lifecycle === 'removed-binding') delete context.testBinding;
  if (lifecycle === 'pagehide') for (const value of listeners.filter(v => v.type === 'pagehide')) value.callback({});
  let stopped = false, prevented = item.defaultPrevented;
  const link = { tagName: 'A', href: item.url, target: item.target, rel: item.rel,
    hasAttribute(name) { return name === 'download' && item.download; } };
  const event = { isTrusted: item.trusted, button: item.button, shiftKey: item.shift,
    altKey: item.alt, ctrlKey: item.control, metaKey: item.meta, clientX: item.x, clientY: item.y,
    get defaultPrevented() { return prevented; },
    composedPath() { return [link]; }, preventDefault() { prevented = true; },
    stopImmediatePropagation() { stopped = true; },
  };
  for (const listener of listeners.filter(v => v.type === 'click').sort((a,b) => Number(b.capture) - Number(a.capture))) {
    if (!stopped && !listener.signal?.aborted) listener.callback(event);
  }
  return { messages, prevented, stopped };
}

function literal(value) {
  return '"' + [...value].map(char => {
    if (char === '"' || char === '\\') return '\\' + char;
    const code = char.codePointAt(0);
    return code < 32 || code > 126 ? `\\u{${code.toString(16).toUpperCase()}}` : char;
  }).join('') + '"';
}
const cases = [];
for (const fixture of fixtures) {
  const item = { ...defaults, ...fixture };
  const reference = run(original, item, false), actual = run(native, item, true);
  const summary = value => JSON.stringify({ kinds: value.messages.map(v => v.kind), prevented: value.prevented, stopped: value.stopped });
  if (summary(reference) !== summary(actual)) throw new Error(`${item.name}: source adapters differ: ${summary(reference)} != ${summary(actual)}`);
  const kind = reference.messages[0]?.kind || (item.shift !== item.alt ? 'modified' : 'pinned');
  const payload = { ...item, nonce: 'fixture', sequence: 1, kind };
  delete payload.name; delete payload.pinnedURL;
  cases.push({ name: item.name, payload: JSON.stringify(payload), pinnedURL: item.pinnedURL,
    sourceURL: item.sourceURL, accepted: reference.messages.length === 1 });
}
const lifecycleCases = ['subframe', 'unarmed', 'disposed', 'changed-document', 'removed-binding', 'pagehide'];
for (const name of lifecycleCases) {
  const result = run(native, { ...defaults, shift: true }, true, name);
  if (result.messages.length || result.prevented || result.stopped) throw new Error(`${name}: revoked adapter intercepted a click`);
}
const generated = `// Generated by macos/scripts/check-peek-link-bridge.cjs --write.
// Expected decisions execute src/main/guest-preload.cjs, not the Swift policy.
import Foundation

enum NativePeekLinkAcceptance {
  static func check() -> [String: Bool] {
    let cases: [(String, String, String, String?, Bool)] = [
${cases.map(v => `      (${literal(v.name)}, ${literal(v.payload)}, ${literal(v.sourceURL)}, ${v.pinnedURL == null ? 'nil' : literal(v.pinnedURL)}, ${v.accepted})`).join(',\n')}
    ]
    var checks = Dictionary(uniqueKeysWithValues: cases.map { name, payload, source, pin, expected in
      let snapshot = NativePeekLinkSnapshot(pageID: "tab", profileID: "profile", ownerWindowID: "window",
        sourceURL: source, pinnedURL: pin, visible: true)
      let click = try? JSONDecoder().decode(NativePeekLinkClick.self, from: Data(payload.utf8))
      let accepted = click.flatMap { NativePeekLinkPolicy.destination($0, snapshot: snapshot) } != nil
      return ("peekLinkReference_" + name, click != nil && accepted == expected)
    })
    let source = "https://source.example/current"
    func snapshot(visible: Bool = true, sourceURL: String = "https://source.example/current") -> NativePeekLinkSnapshot {
      NativePeekLinkSnapshot(pageID: "tab", profileID: "profile", ownerWindowID: "window",
        sourceURL: sourceURL, pinnedURL: nil, visible: visible)
    }
    func click(kind: String = "modified", x: Double = 23, y: Double = 45) -> NativePeekLinkClick {
      NativePeekLinkClick(nonce: "fixture", sequence: 1, kind: kind, sourceURL: source,
        url: "https://other.example/page", trusted: true, button: 0, shift: true, alt: false,
        control: false, meta: false, download: false, defaultPrevented: false,
        target: "", rel: "", x: x, y: y)
    }
    checks["peekLinkHost_hiddenDocument"] = NativePeekLinkPolicy.destination(click(), snapshot: snapshot(visible: false)) == nil
    checks["peekLinkHost_changedDocument"] = NativePeekLinkPolicy.destination(click(), snapshot: snapshot(sourceURL: source + "#changed")) == nil
    checks["peekLinkHost_unknownAction"] = NativePeekLinkPolicy.destination(click(kind: "navigate"), snapshot: snapshot()) == nil
    checks["peekLinkHost_nonfiniteX"] = NativePeekLinkPolicy.destination(click(x: .infinity), snapshot: snapshot()) == nil
    checks["peekLinkHost_nonfiniteY"] = NativePeekLinkPolicy.destination(click(y: .nan), snapshot: snapshot()) == nil
    checks["peekLinkHost_unboundedCoordinate"] = NativePeekLinkPolicy.destination(click(x: 1_000_001), snapshot: snapshot()) == nil
    checks["peekLinkHost_boundedCoordinate"] = NativePeekLinkPolicy.destination(click(x: -1_000_000), snapshot: snapshot()) != nil
    return checks
  }
}
`;
const output = path.join(root, 'macos/Sources/ZacroApp/NativePeekLinkAcceptance.swift');
if (process.argv[2] === '--write') fs.writeFileSync(output, generated);
else if (process.argv.length > 3 || process.argv[2] && process.argv[2] !== '--check') throw new Error('Use --check or --write');
else if (fs.readFileSync(output, 'utf8') !== generated) throw new Error('Swift reference cases changed; inspect and regenerate with --write');
console.log(`${cases.length} exact DOM-adapter decisions match Electron; ${lifecycleCases.length} adapter lifecycle checks pass. Native Swift/binding execution is separate.`);
