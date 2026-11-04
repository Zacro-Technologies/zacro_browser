#!/usr/bin/env python3
"""Route actual installed ExtensionHost children through native CEF ownership."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
PIN = "d0c02bfad08ec92a6ffcf989e53cd995e6381a4c"
CEF_PIN = "4fa4ab516dacf6c49fc7e6e70d2b7ebce29fa35f"
# CEF's official translator output is generated/ignored, not stored in git.
# Pin its exact original bytes as well as the source revision; never adopt an
# arbitrary local wrapper as the baseline for the private helper addition.
CLIENT_BASELINE_SHA256 = "2f97d1d04bfdde1c9d0e42c4e11bccaf97aece51b2331771474a3ee774a4722e"
HOST_H = "extensions/browser/extension_host.h"
HOST_CC = "extensions/browser/extension_host.cc"
VIEW_CC = "chrome/browser/extensions/extension_view_host.cc"
MANAGER_H = "cef/libcef/browser/browser_info_manager.h"
MANAGER_CC = "cef/libcef/browser/browser_info_manager.cc"
DELEGATE_H = "cef/libcef/browser/chrome/chrome_browser_delegate.h"
IMPL_H = "cef/libcef/browser/chrome/chrome_browser_host_impl.h"
CLIENT_CC = "cef/libcef_dll/ctocpp/client_ctocpp.cc"
NEW = {
    "cef/libcef/browser/devtools/zacro_extension_host_navigation.h": "native_extension_host_navigation.h.in",
    "cef/libcef/browser/devtools/zacro_extension_host_navigation.cc": "native_extension_host_navigation.cc.in",
    "cef/libcef/browser/devtools/zacro_extension_host_navigation_capi.h": "native_extension_host_navigation_capi.h.in",
    "cef/libcef/browser/devtools/zacro_extension_host_client_bridge.h": "native_extension_host_client_bridge.h.in",
}
PATHS = (HOST_H, HOST_CC, VIEW_CC, MANAGER_H, MANAGER_CC, DELEGATE_H, IMPL_H, CLIENT_CC, *NEW)


def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError("Pinned extension-host navigation drift: " + old[:100])
    return text.replace(old, new)


def generated(original):
    out = dict(original)
    out[HOST_H] = replace(out[HOST_H], "  using CloseHandler = base::OnceCallback<void(ExtensionHost*)>;", '''  using CloseHandler = base::OnceCallback<void(ExtensionHost*)>;
  // Private embedding hooks retain the real source RFH and created WebContents.
  // They neither construct an ExtensionFunction nor override its permissions.
  using NativePopupCreated = base::RepeatingCallback<void(ExtensionHost*,
      content::WebContents*, const content::GlobalRenderFrameHostId&, const GURL&,
      content::WebContents*)>;
  using NativePopupAdded = base::RepeatingCallback<bool(ExtensionHost*,
      content::WebContents*, std::unique_ptr<content::WebContents>&)>;
  using NativeOpenURL = base::RepeatingCallback<bool(ExtensionHost*,
      const content::OpenURLParams&, base::OnceCallback<void(content::NavigationHandle&)>&,
      content::WebContents**)>;
  static void SetNativeNavigationHooks(NativePopupCreated created,
      NativePopupAdded added, NativeOpenURL open);
  bool OpenURLWithNativeHost(const content::OpenURLParams& params,
      base::OnceCallback<void(content::NavigationHandle&)>& callback,
      content::WebContents** result);
  void WebContentsCreated(content::WebContents* source,
      const content::GlobalRenderFrameHostId& opener, const std::string& frame_name,
      const GURL& target_url, content::WebContents* created) override;''')
    out[HOST_CC] = replace(out[HOST_CC], "namespace extensions {", '''namespace extensions {
namespace {
struct NativeNavigationHooks {
  ExtensionHost::NativePopupCreated created;
  ExtensionHost::NativePopupAdded added;
  ExtensionHost::NativeOpenURL open;
};
NativeNavigationHooks& NativeHostHooks() {
  static base::NoDestructor<NativeNavigationHooks> value;
  return *value;
}
}  // namespace
void ExtensionHost::SetNativeNavigationHooks(NativePopupCreated created,
    NativePopupAdded added, NativeOpenURL open) {
  NativeHostHooks() = {std::move(created), std::move(added), std::move(open)};
}
bool ExtensionHost::OpenURLWithNativeHost(const content::OpenURLParams& params,
    base::OnceCallback<void(content::NavigationHandle&)>& callback,
    content::WebContents** result) {
  auto& open = NativeHostHooks().open;
  return open && open.Run(this, params, callback, result);
}
void ExtensionHost::WebContentsCreated(content::WebContents* source,
    const content::GlobalRenderFrameHostId& opener, const std::string& frame_name,
    const GURL& target_url, content::WebContents* created) {
  auto& hook = NativeHostHooks().created;
  if (hook) hook.Run(this, source, opener, target_url, created);
}
''')
    out[HOST_CC] = replace(out[HOST_CC], "  delegate_->CreateTab(std::move(new_contents), target_url, extension_id_,", '''  auto& native = NativeHostHooks().added;
  if (native && native.Run(this, source, new_contents)) return nullptr;
  delegate_->CreateTab(std::move(new_contents), target_url, extension_id_,''')
    out[VIEW_CC] = replace(out[VIEW_CC], "  // Allowlist the dispositions we will allow to be opened.", '''  content::WebContents* native_result = nullptr;
  if (OpenURLWithNativeHost(params, navigation_handle_callback, &native_result)) return native_result;
  // Allowlist the dispositions we will allow to be opened.''')
    out[MANAGER_H] = replace(out[MANAGER_H], '#include "content/public/browser/global_routing_id.h"',
        '#include "content/public/browser/global_routing_id.h"\n#include "content/public/browser/weak_document_ptr.h"')
    out[MANAGER_H] = replace(out[MANAGER_H], "class CefBrowserHostBase;", "namespace extensions { class ExtensionHost; }\nclass CefBrowserHostBase;")
    out[MANAGER_H] = replace(out[MANAGER_H], "  // Called from ContentBrowserClient::CreateWindowResult if CanCreateWindow", '''  // Real ExtensionHost producers after Chrome's normal popup/navigation policy.
  bool PrepareNativeExtensionHostPopup(content::RenderFrameHost* opener,
      const GURL& target_url, const std::string& frame_name,
      WindowOpenDisposition disposition, const blink::mojom::WindowFeatures& features,
      bool user_gesture);
  void NativeExtensionHostWebContentsCreated(extensions::ExtensionHost* source_host,
      content::WebContents* source, const content::GlobalRenderFrameHostId& opener,
      const GURL& target_url, content::WebContents* created);
  bool AddNativeExtensionHostContents(extensions::ExtensionHost* source_host,
      content::WebContents* source, std::unique_ptr<content::WebContents>& created);
  bool OpenNativeExtensionHostURL(extensions::ExtensionHost* source_host,
      const content::OpenURLParams& params,
      base::OnceCallback<void(content::NavigationHandle&)>& callback,
      content::WebContents** result);

  // Called from ContentBrowserClient::CreateWindowResult if CanCreateWindow''')
    out[MANAGER_H] = replace(out[MANAGER_H], "class WebContentsView;", "class WebContentsView;\nclass NavigationHandle;")
    out[MANAGER_H] = replace(out[MANAGER_H], "    // Values specified by OnBeforePopup.", '''    // Separate provenance for an installed ExtensionHost, not a public tab or
    // fabricated CefFrame. Revalidated at creation and ownership transfer.
    content::WeakDocumentPtr native_host_document;
    int native_host_owner_browser = 0;
    int native_host_owner_window = 0;
    std::string native_host_extension;

    // Values specified by OnBeforePopup.''')
    out[MANAGER_CC] = replace(out[MANAGER_CC], "  CefRefPtr<CefBrowserHostBase> browser;\n  if (!MaybeAllowNavigation(opener, params, browser) || !browser) {", '''  // ChromeContentBrowserClientCef has already applied the genuine opener's
  // popup blocker, origin, sandbox and extension policy. A hosted extension UI
  // has no CefFrame; retain that real RFH through its own native owner path.
  if (!CefBrowserHostBase::GetBrowserForHost(opener)) {
    return PrepareNativeExtensionHostPopup(opener, target_url, frame_name,
        disposition, features, user_gesture);
  }
  CefRefPtr<CefBrowserHostBase> browser;
  if (!MaybeAllowNavigation(opener, params, browser) || !browser) {''')
    out[DELEGATE_H] = replace(out[DELEGATE_H], " private:\n", " private:\n  friend class CefBrowserInfoManager;\n")
    out[IMPL_H] = replace(out[IMPL_H], "  friend class ChromeBrowserDelegate;",
        "  friend class ChromeBrowserDelegate;\n  friend class CefBrowserInfoManager;")
    out[CLIENT_CC] = replace(out[CLIENT_CC], '#include "libcef_dll/ctocpp/client_ctocpp.h"',
        '#include "libcef_dll/ctocpp/client_ctocpp.h"\n#include "cef/libcef/browser/devtools/zacro_extension_host_client_bridge.h"')
    out[CLIENT_CC] += "\n" + (ROOT / "native_extension_host_client_bridge.inc").read_text()
    for path, template in NEW.items():
        out[path] = (ROOT / template).read_text()
    return out


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def source_baselines(source):
    out = {}
    for path in PATHS:
        repo = source / "cef" if path.startswith("cef/") else source
        target = path[4:] if path.startswith("cef/") else path
        if path == CLIENT_CC:
            value = (source / path).read_text()
            value = value.split("\n// Private native producer boundary.", 1)[0]
            value = value.replace('#include "libcef_dll/ctocpp/client_ctocpp.h"\n#include "cef/libcef/browser/devtools/zacro_extension_host_client_bridge.h"',
                '#include "libcef_dll/ctocpp/client_ctocpp.h"')
            if digest(value) != CLIENT_BASELINE_SHA256:
                raise ValueError("The pinned generated CefClient wrapper changed; regenerate/review its canonical baseline.")
            out[path] = value
        else:
            out[path] = "" if path in NEW else subprocess.check_output(["git", "show", "HEAD:" + target], cwd=repo, text=True)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chromium-root", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    source = args.chromium_root.resolve()
    for root, pin in [(source, PIN), (source / "cef", CEF_PIN)]:
        if subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip() != pin:
            raise SystemExit("Unexpected extension-host native source pin")
    original = source_baselines(source)
    output = generated(original)
    receipt = source / "out/zacro-extension-host-navigation.json"
    prior = json.loads(receipt.read_text()) if receipt.exists() else {}
    hashes = prior.get("files", {}) if prior.get("revision") == PIN and prior.get("cefRevision") == CEF_PIN else {}
    for path, value in output.items():
        current = (source / path).read_text() if (source / path).exists() else ""
        if current not in (original[path], value) and digest(current) != hashes.get(path):
            raise SystemExit("Refusing unrelated extension-host source edits: " + path)
    patch = "".join("".join(difflib.unified_diff(original[path].splitlines(True), value.splitlines(True),
        fromfile="a/" + path if original[path] else "/dev/null", tofile="b/" + path)) for path, value in output.items())
    (ROOT / "native-extension-host-navigation.patch").write_text(patch)
    if not args.check:
        for path, value in output.items():
            target = source / path
            target.parent.mkdir(parents=True, exist_ok=True)
            if not target.exists() or target.read_text() != value:
                temporary = target.with_suffix(target.suffix + ".zacro-tmp")
                temporary.write_text(value); temporary.replace(target)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps({"revision": PIN, "cefRevision": CEF_PIN,
            "files": {path: digest(value) for path, value in output.items()}}, indent=2) + "\n")
    print(("Checked" if args.check else "Applied") + " native installed ExtensionHost navigation")


if __name__ == "__main__":
    main()
