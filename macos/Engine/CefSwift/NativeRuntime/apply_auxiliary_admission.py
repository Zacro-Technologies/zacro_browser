#!/usr/bin/env python3
"""Fence native auth admission before shutdown and exact-profile maintenance."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
PIN = 'd0c02bfad08ec92a6ffcf989e53cd995e6381a4c'
CEF_PIN = '4fa4ab516dacf6c49fc7e6e70d2b7ebce29fa35f'
FLOW_H = 'chrome/browser/extensions/api/identity/web_auth_flow.h'
FLOW_CC = 'chrome/browser/extensions/api/identity/web_auth_flow.cc'
CONTEXT_H = 'cef/libcef/browser/request_context_impl.h'
CONTEXT_CC = 'cef/libcef/browser/request_context_impl.cc'
SEARCH_CC = 'chrome/browser/extensions/api/search/search_api.cc'
RUNTIME_CC = 'chrome/browser/extensions/api/runtime/chrome_runtime_api_delegate.cc'
RUNTIME_H = 'chrome/browser/extensions/api/runtime/chrome_runtime_api_delegate.h'
PATHS = (FLOW_H, FLOW_CC, CONTEXT_H, CONTEXT_CC, SEARCH_CC, RUNTIME_CC, RUNTIME_H)

def replace(text, old, new):
    if text.count(old) != 1: raise ValueError('Pinned auxiliary admission anchor drift: '+old[:100])
    return text.replace(old,new)

def generated(originals):
    out=dict(originals)
    declaration=(ROOT/'native_web_auth_admission.h.in').read_text().split('namespace extensions {\n',1)[1].split('}  // namespace extensions',1)[0]
    h=replace(out[FLOW_H], '#include <optional>', '#include <optional>\n#include <cstdint>\n#include <memory>')
    h=replace(h, '#include "base/time/time.h"', '#include "base/time/time.h"\n#include "base/unguessable_token.h"')
    h=replace(h, 'class WebAuthFlowInfoBarDelegate;', declaration+'\nclass WebAuthFlowInfoBarDelegate;')
    h=replace(h, '  void MaybeStartTimeout();', '''  // Cancels only requests which have never been presented. Shown auth pages
  // retain the ordinary native beforeunload path and its original delegate.
  void CancelUnpresentedForNativeAdmission();
  void MaybeStartTimeout();''')
    h=replace(h, '  raw_ptr<Delegate> delegate_ = nullptr;', '''  // Declared first so registration dies LAST, after owned WebContents and
  // all callbacks/observers. Its destructor posts actual quiescence afterward.
  std::unique_ptr<NativeWebAuthFlowRegistration> native_admission_registration_;
  bool native_admission_cancelled_ = false;
  raw_ptr<Delegate> delegate_ = nullptr;''')
    h=replace(h, '''  base::OnceClosure popup_displayed_callback_for_testing_;
  base::WeakPtrFactory<WebAuthFlow> weak_factory_{this};
#endif''','''  base::OnceClosure popup_displayed_callback_for_testing_;
#endif
  base::WeakPtrFactory<WebAuthFlow> weak_factory_{this};''')
    out[FLOW_H]=h
    c=replace(out[FLOW_CC], '#include <memory>', '#include <memory>\n#include <map>')
    c=replace(c, '#include "base/check.h"', '#include "base/check.h"\n#include "base/no_destructor.h"')
    c=replace(c, '#include "content/public/browser/browser_context.h"',
        '#include "content/public/browser/browser_context.h"\n#include "content/public/browser/browser_thread.h"')
    c=replace(c, 'namespace extensions {\n', 'namespace extensions {\n\n'+(ROOT/'native_web_auth_admission.inc').read_text()+'\n')
    c=replace(c, '''    profile_observation_.Observe(profile_);
  }
}''','''    const bool native_profile_closing = profile_->ShutdownStarted();
    if (!native_profile_closing) profile_observation_.Observe(profile_);
    native_admission_registration_ = RegisterNativeWebAuthFlow(
        profile_, base::BindRepeating(&WebAuthFlow::CancelUnpresentedForNativeAdmission,
                                    weak_factory_.GetWeakPtr()),
        base::BindRepeating([](base::WeakPtr<WebAuthFlow> flow) {
          return flow && !flow->web_contents_ && flow->web_contents();
        }, weak_factory_.GetWeakPtr()));
    // A request rejected during profile teardown must not retain a raw Profile
    // or install an observer after its destruction notification has begun.
    if (native_profile_closing) profile_ = nullptr;
  }
}''')
    c=replace(c, '''  DCHECK(profile_);
  DCHECK(!profile_->IsOffTheRecord());
  DCHECK(!profile_->ShutdownStarted());

  content::WebContents::CreateParams params(profile_);''','''  if (!native_admission_registration_ || !native_admission_registration_->is_admitted() || !profile_ ||
      IsNativeWebAuthAdmissionBlocked(profile_)) {
    // Run() owns an extra ref and still needs to return RespondLater. Use the
    // normal async failure path; do not create a provider WebContents first.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&WebAuthFlow::CancelUnpresentedForNativeAdmission,
                                 weak_factory_.GetWeakPtr()));
    return;
  }
  DCHECK(profile_);
  DCHECK(!profile_->IsOffTheRecord());
  DCHECK(!profile_->ShutdownStarted());

  content::WebContents::CreateParams params(profile_);''')
    c=replace(c, 'void WebAuthFlow::DetachDelegateAndDelete() {', '''void WebAuthFlow::CancelUnpresentedForNativeAdmission() {
  if (native_admission_cancelled_ || !delegate_ || (!web_contents_ && web_contents())) return;
  native_admission_cancelled_ = true;
  non_interactive_timeout_timer_->Stop();
  // May detach the delegate and schedule this object's destruction. Nothing
  // below this call may touch the flow or attempt a second response.
  delegate_->OnAuthFlowFailure(WebAuthFlow::WINDOW_CLOSED);
}

void WebAuthFlow::DetachDelegateAndDelete() {''')
    c=replace(c, '''bool WebAuthFlow::DisplayAuthPageInPopupWindow() {
  if (GetBrowserWindowCreationStatusForProfile(*profile_) !=''','''bool WebAuthFlow::DisplayAuthPageInPopupWindow() {
  if (native_admission_cancelled_ || IsNativeWebAuthAdmissionBlocked(profile_)) return false;
  if (GetBrowserWindowCreationStatusForProfile(*profile_) !=''')
    out[FLOW_CC]=c
    out[CONTEXT_H]=replace(out[CONTEXT_H], '  bool VerifyBrowserContext() const;', '''  bool VerifyBrowserContext() const;

  // Trusted private embedding ABI: never creates/initializes a context and
  // returns null instead of triggering VerifyBrowserContext's DCHECK.
  content::BrowserContext* GetInitializedBrowserContextForNativeAdmission();''')
    c=replace(out[CONTEXT_CC], '#include "cef/libcef/browser/request_context_impl.h"',
        '#include "cef/libcef/browser/request_context_impl.h"\n#include "cef/libcef_dll/cpptoc/request_context_cpptoc.h"\n#include "chrome/browser/extensions/api/identity/web_auth_flow.h"')
    c=replace(c, 'bool CefRequestContextImpl::VerifyBrowserContext() const {', '''content::BrowserContext* CefRequestContextImpl::GetInitializedBrowserContextForNativeAdmission() {
  if (!CEF_CURRENTLY_ON_UIT()) return nullptr;
  auto* existing = browser_context();
  return existing && existing->IsInitialized() ? existing->AsBrowserContext() : nullptr;
}

bool CefRequestContextImpl::VerifyBrowserContext() const {''')
    out[CONTEXT_CC]=c+'\n'+(ROOT/'native_auxiliary_export.inc').read_text()
    # On macOS NavigateImpl creates the Browser synchronously; Navigate's
    # posted callback only reports completion. Check on this same UI sequence
    # before either search target resolution or optional uninstall navigation.
    # Both existing GN targets already depend on //chrome/browser/extensions.
    c=replace(out[SEARCH_CC], '#include "chrome/browser/extensions/extension_tab_util.h"',
        '#include "chrome/browser/extensions/extension_tab_util.h"\n#include "chrome/browser/extensions/api/identity/web_auth_flow.h"')
    c=replace(c, '''  Profile* profile = Profile::FromBrowserContext(browser_context());

  // We need to find which tab to navigate''', '''  Profile* profile = Profile::FromBrowserContext(browser_context());
  if (IsNativeWebAuthAdmissionBlocked(profile)) {
    return RespondNow(Error("The browser context is closing."));
  }

  // We need to find which tab to navigate''')
    out[SEARCH_CC]=c
    h=replace(out[RUNTIME_H], '  // Sets a custom TickClock to use in tests.', '''  // Private embedding producer, called after uninstall has already completed.
  // This does not impersonate or revive the removed extension's API authority.
  using NativeUninstallURLHandler =
      base::RepeatingCallback<void(content::BrowserContext*, const GURL&)>;
  static void SetNativeUninstallURLHandler(NativeUninstallURLHandler handler);

  // Sets a custom TickClock to use in tests.''')
    h=replace(h, '#include "base/memory/raw_ptr.h"', '#include "base/memory/raw_ptr.h"\n#include "base/functional/callback.h"')
    out[RUNTIME_H]=h
    c=replace(out[RUNTIME_CC], '#include "chrome/browser/extensions/browser_window_util.h"',
        '#include "chrome/browser/extensions/browser_window_util.h"\n#include "chrome/browser/extensions/api/identity/web_auth_flow.h"')
    c=replace(c, '#include "base/notimplemented.h"', '#include "base/notimplemented.h"\n#include "base/no_destructor.h"\n#include "content/public/browser/browser_thread.h"')
    c=replace(c, 'namespace {\n', '''namespace {
ChromeRuntimeAPIDelegate::NativeUninstallURLHandler& NativeUninstallURLHandlerStorage() {
  static base::NoDestructor<ChromeRuntimeAPIDelegate::NativeUninstallURLHandler> handler;
  return *handler;
}
''')
    c=replace(c, 'void ChromeRuntimeAPIDelegate::OpenURL(const GURL& uninstall_url) {', '''void ChromeRuntimeAPIDelegate::SetNativeUninstallURLHandler(
    NativeUninstallURLHandler handler) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  NativeUninstallURLHandlerStorage() = std::move(handler);
}

void ChromeRuntimeAPIDelegate::OpenURL(const GURL& uninstall_url) {''')
    c=replace(c, '''void ChromeRuntimeAPIDelegate::OpenURL(const GURL& uninstall_url) {
  Profile* profile = Profile::FromBrowserContext(browser_context_);

  NavigateParams params''', '''void ChromeRuntimeAPIDelegate::OpenURL(const GURL& uninstall_url) {
  Profile* profile = Profile::FromBrowserContext(browser_context_);
  // This is a post-uninstall optional navigation, not a pending extension API
  // invocation. Preserve the completed uninstall result without opening a new
  // Browser during profile retirement or application shutdown.
  if (extensions::IsNativeWebAuthAdmissionBlocked(profile)) return;
  if (auto& handler = NativeUninstallURLHandlerStorage(); handler) {
    handler.Run(browser_context_, uninstall_url);
    return;
  }

  NavigateParams params''')
    out[RUNTIME_CC]=c
    return out

def digest(value):return hashlib.sha256(value.encode()).hexdigest()
def source_baselines(source):
    out={}
    for path in PATHS:
        repo=source/'cef' if path.startswith('cef/') else source
        target=path[4:] if path.startswith('cef/') else path
        out[path]=subprocess.check_output(['git','show','HEAD:'+target],cwd=repo,text=True)
    return out
def validate_current(originals,out,current,prior=None):
    prior=prior or {}
    hashes=prior.get('files',{}) if prior.get('revision')==PIN and prior.get('cefRevision')==CEF_PIN else {}
    for path in PATHS:
        if current[path] not in (originals[path],out[path]) and digest(current[path])!=hashes.get(path):
            raise ValueError('Refusing unrelated source edits: '+path)
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--chromium-root',type=Path,required=True)
    p.add_argument('--check',action='store_true');p.add_argument('--emit-patch',action='store_true')
    p.add_argument('--output-tree',type=Path,help='Write only this staged tree, never the live checkout')
    a=p.parse_args();source=a.chromium_root.resolve()
    for root,pin in [(source,PIN),(source/'cef',CEF_PIN)]:
        if subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()!=pin:raise SystemExit('Wrong source pin')
    originals=source_baselines(source);out=generated(originals)
    receipt=source/'out/zacro-auxiliary-admission.json'
    current={f:(source/f).read_text() if (source/f).exists() else '' for f in PATHS}
    validate_current(originals,out,current,json.loads(receipt.read_text()) if receipt.exists() else None)
    patch=''.join(''.join(difflib.unified_diff(originals[f].splitlines(True),out[f].splitlines(True),
        fromfile='a/'+f if originals[f] else '/dev/null',tofile='b/'+f)) for f in PATHS)
    if a.emit_patch or not (a.check or a.output_tree):(ROOT/'native-auxiliary-admission.patch').write_text(patch)
    if a.output_tree:
        for f,value in out.items():
            target=a.output_tree/f;target.parent.mkdir(parents=True,exist_ok=True);target.write_text(value)
    if not (a.check or a.emit_patch or a.output_tree):
        for f,value in out.items():
            target=source/f
            if target.read_text()!=value:
                temporary=target.with_suffix(target.suffix+'.zacro-tmp')
                temporary.write_text(value);temporary.replace(target)
        receipt.parent.mkdir(parents=True,exist_ok=True)
        receipt.write_text(json.dumps({'revision':PIN,'cefRevision':CEF_PIN,
            'files':{f:digest(value) for f,value in out.items()}},indent=2)+'\n')
    print('Validated native auxiliary admission' if a.check or a.emit_patch or a.output_tree
          else 'Applied native auxiliary admission')
if __name__=='__main__':main()
