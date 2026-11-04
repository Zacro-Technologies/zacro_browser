#!/usr/bin/env python3
"""Verify committed-error lifetime using the actual ChromiumPage delegate methods."""
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def method(source, anchor):
    start = source.index(anchor)
    opening = source.index('{', start)
    depth = 1
    cursor = opening + 1
    while depth:
        if source[cursor] == '{': depth += 1
        if source[cursor] == '}': depth -= 1
        cursor += 1
    return source[start:cursor]

source = (ROOT/'Sources/ZacroChromium/ChromiumEngine.swift').read_text()
methods = '\n'.join(method(source, anchor) for anchor in (
    '  public func browser(_ b: CefBrowser, didCommitNavigation url: URL)',
    '  public func browser(_ b: CefBrowser, didFailLoad code: Int, errorText: String, failedURL: String)',
    '  public func browser(_ b: CefBrowser, decidePolicyForNavigation url: URL?',
    '  private static func webURL(_ url: URL)'))
prelude = '''import Foundation
public final class CefBrowser {}
public enum CefNavigationDecision { case allow, cancel }
struct ChromiumDocumentError { let url: URL?; let code: Int; let message: String }
@MainActor final class Page {
  var browser: CefBrowser? = CefBrowser()
  var id = "owned-tab", url: URL? = URL(string: "http://127.0.0.1:1/failure")
  var error: String?, documentError: ChromiumDocumentError?
  var onCommittedNavigation: ((URL) -> Void)?, onChange: (() -> Void)?
  var approvedNavigationURLs: Set<String> = []
  private static func navigationKey(_ url: URL) -> String { url.absoluteString }
'''
checks = '''
}
let page = Page(), browser = page.browser!, foreign = CefBrowser()
let bad = page.url!, good = URL(string: "http://127.0.0.1:8080/recovered")!
var changes = 0, commits = 0, count = 0
@MainActor func require(_ condition: @autoclosure () -> Bool) { precondition(condition()); count += 1 }
page.onChange = { changes += 1 }
page.onCommittedNavigation = { _ in precondition(page.documentError == nil); commits += 1 }
page.browser(browser, didFailLoad: -102, errorText: "connection refused", failedURL: bad.absoluteString)
require(page.documentError?.code == -102 && page.documentError?.url == bad)
page.browser(foreign, didFailLoad: -2, errorText: "foreign error", failedURL: good.absoluteString)
require(page.documentError?.code == -102 && page.documentError?.url == bad && changes == 1)
page.browser = nil
page.browser(browser, didFailLoad: -2, errorText: "closed browser error", failedURL: good.absoluteString)
require(page.documentError?.code == -102 && page.documentError?.url == bad && changes == 1)
page.browser = browser
require(page.browser(browser, decidePolicyForNavigation: bad, isMainFrame: true, isRedirect: false, userGesture: false) == .allow)
require(page.documentError?.code == -102)
page.browser(browser, didFailLoad: -3, errorText: "aborted duplicate retry", failedURL: bad.absoluteString)
require(page.documentError?.code == -102 && changes == 1)
require(page.browser(browser, decidePolicyForNavigation: good, isMainFrame: true, isRedirect: false, userGesture: true) == .allow)
require(page.documentError?.url == bad)
page.browser(foreign, didCommitNavigation: good)
require(page.documentError?.url == bad && commits == 0)
page.browser(browser, didCommitNavigation: good)
require(page.documentError == nil && page.error == nil && commits == 1 && changes == 2)
page.browser(browser, didFailLoad: -2, errorText: "postcommit filter error", failedURL: good.absoluteString)
require(page.documentError?.url == good && page.documentError?.code == -2)
require(page.browser(browser, decidePolicyForNavigation: URL(string: "javascript:void(0)")!, isMainFrame: true, isRedirect: false, userGesture: false) == .cancel)
require(page.documentError?.code == -2)
require(page.browser(browser, decidePolicyForNavigation: good, isMainFrame: false, isRedirect: false, userGesture: false) == .allow && page.documentError?.code == -2)
page.browser(browser, didCommitNavigation: good)
page.error = "close preparation failed"
require(page.browser(browser, decidePolicyForNavigation: good, isMainFrame: true, isRedirect: false, userGesture: true) == .allow && page.error == nil)
require(commits == 2 && page.browser === browser)
print("{\\"checks\\":\\(count)}")
'''
with tempfile.TemporaryDirectory(prefix='zacro-document-error-') as temporary:
    code = Path(temporary)/'fixture.swift'
    binary = Path(temporary)/'fixture'
    code.write_text(prelude + methods + checks)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', str(code), '-o', str(binary)], check=True)
    result = json.loads(subprocess.check_output([str(binary)], text=True))
    if result != {'checks': 16}: raise ValueError(result)
    print(json.dumps(result))
