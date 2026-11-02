#!/usr/bin/env python3
"""Retain a native global extension panel across logical-tab view changes."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
PIN = "d0c02bfad08ec92a6ffcf989e53cd995e6381a4c"
REGISTRY_H = "chrome/browser/ui/side_panel/side_panel_registry.h"
REGISTRY_CC = "chrome/browser/ui/side_panel/side_panel_registry.cc"
UI_H = "chrome/browser/ui/side_panel/side_panel_ui.h"
UI_CC = "chrome/browser/ui/side_panel/side_panel_ui.cc"
VIEWS_H = "chrome/browser/ui/views/side_panel/side_panel_coordinator.h"
VIEWS_CC = "chrome/browser/ui/views/side_panel/side_panel_coordinator.cc"
COORDINATOR_H = "chrome/browser/ui/extensions/extension_side_panel_coordinator.h"
COORDINATOR_CC = "chrome/browser/ui/extensions/extension_side_panel_coordinator.cc"
MANAGER_H = "chrome/browser/ui/extensions/extension_side_panel_manager.h"
MANAGER_CC = "chrome/browser/ui/extensions/extension_side_panel_manager.cc"
HOST_H = "chrome/browser/extensions/extension_view_host.h"
FACTORY_CC = "chrome/browser/extensions/extension_view_host_factory.cc"
BROWSER_H = "chrome/browser/ui/views/frame/browser_view.h"
BROWSER_CC = "chrome/browser/ui/views/frame/browser_view.cc"
SERVICE_H = "chrome/browser/extensions/api/side_panel/side_panel_service.h"
SERVICE_CC = "chrome/browser/extensions/api/side_panel/side_panel_service.cc"
SERVICE_TEST = "chrome/browser/extensions/api/side_panel/side_panel_apitest.cc"
PATHS = (SERVICE_H, SERVICE_CC, SERVICE_TEST, REGISTRY_H, REGISTRY_CC, UI_H, UI_CC, VIEWS_H, VIEWS_CC, COORDINATOR_H,
         COORDINATOR_CC, MANAGER_H, MANAGER_CC, HOST_H, FACTORY_CC, BROWSER_H, BROWSER_CC)


def replace(text, old, new):
    if text.count(old) != 1:
        raise SystemExit(f"Pinned side-panel source drift: {old[:100]!r}")
    return text.replace(old, new)


def generated(originals):
    result = dict(originals)
    result[SERVICE_H] = replace(result[SERVICE_H], "    virtual void OnSidePanelServiceShutdown() = 0;", """    virtual void OnSidePanelServiceShutdown() = 0;
    // Browser UI must track presentation even when the extension has no JS
    // event listener. This callback does not itself dispatch an extension event.
    virtual void OnNativePanelPresentationChanged(const ExtensionId& extension_id,
        int window_id, std::optional<int> tab_id, bool visible) {}
""")
    for event, visible in (("Opened", "true"), ("Closed", "false")):
        signature = f"void SidePanelService::DispatchOn{event}Event"
        begin = result[SERVICE_CC].index(signature)
        position = result[SERVICE_CC].index("  auto* router = EventRouter::Get(browser_context_);", begin)
        result[SERVICE_CC] = (result[SERVICE_CC][:position] +
            f"  for (auto& observer : observers_) {{\n    observer.OnNativePanelPresentationChanged(extension_id, window_id, tab_id, {visible});\n  }}\n" +
            result[SERVICE_CC][position:])
    result[SERVICE_TEST] = replace(result[SERVICE_TEST], '#include "extensions/browser/disable_reason.h"',
        '#include "extensions/browser/disable_reason.h"\n#include "extensions/browser/event_router.h"')
    result[SERVICE_TEST] = replace(result[SERVICE_TEST], "}  // namespace extensions\n",
        (ROOT / "sidepanel_observer_tests.inc").read_text() + "\n}  // namespace extensions\n")
    result[UI_H] = replace(result[UI_H], '#include "chrome/browser/ui/side_panel/side_panel_enums.h"',
        '#include "chrome/browser/ui/side_panel/side_panel_enums.h"\n#include "chrome/browser/ui/side_panel/side_panel_native_view.h"')
    result[UI_H] = replace(result[UI_H], "  // Close the side panel.", """  // Native embedders may host one logical window in several BrowserViews.
  // Detach the current global view without destroying its extension document.
  // Unsupported platforms leave the panel untouched and return null.
  virtual SidePanelNativeView TakeNativeGlobalView(const SidePanelEntryKey& key) {
    return nullptr;
  }
  virtual void SetNativeEmptyContentHidden(bool hidden) {}

  // Close the side panel.""")
    result[UI_H] = replace(result[UI_H], '  static SidePanelUI* From(BrowserWindowInterface* browser);', """  // The embedding registry must authorize the current exact document on each
  // Show. A window kind alone does not confer extension presentation authority.
  using NativeHostedPanelPolicy = base::RepeatingCallback<bool(
      BrowserWindowInterface*, const SidePanelEntryKey&)>;
  static void SetNativeHostedPanelPolicy(NativeHostedPanelPolicy policy);
  static bool IsNativeHostedPanelAllowed(BrowserWindowInterface* browser,
                                       const SidePanelEntryKey& key);

  static SidePanelUI* From(BrowserWindowInterface* browser);""")
    result[UI_CC] = replace(result[UI_CC], '#include "chrome/browser/ui/side_panel/side_panel_ui.h"',
        '#include "chrome/browser/ui/side_panel/side_panel_ui.h"\n#include "base/no_destructor.h"\n#include <utility>')
    result[UI_CC] = replace(result[UI_CC], 'DEFINE_USER_DATA(SidePanelUI);', """DEFINE_USER_DATA(SidePanelUI);

namespace {
SidePanelUI::NativeHostedPanelPolicy& NativePanelPolicy() {
  static base::NoDestructor<SidePanelUI::NativeHostedPanelPolicy> policy;
  return *policy;
}
}  // namespace

void SidePanelUI::SetNativeHostedPanelPolicy(NativeHostedPanelPolicy policy) {
  NativePanelPolicy() = std::move(policy);
}

bool SidePanelUI::IsNativeHostedPanelAllowed(BrowserWindowInterface* browser,
                                           const SidePanelEntryKey& key) {
  return NativePanelPolicy() && NativePanelPolicy().Run(browser, key);
}""")
    result[VIEWS_CC] = replace(result[VIEWS_CC], '#include "base/check.h"',
        '#include "base/check.h"\n#if BUILDFLAG(ENABLE_CEF)\n#include "cef/libcef/browser/chrome/browser_util.h"\n#endif')
    result[VIEWS_CC] = replace(result[VIEWS_CC], """  // Side panel is not supported for non-normal browsers.
  if (browser_->GetType() != BrowserWindowInterface::Type::TYPE_NORMAL) {
    return;
  }""", """  // Ordinary Chrome popups retain their original restriction. Native hosted
  // document views may present only a real extension entry whose current
  // profile/document ownership is approved by the embedding registry.
  bool native_extension_owner = false;
#if BUILDFLAG(ENABLE_CEF)
  if (input.key.id() == SidePanelEntryId::kExtension &&
      input.key.extension_id().has_value()) {
    auto* delegate = cef::BrowserForBWI(&*browser_)->cef_delegate();
    native_extension_owner = delegate && delegate->IsViewsHosted() &&
        SidePanelUI::IsNativeHostedPanelAllowed(&*browser_, input.key);
  }
#endif
  if (browser_->GetType() != BrowserWindowInterface::Type::TYPE_NORMAL &&
      !native_extension_owner) {
    return;
  }""")
    result[VIEWS_H] = replace(result[VIEWS_H], "  // SidePanelUI:\n", """  // SidePanelUI:
  SidePanelNativeView TakeNativeGlobalView(const SidePanelEntryKey& key) override;
  void SetNativeEmptyContentHidden(bool hidden) override;
""")
    result[VIEWS_CC] = replace(result[VIEWS_CC], '#include "chrome/browser/ui/views/side_panel/side_panel_coordinator.h"',
        '#include "chrome/browser/ui/views/side_panel/side_panel_coordinator.h"\n#include "chrome/browser/ui/views/frame/browser_view.h"')
    result[VIEWS_CC] = replace(result[VIEWS_CC], "void SidePanelCoordinator::Close(SidePanelEntryHideReason reason,", """void SidePanelCoordinator::SetNativeEmptyContentHidden(bool hidden) {
  if (auto* view = BrowserView::GetBrowserViewForBrowser(browser())) {
    view->SetNativeEmptyContentHidden(hidden);
  }
}

SidePanelNativeView SidePanelCoordinator::TakeNativeGlobalView(
    const SidePanelEntryKey& key) {
  if (!IsSidePanelEntryShowing(key, /*for_tab=*/false)) return nullptr;
  auto* panel = GetSidePanel();
  panel->ResetSidePanelAnimationContent();
  auto* wrapper = panel->GetContentParentView();
  if (wrapper->children().size() != 1) return nullptr;
  auto view = wrapper->RemoveChildViewT(wrapper->children().front());
  // The detached view continues to own its ExtensionViewHost. Close cannot
  // destroy it or emit an extension onClosed event while it is retained here.
  Close(SidePanelEntryHideReason::kSidePanelClosed, /*suppress_animations=*/true);
  return view;
}

void SidePanelCoordinator::Close(SidePanelEntryHideReason reason,""")
    result[REGISTRY_H] = replace(result[REGISTRY_H], "  bool Deregister(const SidePanelEntry::Key& key);", """  bool Deregister(const SidePanelEntry::Key& key);

  // Takes an inactive entry after its live view has been detached. The caller
  // must immediately register it in another registry in the same profile.
  std::unique_ptr<SidePanelEntry> TakeNativeEntry(const SidePanelEntry::Key& key);""")
    result[REGISTRY_CC] = replace(result[REGISTRY_CC], "void SidePanelRegistry::SetActiveEntry(SidePanelEntry* entry) {", """std::unique_ptr<SidePanelEntry> SidePanelRegistry::TakeNativeEntry(
    const SidePanelEntry::Key& key) {
  auto* entry = GetEntryForKey(key);
  if (!entry || (active_entry_ && *active_entry_ == entry) ||
      deregistering_entry_key_) return nullptr;
  auto it = std::find_if(entries_.begin(), entries_.end(), base::MatchesUniquePtr(entry));
  CHECK(it != entries_.end());
  entry->RemoveObserver(this);
  entry->set_scope(nullptr);
  auto taken = std::move(*it);
  entries_.erase(it);
  return taken;
}

void SidePanelRegistry::SetActiveEntry(SidePanelEntry* entry) {""")
    result[HOST_H] = replace(result[HOST_H], "namespace extensions {", "class BrowserWindowInterface;\n\nnamespace extensions {")
    result[HOST_H] = replace(result[HOST_H], "    virtual ~Delegate();", """    virtual ~Delegate();

    // Only a window-scoped host may move between physical views of the same
    // logical native window. Tab-scoped and unsupported delegates reject it.
    virtual bool RebindNativeBrowser(BrowserWindowInterface* browser) { return false; }""")
    result[HOST_H] = replace(result[HOST_H], "  void set_view(ExtensionView* view) { view_ = view; }", """  bool RebindNativeBrowser(BrowserWindowInterface* browser) {
    return delegate_->RebindNativeBrowser(browser);
  }

  void set_view(ExtensionView* view) { view_ = view; }""")
    result[FACTORY_CC] = replace(result[FACTORY_CC], "  ~ExtensionViewHostBrowserDelegate() override = default;", """  ~ExtensionViewHostBrowserDelegate() override = default;

  bool RebindNativeBrowser(BrowserWindowInterface* browser) override {
    if (!browser || browser->GetProfile() != browser_->GetProfile()) return false;
    browser_ = browser;
    return true;
  }""")
    result[COORDINATOR_H] = replace(result[COORDINATOR_H], "  BrowserWindowInterface* GetBrowser();", """  BrowserWindowInterface* GetBrowser();

  // Keeps the existing extension document, view observer and close callback.
  // Called only while its entry/view are detached between same-profile windows.
  bool RebindNativeBrowser(BrowserWindowInterface* browser, SidePanelRegistry* registry);
  base::WeakPtr<ExtensionSidePanelCoordinator> GetNativeWeakPtr() {
    return weak_factory_.GetWeakPtr();
  }""")
    result[COORDINATOR_CC] = replace(result[COORDINATOR_CC], "void ExtensionSidePanelCoordinator::DeregisterEntry() {", """bool ExtensionSidePanelCoordinator::RebindNativeBrowser(
    BrowserWindowInterface* browser, SidePanelRegistry* registry) {
  if (for_tab_ || !host_ || !browser || !registry ||
      browser->GetProfile() != profile_ || !host_->RebindNativeBrowser(browser)) return false;
  if (delegate_) delegate_->OnEntryDeregistered();
  browser_ = browser;
  registry_ = registry;
  window_id_ = ExtensionTabUtil::GetWindowId(browser);
  if (delegate_) delegate_->OnEntryRegistered();
  return true;
}

void ExtensionSidePanelCoordinator::DeregisterEntry() {""")
    result[MANAGER_H] = replace(result[MANAGER_H], "  void RegisterExtensionEntries();", """  void RegisterExtensionEntries();

  // Moves an already-open global panel, preserving its WebContents. Contextual
  // panels and cross-profile transfers are deliberately not transferred.
  bool TransferNativeGlobalPanel(const ExtensionId& extension_id,
                                ExtensionSidePanelManager* destination);""")
    result[MANAGER_H] = replace(result[MANAGER_H], "      scoped_unowned_user_data_;", """      scoped_unowned_user_data_;
  base::WeakPtrFactory<ExtensionSidePanelManager> native_weak_factory_{this};""")
    result[MANAGER_CC] = replace(result[MANAGER_CC], '#include "chrome/browser/ui/extensions/extension_side_panel_coordinator.h"',
        '#include "chrome/browser/ui/extensions/extension_side_panel_coordinator.h"\n#include "chrome/browser/ui/side_panel/side_panel_registry.h"\n#include "chrome/browser/ui/side_panel/side_panel_ui.h"')
    result[MANAGER_CC] = replace(result[MANAGER_CC], "void ExtensionSidePanelManager::RegisterExtensionEntries() {", """bool ExtensionSidePanelManager::TransferNativeGlobalPanel(
    const ExtensionId& extension_id, ExtensionSidePanelManager* destination) {
  if (!destination || destination == this || for_tab_ || destination->for_tab_ ||
      profile_ != destination->profile_) return false;
  const auto source_manager = native_weak_factory_.GetWeakPtr();
  const auto target_manager = destination->native_weak_factory_.GetWeakPtr();
  auto source = coordinators_.find(extension_id);
  auto target = destination->coordinators_.find(extension_id);
  if (source == coordinators_.end() || !source->second->host() ||
      target == destination->coordinators_.end() || target->second->host()) return false;
  auto* coordinator = source->second.get();
  const auto source_weak = coordinator->GetNativeWeakPtr();
  const auto target_weak = target->second->GetNativeWeakPtr();
  scoped_refptr<const Extension> extension = coordinator->extension();
  const auto key = coordinator->GetEntryKey();
  const auto* original_entry = coordinator->GetEntry();
  auto* source_ui = SidePanelUI::From(browser_);
  auto* target_ui = SidePanelUI::From(destination->browser_);
  if (!source_ui || !target_ui || !coordinator->GetEntry()) return false;
  // Contextual panels retain precedence. The global document can still move
  // into that window's inactive registry cache, so closing its previous host
  // cannot destroy it merely because the selected tab has an override.
  bool show_global = true;
  if (auto* tab = destination->browser_->GetActiveTabInterface()) {
    auto* contextual = SidePanelRegistry::From(tab);
    if (contextual && contextual->GetEntryForKey(key)) show_global = false;
  }
  auto view = source_ui->IsSidePanelEntryShowing(key, /*for_tab=*/false)
      ? source_ui->TakeNativeGlobalView(key) : std::move(coordinator->GetEntry()->CachedView());
  if (!view) return false;
  // Closing the shell invokes arbitrary native entry observers. They may
  // deregister a panel, replace a coordinator or unload the extension. Never
  // reuse a pre-callback iterator or require those objects to survive.
  auto still_current = [&]() {
    if (!source_manager || !target_manager) return false;
    const auto current_source = coordinators_.find(extension_id);
    const auto current_target = destination->coordinators_.find(extension_id);
    return source_weak && target_weak &&
        current_source != coordinators_.end() && current_source->second.get() == source_weak.get() &&
        current_target != destination->coordinators_.end() && current_target->second.get() == target_weak.get() &&
        registry_->GetEntryForKey(key) == original_entry && source_weak->host() && !target_weak->host() &&
        ExtensionRegistry::Get(profile_)->enabled_extensions().GetByID(extension_id) == extension.get();
  };
  if (!still_current()) return false;
  // Remove only the destination's unused coordinator; its original extension
  // content has never been created. No stateful document is overwritten.
  target_weak->DeregisterEntry();
  if (!still_current()) return false;
  destination->coordinators_.erase(extension_id);
  auto entry = registry_->TakeNativeEntry(key);
  if (!entry) return false;
  auto moved = std::move(coordinators_.at(extension_id));
  coordinators_.erase(extension_id);
  // Hold the coordinator ourselves while action-item callbacks run. Registry
  // unload observers cannot delete it while RebindNativeBrowser is executing.
  if (!moved->RebindNativeBrowser(destination->browser_, destination->registry_)) return false;
  if (!source_manager || !target_manager) return false;
  entry->CacheView(std::move(view));
  if (!destination->registry_->Register(std::move(entry))) return false;
  if (!moved->host() || ExtensionRegistry::Get(profile_)->enabled_extensions().GetByID(extension_id) != extension.get()) {
    moved->DeregisterEntry();
    return false;
  }
  destination->coordinators_[extension_id] = std::move(moved);
  if (show_global) target_ui->Show(key, std::nullopt, /*suppress_animations=*/true);
  if (!source_manager || !target_manager) return false;
  // This physical view can still receive future per-profile option changes.
  if (ExtensionRegistry::Get(profile_)->enabled_extensions().GetByID(extension_id) == extension.get())
    MaybeCreateExtensionSidePanelCoordinator(extension.get());
  return source_weak && source_weak->host() &&
      (!show_global || target_ui->IsSidePanelEntryShowing(key, /*for_tab=*/false));
}

void ExtensionSidePanelManager::RegisterExtensionEntries() {""")
    result[BROWSER_H] = replace(result[BROWSER_H], "  views::View* contents_container();", """  views::View* contents_container();

  // A native shell paints its own themed empty canvas. Keep extension UI
  // visible while suppressing only a blank, failed or crashed renderer.
  void SetNativeEmptyContentHidden(bool hidden);""")
    result[BROWSER_H] = replace(result[BROWSER_H], " private:\n", " private:\n  bool native_empty_content_hidden_ = false;\n")
    result[BROWSER_CC] = replace(result[BROWSER_CC], "void BrowserView::FrameColorsChanged() {", """void BrowserView::SetNativeEmptyContentHidden(bool hidden) {
  auto* tab = browser_->GetActiveTabInterface();
  auto* contents = tab ? tab->GetContents() : nullptr;
  auto* entry = contents ? contents->GetController().GetLastCommittedEntry() : nullptr;
  if (hidden && (!contents || (contents->GetLastCommittedURL() != GURL("about:blank") &&
      !contents->IsCrashed() && (!entry || entry->GetPageType() != content::PAGE_TYPE_ERROR)))) hidden = false;
  if (native_empty_content_hidden_ == hidden) return;
  native_empty_content_hidden_ = hidden;
  for (const auto& container : GetContentsContainerViews()) {
    // Opacity retains the content slot's geometry, unlike SetVisible(false),
    // and does not remove the real tab or its extension action permissions.
    if (!container->layer()) container->SetPaintToLayer();
    container->layer()->SetOpacity(hidden ? 0.0f : 1.0f);
    container->SetCanProcessEventsWithinSubtree(!hidden);
  }
  FrameColorsChanged();
}

void BrowserView::FrameColorsChanged() {
  if (native_empty_content_hidden_) {
    GetWidget()->SetBackgroundColor(SK_ColorTRANSPARENT);
    return;
  }""")
    return result


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def source_baselines(source):
    originals = {path: subprocess.check_output(["git", "show", "HEAD:" + path], cwd=source, text=True) for path in PATHS}
    cef = source / "cef"
    if not subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=cef, text=True).startswith("4fa4ab516dac"):
        raise SystemExit("The pinned CEF source revision changed")
    with tempfile.TemporaryDirectory(prefix="zacro-sidepanel-baseline-") as temporary:
        tree = Path(temporary)
        for path, text in originals.items():
            destination = tree / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(text)
        for name in ("chrome_runtime_views", "win_taskbar_decorator_3645"):
            upstream = subprocess.check_output(["git", "show", "HEAD:patch/patches/" + name + ".patch"], cwd=cef, text=True)
            selected = ["diff --git " + section for section in upstream.split("diff --git ")[1:]
                        if section.splitlines()[0].split()[0] in PATHS]
            if selected:
                subprocess.run(["git", "apply", "-p0", "--unsafe-paths", "-"], cwd=tree,
                               input="".join(selected), text=True, check=True)
        return {path: (tree / path).read_text() for path in PATHS}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chromium-root", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    source = args.chromium_root.resolve()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if revision != PIN:
        raise SystemExit(f"Expected pinned Chromium {PIN}, found {revision}")
    originals = source_baselines(source)
    output = generated(originals)
    receipt = source / "out/zacro-sidepanel.json"
    prior = json.loads(receipt.read_text()) if receipt.exists() else {}
    if prior.get("revision") != PIN:
        prior = {}
    for path, contents in output.items():
        current = (source / path).read_text()
        if current not in (originals[path], contents) and digest(current) != prior.get("files", {}).get(path):
            raise SystemExit("Refusing to overwrite unrelated edits: " + path)
    if not args.check:
        patch = "".join("".join(difflib.unified_diff(originals[path].splitlines(True), contents.splitlines(True),
            fromfile="a/" + path, tofile="b/" + path)) for path, contents in output.items())
        (ROOT / "native-sidepanel.patch").write_text(patch)
        for path, contents in output.items():
            if (source / path).read_text() != contents:
                (source / path).write_text(contents)
        receipt.write_text(json.dumps({"revision": PIN, "files": {path: digest(value) for path, value in output.items()}}, indent=2) + "\n")
    print("Checked" if args.check else "Applied", "native retained side-panel adapter")


if __name__ == "__main__":
    main()
