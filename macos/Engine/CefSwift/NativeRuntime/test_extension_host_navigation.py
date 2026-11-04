#!/usr/bin/env python3
"""Check installed-host provenance and compile actual native ownership transfer."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument("--chromium-root", required=True, type=Path)
arguments, rest = parser.parse_known_args()
spec = importlib.util.spec_from_file_location("host_navigation", ROOT / "apply_extension_host_navigation.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class ExtensionHostNavigationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = m.source_baselines(arguments.chromium_root.resolve())
        cls.output = m.generated(cls.original)

    def test_pinned_generation_and_capi_identity(self):
        self.assertEqual(self.output, m.generated(self.original))
        capi = self.output["cef/libcef/browser/devtools/zacro_extension_host_navigation_capi.h"]
        self.assertEqual(capi, (ROOT.parent / "Sources/CCef/include/ccef_extension_host_navigation.h").read_text())
        changed = dict(self.original)
        changed[m.HOST_H] = changed[m.HOST_H].replace("using CloseHandler", "using OtherHandler")
        with self.assertRaises(ValueError): m.generated(changed)

    def test_client_uses_original_version_selected_wrapper_translation_unit(self):
        native = self.output["cef/libcef/browser/devtools/zacro_extension_host_navigation.cc"]
        self.assertNotIn("client_ctocpp.h", native)
        self.assertNotIn("CefClientCToCpp_Wrap", native)
        client = self.output[m.CLIENT_CC]
        self.assertEqual(client.count("::kWrapperType = WT_CLIENT;"), 1)
        self.assertLess(client.index("::kWrapperType = WT_CLIENT;"), client.index("CefRefPtr<CefClient> ZacroWrapExtensionHostClient"))
        self.assertIn("return CefClientCToCpp_Wrap(static_cast<cef_client_0_t*>(transferred));", client)
        self.assertIn("return CefClientCToCpp_Unwrap(client);", client)
        self.assertNotIn("Wno-undefined-var-template", client)

    def test_original_chrome_popup_policy_stays_first(self):
        outer = (arguments.chromium_root / "cef/libcef/browser/chrome/chrome_content_browser_client_cef.cc").read_text()
        body = outer.split("bool ChromeContentBrowserClientCef::CanCreateWindow", 1)[1].split("void ChromeContentBrowserClientCef::CreateWindowResult", 1)[0]
        self.assertLess(body.index("ChromeContentBrowserClient::CanCreateWindow"), body.index("CefBrowserInfoManager::GetInstance()->CanCreateWindow"))
        manager = self.output[m.MANAGER_CC].split("bool CefBrowserInfoManager::CanCreateWindow", 1)[1]
        self.assertIn("if (!CefBrowserHostBase::GetBrowserForHost(opener))", manager)
        self.assertIn("PrepareNativeExtensionHostPopup(opener, target_url, frame_name", manager)
        native = self.output["cef/libcef/browser/devtools/zacro_extension_host_navigation.cc"]
        self.assertNotIn("GetFrameForHost", native)
        self.assertNotIn("ExtensionFunction(", native)
        self.assertNotIn("set_user_gesture", native)

    def test_source_is_actual_installed_host_and_owner(self):
        topology = (ROOT / "devtools_topology_adapter.inc").read_text().split("ZacroInstallExtensionHostNavigation(", 1)[1].split("SetNativeUIWindowResolver", 1)[0]
        for guard in ["frame->IsRenderFrameLive()", "contents->IsBeingDestroyed()", "context->IsOffTheRecord()",
            "IsNativeWebAuthAdmissionBlocked", "GetExtensionHostForPrimaryMainFrame", "host->host_contents() != contents",
            "host->browser_context() != context", "kExtensionPopup", "kExtensionSidePanel", "host->extension()",
            "registry->enabled_extensions().GetByID(host->extension_id()) != host->extension()",
            "host->GetExtensionWindowController()", "browser->GetProfile() != context",
            "!tab->closing && !tab->discarded", "state->panel_parking_", "NativeExtensionUIWindowForLogicalWindow(window, source_window)"]:
            self.assertIn(guard, topology)

    def test_live_child_and_navigation_are_not_reconstructed_as_get(self):
        native = self.output["cef/libcef/browser/devtools/zacro_extension_host_navigation.cc"]
        self.assertIn("source_document = opener->GetWeakDocumentPtr()", native)
        self.assertIn("CreateBrowserHostForPopup(created", native)
        self.assertIn("child->AddNewContents(std::move(created), std::nullopt)", native)
        self.assertIn("LoadURLParams(params)", native)
        self.assertNotIn("LoadURL(params.url)", native)
        original = self.output[m.HOST_CC].split("ExtensionHost::AddNewContents(", 1)[1]
        self.assertLess(original.index("native.Run(this, source, new_contents)"), original.index("delegate_->CreateTab"))
        swift = (ROOT.parent / "Sources/CefKit/CefExtensionHostNavigation.swift").read_text()
        self.assertIn("child.adoptCreatedNativePopup = true", swift)
        lifetime = (ROOT.parent / "Sources/CefKit/BrowserClient.swift").read_text()
        self.assertIn("client.adoptCreatedNativePopup, let pending = client.browser", lifetime)
        self.assertIn("let resolved = CefWindowOpenPolicy.resolve(action, for: request)", swift)
        self.assertIn("guard resolved == .allowNativePopup", swift)
        self.assertIn("sourceExtensionID: identifier", swift)

    def test_separate_provisional_history_does_not_grant_core_source_authority(self):
        owner = (ROOT / "native_history_owner.cc.in").read_text()
        original = owner.split("bool NativeHistoryOwner::RegisterProvisionalPopup", 1)[1].split("bool NativeHistoryOwner::IsLivePublic", 1)[0]
        self.assertIn("origin->HasRegisteredAuthority()", original)
        extension = owner.split("bool NativeHistoryOwner::RegisterProvisionalExtensionPopup", 1)[1].split("bool NativeHistoryOwner::HasRegisteredAuthority", 1)[0]
        self.assertIn("source->GetWeakDocumentPtr()", extension)
        self.assertIn("value->provisional_ = true", extension)
        self.assertNotIn("registered_ = true", extension)
        self.assertNotIn("published_ = true", extension)

    def test_actual_native_owner_and_child_transfer(self):
        native = self.output["cef/libcef/browser/devtools/zacro_extension_host_navigation.cc"]
        resolve = "std::optional<ZacroExtensionHostOwner> ResolveHostOwner" + native.split("std::optional<ZacroExtensionHostOwner> ResolveHostOwner", 1)[1].split('NO_SANITIZE("cfi-icall") void AbortNativeHostPopup', 1)[0]
        transfer = "bool CefBrowserInfoManager::AddNativeExtensionHostContents" + native.split("bool CefBrowserInfoManager::AddNativeExtensionHostContents", 1)[1].split("bool CefBrowserInfoManager::OpenNativeExtensionHostURL", 1)[0]
        prelude = r'''
#include <cassert>
#include <cstdio>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#define CEF_REQUIRE_UIT() do {} while(false)
namespace content {
struct BrowserContext { bool managed=true; };
struct RenderFrameHost;
struct WebContents {
  BrowserContext* context;
  std::string post="retained POST",opener="actual extension RFH";
  static int destroyed;
  explicit WebContents(BrowserContext* ctx):context(ctx){}
  ~WebContents(){++destroyed;}
  BrowserContext* GetBrowserContext(){return context;}
  static WebContents* FromRenderFrameHost(RenderFrameHost* frame);
};
int WebContents::destroyed=0;
struct RenderFrameHost { WebContents* source;bool live=true;bool IsRenderFrameLive(){return live;}
  BrowserContext* GetBrowserContext(){return source->GetBrowserContext();} };
WebContents* WebContents::FromRenderFrameHost(RenderFrameHost* frame){return frame?frame->source:nullptr;}
}
// Extracted authority/transfer methods call a logging-only boundary. The real
// diagnostic helper is exercised by the actual pinned Chromium compilation.
void TraceNativeHost(const char*,content::RenderFrameHost* = nullptr,int = -1,
                     int = 0,int = 0,int = -1,int = -1) {}
struct CefBrowserHostBase {
  content::WebContents* source=nullptr;int id=1;bool alloy=false,valid=true;
  bool IsAlloyStyle(){return alloy;}bool IsValid(){return valid;}
  content::WebContents* GetWebContents(){return source;}int GetIdentifier(){return id;}
};
struct ZacroExtensionHostOwner { std::shared_ptr<CefBrowserHostBase> browser;int logical_window_id=1;std::string extension_id=std::string(32,'a'); };
struct Resolver {
  std::optional<ZacroExtensionHostOwner> owner;
  explicit operator bool()const{return true;}
  std::optional<ZacroExtensionHostOwner> Run(content::RenderFrameHost*){return owner;}
};
Resolver resolver;
Resolver& HostOwnerResolver(){return resolver;}
bool ManagedContext(content::BrowserContext* ctx){return ctx&&ctx->managed;}
namespace extensions { struct ExtensionHost { content::WebContents* source;content::WebContents* host_contents(){return source;} }; }
struct ChromeBrowserHostImpl {
  static std::map<content::WebContents*,std::shared_ptr<ChromeBrowserHostImpl>> hosts;
  std::unique_ptr<content::WebContents> accepted;
  static auto GetBrowserForContents(content::WebContents* contents){
    const auto found=hosts.find(contents);return found==hosts.end()?std::shared_ptr<ChromeBrowserHostImpl>():found->second;}
  void AddNewContents(std::unique_ptr<content::WebContents> contents,std::nullopt_t){accepted=std::move(contents);}
};
std::map<content::WebContents*,std::shared_ptr<ChromeBrowserHostImpl>> ChromeBrowserHostImpl::hosts;
struct CefBrowserInfoManager {
  struct PendingPopup {
    enum Step { WEB_CONTENTS_CREATED,CREATION_COMPLETE } step=WEB_CONTENTS_CREATED;
    struct Document { content::RenderFrameHost* frame;content::RenderFrameHost* AsRenderFrameHostIfValid(){return frame&&frame->live?frame:nullptr;} } native_host_document;
    int native_host_owner_browser=1,native_host_owner_window=1;
    std::string native_host_extension=std::string(32,'a');
    content::WebContents* created;
    static int aborted;
    ~PendingPopup(){if(step!=CREATION_COMPLETE)++aborted;}
  };
  std::unique_ptr<PendingPopup> pending;
  auto PopPendingPopup(PendingPopup::Step,PendingPopup::Step,content::WebContents* contents){
    return pending&&pending->created==contents?std::move(pending):std::unique_ptr<PendingPopup>();}
  bool AddNativeExtensionHostContents(extensions::ExtensionHost*,content::WebContents*,std::unique_ptr<content::WebContents>&);
};
int CefBrowserInfoManager::PendingPopup::aborted=0;
'''
        cases = r'''
int main(){
  int checks=0;auto require=[&](bool value){assert(value);++checks;};
  content::BrowserContext a,b;
  content::WebContents source(&a),foreign(&b);
  content::RenderFrameHost frame{&source};
  auto browser=std::make_shared<CefBrowserHostBase>();browser->source=&source;
  resolver.owner=ZacroExtensionHostOwner{browser,1,std::string(32,'a')};
  require(ResolveHostOwner(&frame).has_value());
  frame.live=false;require(!ResolveHostOwner(&frame));frame.live=true;
  browser->valid=false;require(!ResolveHostOwner(&frame));browser->valid=true;
  browser->alloy=true;require(!ResolveHostOwner(&frame));browser->alloy=false;
  browser->source=&foreign;require(!ResolveHostOwner(&frame));browser->source=&source;
  resolver.owner->logical_window_id=0;require(!ResolveHostOwner(&frame));resolver.owner->logical_window_id=1;
  resolver.owner->extension_id="invalid";require(!ResolveHostOwner(&frame));resolver.owner->extension_id=std::string(32,'a');
  CefBrowserInfoManager manager;extensions::ExtensionHost host{&source};
  auto create=[&](content::BrowserContext* ctx){
    auto child=std::make_unique<content::WebContents>(ctx);
    manager.pending=std::make_unique<CefBrowserInfoManager::PendingPopup>();
    manager.pending->created=child.get();manager.pending->native_host_document.frame=&frame;
    ChromeBrowserHostImpl::hosts[child.get()]=std::make_shared<ChromeBrowserHostImpl>();return child;};
  auto child=create(&a);auto* original=child.get();auto adopted=ChromeBrowserHostImpl::hosts[original];
  require(manager.AddNativeExtensionHostContents(&host,&source,child));
  require(!child&&adopted->accepted.get()==original);
  require(adopted->accepted->post=="retained POST"&&adopted->accepted->opener=="actual extension RFH");
  require(CefBrowserInfoManager::PendingPopup::aborted==0);
  child=create(&a);int before=content::WebContents::destroyed;resolver.owner->logical_window_id=2;
  require(manager.AddNativeExtensionHostContents(&host,&source,child));
  require(!child&&content::WebContents::destroyed==before+1);resolver.owner->logical_window_id=1;
  child=create(&b);before=content::WebContents::destroyed;
  require(manager.AddNativeExtensionHostContents(&host,&source,child));
  require(!child&&content::WebContents::destroyed==before+1);
  child=create(&a);before=content::WebContents::destroyed;frame.live=false;
  require(manager.AddNativeExtensionHostContents(&host,&source,child));
  require(!child&&content::WebContents::destroyed==before+1);frame.live=true;
  child=create(&a);before=content::WebContents::destroyed;host.source=&foreign;
  require(manager.AddNativeExtensionHostContents(&host,&source,child));
  require(!child&&content::WebContents::destroyed==before+1);host.source=&source;
  child=create(&a);a.managed=false;
  require(!manager.AddNativeExtensionHostContents(&host,&source,child));require(bool(child));a.managed=true;
  child.reset();manager.pending.reset();
  require(CefBrowserInfoManager::PendingPopup::aborted==5);
  require(manager.AddNativeExtensionHostContents(&host,&source,child));
  std::printf("{\"checks\":%d}\n",checks);
}
'''
        with tempfile.TemporaryDirectory(prefix="zacro-extension-host-") as temp:
            source = Path(temp) / "transfer.cc"; binary = Path(temp) / "transfer"
            source.write_text(prelude + resolve + transfer + cases)
            subprocess.run(["xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined", str(source), "-o", str(binary)], check=True)
            value = json.loads(subprocess.check_output([str(binary)], text=True))
            self.assertEqual(value["checks"], 23)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], *rest])
