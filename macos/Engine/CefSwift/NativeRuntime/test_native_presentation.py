#!/usr/bin/env python3
"""Pinned presentation guards; actual popup/panel behavior requires runtime tests."""
import argparse
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DELEGATE = 'chrome/browser/ui/views/extensions/extension_action_delegate_desktop.cc'
VIEWS = 'chrome/browser/ui/views/side_panel/side_panel_coordinator.cc'


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


POPUP = module('apply_popup_anchor')
PANEL = module('apply_sidepanel_adapter')


class PresentationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.panel=PANEL.generated(PANEL.source_baselines(SOURCE))
        cls.popup=POPUP.generated({p: '' if p in (POPUP.HEADER,POPUP.SOURCE) else
            subprocess.check_output(['git','show','HEAD:'+p],cwd=SOURCE,text=True) for p in POPUP.PATHS})
    def test_generated_output_matches_current_pinned_source(self):
        for path,contents in {**self.panel,**self.popup}.items():
            self.assertEqual((SOURCE/path).read_text(),contents,path)
    def test_proven_nullable_container_requires_real_active_tab_fallback(self):
        container=(SOURCE/'chrome/browser/ui/extensions/extensions_container.cc').read_text()
        self.assertIn('ExtensionsContainer::GetActiveWebContents() const {\n  return nullptr;',container)
        body=self.popup[DELEGATE].split('void ExtensionActionDelegateDesktop::DoTriggerPopup(',1)[1].split('void ExtensionActionDelegateDesktop::ShowPopup(',1)[0]
        self.assertLess(body.index('browser_->GetTabStripModel()->GetActiveWebContents()'),body.index('HasPrepared(anchor_contents)'))
        self.assertLess(body.index('ShowPopup(std::move(host)'),body.index('PopOutAction('))
    def test_one_use_anchor_lifetime_not_extended(self):
        staged=ROOT
        text=(staged/'devtools_topology_adapter.inc').read_text()
        self.assertIn('function->Run().Execute();\n          if (request->action_popup_window && contents) NativeExtensionPopupAnchor::CancelPrepared(contents.get());',text)
        self.assertIn('contents->RemoveUserData(kPendingAnchor);',(staged/'native_popup_anchor_mac.mm.in').read_text())
    def test_activation_observer_matches_upstream_pre_show_guard(self):
        text=(ROOT/'native_popup_anchor_mac.mm.in').read_text()
        self.assertIn('state && state->popup.visible && !Descendant(event.object, state->popup)',text)
        upstream=(SOURCE/'chrome/browser/ui/views/extensions/extension_popup.cc').read_text()
        body=upstream.split('void ExtensionPopup::OnWidgetTreeActivated(',1)[1].split('\n}',1)[0]
        self.assertIn('IsVisible()',body)
    def test_panel_policy_checks_actual_profile_document_and_installation(self):
        text=(ROOT/'devtools_topology_adapter.inc').read_text()
        body=text.split('SidePanelUI::SetNativeHostedPanelPolicy(',1)[1].split('extensions::RuntimeGetContextsFunction',1)[0]
        for phrase in ('IsOffTheRecord()', 'Find(context)', 'enabled_extensions().GetByID',
                       'contents->GetBrowserContext() != context', 'tab->web_contents() == contents',
                       '!tab->closing && !tab->discarded', 'parked.get() == contents', 'contents->IsBeingDestroyed()'):
            self.assertIn(phrase,body)
        self.assertNotIn('state = Get(context)',body)
    def test_generators_check_without_source_mutation(self):
        before={p:(SOURCE/p).read_bytes() for p in set(POPUP.PATHS)|set(PANEL.PATHS)}
        for name in ('apply_popup_anchor.py','apply_sidepanel_adapter.py'):
            subprocess.run([sys.executable, '-B', str(ROOT / name), '--chromium-root',
                            str(SOURCE), '--check'], check=True)
        self.assertEqual(before,{p:(SOURCE/p).read_bytes() for p in before})
    def test_compiled_actual_generated_guards(self):
        if os.environ.get('ZACRO_SKIP_NATIVE_FIXTURE')=='1':self.skipTest('Compiler baton held by integrated build')
        delegate=self.popup[DELEGATE].split('void ExtensionActionDelegateDesktop::DoTriggerPopup(',1)[1]
        popup=delegate.split('#if BUILDFLAG(IS_MAC)\n',1)[1].split('#endif',1)[0]
        panel=self.panel[VIEWS].split('void SidePanelCoordinator::Show(\n    const UniqueKey& input,',1)[1]
        panel=panel.split('  // Ordinary Chrome popups',1)[1].split('  SidePanelEntry* entry',1)[0]
        panel='  // Ordinary Chrome popups'+panel
        prelude='''#include <cassert>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#define BUILDFLAG(x) 1
struct Contents { bool prepared = false; };
struct Strip { Contents* active = nullptr; Contents* GetActiveWebContents() { return active; } };
struct Delegate { bool hosted = false; bool IsViewsHosted() { return hosted; } };
struct BrowserWindowInterface { enum class Type { TYPE_NORMAL, TYPE_POPUP }; };
struct Browser { Strip strip; Delegate* delegate=nullptr; BrowserWindowInterface::Type type=BrowserWindowInterface::Type::TYPE_POPUP;
  Strip* GetTabStripModel(){return &strip;} Delegate* cef_delegate(){return delegate;} auto GetType(){return type;} };
struct NativeExtensionPopupAnchor { static bool HasPrepared(Contents* c){return c&&c->prepared;} };
struct PopupTest { Browser* browser_; Contents* overridden=nullptr; bool synchronous=false; bool queued=false;
  Contents* GetActiveWebContents(){return overridden;}
  void ShowPopup(std::unique_ptr<int>,int,bool,int){synchronous=true;browser_->strip.active->prepared=false;}
  void Run(){auto host=std::make_unique<int>(1);int show_action=0;bool by_user=false;int callback=0;
'''
        middle='''queued=true;}
};
enum class SidePanelEntryId { kExtension, kBookmarks };
struct Key { SidePanelEntryId kind; std::optional<std::string> extension; auto id() const{return kind;} auto extension_id() const{return extension;} };
struct UniqueKey { Key key; };
namespace cef { Browser* BrowserForBWI(Browser* browser){return browser;} }
struct SidePanelUI { static inline bool permitted=false; static inline int checks=0; static bool IsNativeHostedPanelAllowed(Browser*,const Key&){++checks;return permitted;} };
struct BrowserRef { Browser* ptr;Browser* operator->(){return ptr;}Browser& operator*(){return *ptr;} };
struct PanelTest { BrowserRef browser_;bool shown=false;void Show(const UniqueKey& input){
'''
        main='''shown=true;}};
int main(){int count=0;auto check=[&](bool ok){assert(ok);++count;};
  Contents target{true};Browser browser;browser.strip.active=&target;
  PopupTest ordinary{&browser};ordinary.Run();check(ordinary.synchronous&&!ordinary.queued);check(!target.prepared);
  PopupTest noAnchor{&browser};noAnchor.Run();check(!noAnchor.synchronous&&noAnchor.queued);
  target.prepared=true;PopupTest overridden{&browser,&target};overridden.Run();check(overridden.synchronous&&!overridden.queued);
  browser.strip.active=nullptr;PopupTest absent{&browser};absent.Run();check(!absent.synchronous&&absent.queued);
  Delegate hosted{true};UniqueKey extension{{SidePanelEntryId::kExtension,"extension"}},builtin{{SidePanelEntryId::kBookmarks,std::nullopt}},malformed{{SidePanelEntryId::kExtension,std::nullopt}};
  auto show=[&](UniqueKey key){PanelTest p{{&browser}};p.Show(key);return p.shown;};
  browser.delegate=&hosted;SidePanelUI::permitted=true;check(show(extension));
  SidePanelUI::permitted=false;check(!show(extension));
  SidePanelUI::permitted=true;check(!show(builtin));check(!show(malformed));
  hosted.hosted=false;check(!show(extension));
  browser.delegate=nullptr;check(!show(extension));
  browser.type=BrowserWindowInterface::Type::TYPE_NORMAL;check(show(extension));check(show(builtin));
  browser.type=BrowserWindowInterface::Type::TYPE_POPUP;browser.delegate=&hosted;hosted.hosted=true;
  SidePanelUI::permitted=true;check(show(extension));SidePanelUI::permitted=false;check(!show(extension));
  std::cout<<"{\\"checks\\":"<<count<<"}";}
'''
        code=prelude+popup+middle+panel+main
        with tempfile.TemporaryDirectory(prefix='zacro-popup-panel-') as tmp:
            binary=Path(tmp)/'fixture';source=Path(tmp)/'fixture.cc';source.write_text(code)
            subprocess.run(['xcrun','clang++','-std=c++20','-Wall','-Wextra','-Werror',str(source),'-o',str(binary)],check=True)
            result=json.loads(subprocess.check_output([str(binary)],text=True));self.assertEqual(result['checks'],15)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--chromium-root', required=True, type=Path)
    args, rest = parser.parse_known_args()
    SOURCE = args.chromium_root.resolve()
    if subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=SOURCE,
                               text=True).strip() != POPUP.PIN:
        raise SystemExit('Pinned Chromium sources required')
    unittest.main(argv=[__file__] + rest)
