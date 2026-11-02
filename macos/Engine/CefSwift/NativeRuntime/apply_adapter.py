#!/usr/bin/env python3
"""Apply the native protocol adapter to the exact pinned CEF source checkout."""
import argparse
import difflib
import pathlib
import subprocess
import tempfile

PIN = "4fa4ab5"
ROOT = pathlib.Path(__file__).resolve().parent


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise SystemExit(f"Source drift: expected exactly one occurrence of {old[:80]!r}")
    return text.replace(old, new, 1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cef-root", required=True, type=pathlib.Path)
    parser.add_argument("--check", action="store_true", help="Produce a reviewable patch without changing the checkout")
    args = parser.parse_args()
    cef = args.cef_root.resolve()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=cef, text=True).strip()
    if not revision.startswith(PIN):
        raise SystemExit(f"Expected CEF {PIN}, found {revision}; update and review this adapter before applying.")
    paths = ["libcef/browser/devtools/devtools_controller.h", "libcef/browser/devtools/devtools_controller.cc", "BUILD.gn",
             "libcef/browser/browser_platform_delegate.h", "libcef/browser/browser_platform_delegate.cc",
             "libcef/browser/chrome/chrome_browser_main_extra_parts_cef.h",
             "libcef/browser/chrome/chrome_browser_main_extra_parts_cef.cc",
             "libcef/browser/net/throttle_handler.cc"]
    originals = {path: subprocess.check_output(["git", "show", f"HEAD:{path}"], cwd=cef, text=True) for path in paths}
    output = dict(originals)
    header = output[paths[0]]
    header = replace_once(header, "#include <memory>", "#include <memory>\n#include <map>\n#include <set>\n#include <vector>")
    header = replace_once(header, '#include "base/memory/raw_ptr.h"', '#include "base/memory/raw_ptr.h"\n#include "base/callback_list.h"')
    header = replace_once(header, "class CefDevToolsController", "class ZacroDataRemoval;\nclass ZacroDiscardOperation;\nclass ZacroDocumentObserver;\nnamespace sessions { class SerializedNavigationEntry; }\n\nclass CefDevToolsController")
    header = replace_once(header, "  bool EnsureAgentHost();", """  bool EnsureAgentHost();
  bool DispatchZacro(const std::string_view& message);
  void ReplyZacro(int id, base::DictValue result, const std::string& error = {});
  void EmitZacro(const std::string& method, const base::DictValue& params);
  bool DispatchZacroExtensions(int id, const std::string& method, const base::DictValue* params);
  bool DispatchZacroTopology(int id, const std::string& method, const base::DictValue* params);
  bool DispatchZacroBookmarks(int id, const std::string& method, const base::DictValue* params);
  bool DispatchZacroDownloads(int id, const std::string& method, const base::DictValue* params);
  base::CallbackListSubscription zacro_extension_subscription_;
  void FinishZacroDataRemoval(int id, uint64_t failed_types);
  void FinishZacroDiscard(int id, int entry_id, const std::string& error);
  std::unique_ptr<ZacroDiscardOperation> zacro_discard_;
  std::unique_ptr<ZacroDocumentObserver> zacro_document_observer_;
  int zacro_dormant_entry_ = 0;
  std::vector<sessions::SerializedNavigationEntry> zacro_dormant_history_;
  int zacro_dormant_selected_ = 0;
  scoped_refptr<content::DevToolsAgentHost> zacro_browser_agent_;
  std::set<std::string> zacro_browser_sessions_;
  std::map<int, std::unique_ptr<ZacroDataRemoval>> zacro_data_removals_;""")
    output[paths[0]] = header
    code = output[paths[1]]
    code = replace_once(code, '#include "content/public/browser/devtools_agent_host.h"', '#include "content/public/browser/devtools_agent_host.h"\n#include "cef/libcef/browser/devtools/zacro_native_adapter.inc"')
    code = replace_once(code, "CefDevToolsController::~CefDevToolsController() {", """CefDevToolsController::~CefDevToolsController() {
  zacro_data_removals_.clear();
  zacro_discard_.reset();
  zacro_document_observer_.reset();
  zacro_extension_subscription_ = {};
  if (zacro_browser_agent_) {
    zacro_browser_agent_->DetachClient(this);
    zacro_browser_agent_ = nullptr;
  }""")
    code = replace_once(code, """  agent_host_->DispatchProtocolMessage(this,
                                       base::as_bytes(base::span(message)));""", """  if (DispatchZacro(message)) return true;
  agent_host_->DispatchProtocolMessage(this,
                                       base::as_bytes(base::span(message)));""")
    code = replace_once(code, "  DCHECK(agent_host == agent_host_.get());", """  if (agent_host == zacro_browser_agent_.get()) {
    zacro_browser_agent_ = nullptr;
    zacro_browser_sessions_.clear();
    return;
  }
  DCHECK(agent_host == agent_host_.get());""")
    code = replace_once(code, """  devtools_util::ProtocolParser parser;""", """  // Flattened sessions attached through the browser agent must keep routing
  // through that agent, rather than the inspected document's page agent.
  if (agent_host == zacro_browser_agent_.get()) {
    if (auto response = base::JSONReader::ReadDict(str_message, base::JSON_PARSE_RFC)) {
      if (const auto* result = response->FindDict("result")) {
        if (const auto* session = result->FindString("sessionId")) zacro_browser_sessions_.insert(*session);
      }
      const auto* method = response->FindString("method");
      const auto* params = response->FindDict("params");
      const auto* session = params ? params->FindString("sessionId") : nullptr;
      if (method && session) {
        if (*method == "Target.attachedToTarget") zacro_browser_sessions_.insert(*session);
        else if (*method == "Target.detachedFromTarget") zacro_browser_sessions_.erase(*session);
      }
    }
  }

  devtools_util::ProtocolParser parser;""")
    output[paths[1]] = code
    output[paths[2]] = replace_once(output[paths[2]], '    "//components/services/print_compositor/public/mojom",', '    "//components/services/print_compositor/public/mojom",\n    "//components/sessions",\n    "//components/os_crypt/async/browser",\n    "//components/os_crypt/async/common",\n    "//chrome/browser/ui/views/extensions:extension_popup",\n    "//extensions/browser/api/runtime",')
    platform_header = replace_once(output[paths[3]], "class WebContents;", "class WebContents;\nclass ScopedAccessibilityMode;")
    output[paths[3]] = replace_once(platform_header,
        "  raw_ptr<content::WebContents> web_contents_ = nullptr;",
        "  raw_ptr<content::WebContents> web_contents_ = nullptr;\n  std::unique_ptr<content::ScopedAccessibilityMode> accessibility_mode_;")
    platform = replace_once(output[paths[4]], '#include "content/public/browser/render_view_host.h"',
        '#include "content/public/browser/render_view_host.h"\n#include "content/public/browser/browser_accessibility_state.h"\n#include "content/public/browser/scoped_accessibility_mode.h"')
    start = platform.index("void CefBrowserPlatformDelegate::SetAccessibilityState(")
    end = platform.index("\nbool CefBrowserPlatformDelegate::IsPrintPreviewSupported()", start)
    platform = platform[:start] + """void CefBrowserPlatformDelegate::SetAccessibilityState(
    cef_state_t accessibility_state) {
  // Own the accessibility request through Chromium's mode manager. Setting
  // WebContentsImpl's current mode directly is lost when visibility/platform
  // signals recompute the effective mode for a retained document.
  if (accessibility_state != STATE_ENABLED) {
    accessibility_mode_.reset();
    return;
  }
  if (!web_contents_ || accessibility_mode_) return;
  accessibility_mode_ = content::BrowserAccessibilityState::GetInstance()
      ->CreateScopedModeForWebContents(web_contents_,
          IsWindowless() ? ui::kAXModeWebContentsOnly : ui::kAXModeComplete);
}
""" + platform[end:]
    output[paths[4]] = platform
    output[paths[5]] = replace_once(output[paths[5]], "  void PostProfileInit(Profile* profile, bool is_initial_profile) override;",
        "  void PreProfileInit() override;\n  void PostProfileInit(Profile* profile, bool is_initial_profile) override;")
    output[paths[6]] = replace_once(output[paths[6]], "void ChromeBrowserMainExtraPartsCef::PostProfileInit(Profile* profile,", """// Native process-only hooks are installed before extension workers can start.
void ZacroInstallTopologyHooks();
void ChromeBrowserMainExtraPartsCef::PreProfileInit() {
  ZacroInstallTopologyHooks();
}

void ChromeBrowserMainExtraPartsCef::PostProfileInit(Profile* profile,""")
    throttle = output[paths[7]]
    throttle = replace_once(throttle, "namespace throttle {", """// Native-only approved extension destinations must be revalidated on reload,
// history traversal and subsequent navigation, not only when first opened.
bool ZacroAllowApprovedNavigation(content::WebContents* contents, const GURL& url);

namespace throttle {""")
    throttle = replace_once(throttle, "  const bool is_main_frame = navigation_handle->IsInMainFrame();", """  const bool is_main_frame = navigation_handle->IsInMainFrame();
  if (is_main_frame && !ZacroAllowApprovedNavigation(navigation_handle->GetWebContents(), navigation_handle->GetURL())) {
    std::move(result_callback).Run(true);
    return;
  }""")
    output[paths[7]] = throttle
    adapter_path = "libcef/browser/devtools/zacro_native_adapter.inc"
    originals[adapter_path] = ""
    output[adapter_path] = (ROOT / "devtools_native_adapter.inc").read_text()
    extensions_path = "libcef/browser/devtools/zacro_extensions_adapter.inc"
    originals[extensions_path] = ""
    output[extensions_path] = (ROOT / "devtools_extensions_adapter.inc").read_text()
    topology_path = "libcef/browser/devtools/zacro_topology_adapter.inc"
    originals[topology_path] = ""
    output[topology_path] = (ROOT / "devtools_topology_adapter.inc").read_text()
    bookmarks_path = "libcef/browser/devtools/zacro_bookmarks_adapter.inc"
    originals[bookmarks_path] = ""
    output[bookmarks_path] = (ROOT / "devtools_bookmarks_adapter.inc").read_text()
    downloads_path = "libcef/browser/devtools/zacro_downloads_adapter.inc"
    originals[downloads_path] = ""
    output[downloads_path] = (ROOT / "devtools_downloads_adapter.inc").read_text()
    diff = "".join("".join(difflib.unified_diff(originals[path].splitlines(True), contents.splitlines(True),
        fromfile="a/" + path if originals[path] else "/dev/null", tofile="b/" + path)) for path, contents in output.items())
    previous = {}
    patch_path = ROOT / "native-adapter.patch"
    if patch_path.exists():
        # Reconstruct only our previous generated outputs. Comparing exact
        # contents preserves unrelated edits even outside old patch hunks.
        with tempfile.TemporaryDirectory(prefix="zacro-cef-patch-") as temporary:
            staging = pathlib.Path(temporary)
            for path, contents in originals.items():
                if contents:
                    destination = staging / path
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_text(contents)
            applied = subprocess.run(["git", "apply", str(patch_path)], cwd=staging, capture_output=True)
            if applied.returncode == 0:
                previous = {path: (staging / path).read_text() for path in output if (staging / path).exists()}
    for path, contents in output.items():
        target = cef / path
        current = target.read_text() if target.exists() else ""
        if current not in (originals[path], contents, previous.get(path)):
            raise SystemExit(f"Refusing to overwrite unrelated changes in {target}")
    if not args.check:
        for path, contents in output.items():
            destination = cef / path
            if not destination.exists() or destination.read_text() != contents:
                destination.write_text(contents)
    patch_path.write_text(diff)
    print(f"{'Checked' if args.check else 'Applied'} CEF {revision[:12]} adapter; patch: {ROOT / 'native-adapter.patch'}")


if __name__ == "__main__":
    main()
