#!/usr/bin/env python3
"""Execute the pinned CEF navigation callback's real error-address branches."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def verify(chromium):
    cef = chromium / 'cef'
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=cef, text=True).strip()
    if not revision.startswith('4fa4ab5'):
        raise ValueError('The pinned CEF revision is required')
    text = (cef / 'libcef/browser/browser_contents_delegate.cc').read_text()
    start = text.index('void CefBrowserContentsDelegate::DidFinishNavigation(')
    method = text[start:text.index('\nvoid CefBrowserContentsDelegate::DidFailLoad(', start)]
    if 'OnAddressChange(navigation_handle->GetURL());' not in method:
        raise ValueError('Apply the current CEF adapter before testing')
    prelude = r'''
#include <cassert>
#include <iostream>
#include <memory>
#include <string>
#include <vector>
#define DCHECK(x) assert(x)
namespace net { using Error = int; constexpr Error OK = 0; }
using GURL = std::string;
template<class T> using CefRefPtr = std::shared_ptr<T>;
namespace content {
struct NavigationHandle {
  int error = 0; bool committed = true, primary = true, main = true;
  bool same = false, cached = false;
  GURL url = "http://127.0.0.1:1/failed";
  int GetNetErrorCode() { return error; }
  bool HasCommitted() { return committed; }
  bool IsInPrimaryMainFrame() { return primary; }
  bool IsInMainFrame() { return main; }
  bool IsSameDocument() { return same; }
  bool IsServedFromBackForwardCache() { return cached; }
  const GURL& GetURL() { return url; }
  int GetPageTransition() { return 0; }
};
}
namespace frame_util {
int GetGlobalId(content::NavigationHandle*) { return 1; }
int InvalidGlobalId() { return -1; }
}
struct CefFrameHostImpl { void RefreshAttributes() {} };
struct BrowserInfo {
  bool closing = false, missing = false;
  int mainFallback = 0, subFallback = 0;
  bool IsClosing() { return closing; }
  CefRefPtr<CefFrameHostImpl> GetFrameForGlobalId(int) {
    return missing ? nullptr : std::make_shared<CefFrameHostImpl>();
  }
  CefRefPtr<CefFrameHostImpl> GetMainFrame() {
    ++mainFallback; return std::make_shared<CefFrameHostImpl>();
  }
  CefRefPtr<CefFrameHostImpl> CreateTempSubFrame(int) {
    ++subFallback; return std::make_shared<CefFrameHostImpl>();
  }
};
struct CefBrowserContentsDelegate {
  BrowserInfo info; BrowserInfo* browser_info_ = &info;
  bool has_document_ = true;
  enum class State { kDocument };
  std::vector<std::string> calls;
  GURL address;
  void OnStateChanged(State) { calls.push_back("state"); }
  void OnLoadStart(CefFrameHostImpl*, int) { calls.push_back("start"); }
  void OnLoadEnd(CefFrameHostImpl*, const GURL&, int) { calls.push_back("end"); }
  void OnLoadError(CefFrameHostImpl*, const GURL&, int) { calls.push_back("error"); }
  void OnAddressChange(const GURL& value) { calls.push_back("address"); address = value; }
  void DidFinishNavigation(content::NavigationHandle*);
};
'''
    checks = r'''
int main() {
  int checks = 0;
  auto run = [&](content::NavigationHandle n, std::vector<std::string> expected,
                 bool closing = false, bool missing = false) {
    CefBrowserContentsDelegate d; d.info.closing = closing; d.info.missing = missing;
    d.DidFinishNavigation(&n);
    assert(d.calls == expected);
    const bool sent = !expected.empty() && expected.back() == "address";
    assert(d.address == (sent ? n.url : GURL()));
    if (missing) assert(n.main ? d.info.mainFallback == 1 : d.info.subFallback == 1);
    ++checks;
  };
  content::NavigationHandle n;
  n.error = -312; run(n, {"state", "error", "address"});
  n.committed = false; run(n, {"error"});
  n.error = -3; run(n, {"error"});
  n.committed = true; n.primary = false; n.main = false; run(n, {"error"});
  n.main = true; run(n, {"error"}); // Non-primary main frame must not replace shell address.
  n = {}; run(n, {"state", "start", "address"});
  n.same = true; run(n, {"state", "address"});
  n.same = false; n.cached = true; run(n, {"state", "start", "end", "address"});
  n.committed = false; run(n, {});
  n = {}; run(n, {}, true);
  n.error = -102; run(n, {"state", "error", "address"}, false, true);
  n.primary = false; n.main = false; run(n, {"error"}, false, true);
  std::cout << "{\"checks\":" << checks << "}\n";
}
'''
    with tempfile.TemporaryDirectory(prefix='zacro-error-address-') as temporary:
        source = Path(temporary) / 'fixture.cc'
        binary = Path(temporary) / 'fixture'
        source.write_text(prelude + method + checks)
        subprocess.run(['xcrun', 'clang++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                        str(source), '-o', str(binary)], check=True, timeout=45)
        result = json.loads(subprocess.check_output([str(binary)], text=True, timeout=10))
        if result != {'checks': 12}:
            raise ValueError(result)
        print(json.dumps({**result, 'actualProductionCallback': True,
                          'actualChromiumCompile': False, 'runtimeAcceptance': False}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--chromium-root', required=True, type=Path)
    verify(parser.parse_args().chromium_root.resolve())
