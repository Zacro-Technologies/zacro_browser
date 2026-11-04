#!/usr/bin/env python3
import argparse
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('admission',ROOT/'apply_auxiliary_admission.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--chromium-root', type=Path, required=True)
arguments, remaining = parser.parse_known_args()
SOURCE = arguments.chromium_root.resolve()

class AdmissionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.original=m.source_baselines(SOURCE);cls.out=m.generated(cls.original)
    def test_exact_anchors_and_current_pinned_source(self):
        receipt=SOURCE/'out/zacro-auxiliary-admission.json'
        m.validate_current(self.original,self.out,{p:(SOURCE/p).read_text() for p in m.PATHS},
                           json.loads(receipt.read_text()) if receipt.exists() else None)
        for p in m.PATHS:self.assertNotEqual(self.original[p],self.out[p])
    def test_unknown_source_and_wrong_receipt_fail_closed(self):
        changed=dict(self.out);changed[m.FLOW_H]+='// foreign edit\n'
        with self.assertRaises(ValueError):m.validate_current(self.original,self.out,changed)
        prior={'revision':'wrong','cefRevision':m.CEF_PIN,'files':{p:m.digest(s) for p,s in changed.items()}}
        with self.assertRaises(ValueError):m.validate_current(self.original,self.out,changed,prior)
    def test_exact_previous_generation_upgrade(self):
        changed=dict(self.out);changed[m.FLOW_H]+='// previous generated version\n'
        prior={'revision':m.PIN,'cefRevision':m.CEF_PIN,'files':{p:m.digest(s) for p,s in changed.items()}}
        m.validate_current(self.original,self.out,changed,prior)
    def test_start_blocks_before_any_provider_contents(self):
        body=self.out[m.FLOW_CC].split('void WebAuthFlow::Start()',1)[1].split('void WebAuthFlow::CancelUnpresented',1)[0]
        self.assertLess(body.index('IsNativeWebAuthAdmissionBlocked'),body.index('WebContents::Create(params)'))
        self.assertLess(body.index('IsNativeWebAuthAdmissionBlocked'),body.index('DCHECK(!profile_->ShutdownStarted())'))
        self.assertIn('PostTask',body)
        popup=self.out[m.FLOW_CC].split('bool WebAuthFlow::DisplayAuthPageInPopupWindow()',1)[1]
        self.assertLess(popup.index('IsNativeWebAuthAdmissionBlocked'),popup.index('CreateBrowserWindow'))
    def test_registration_outlives_owned_contents_and_posts_final_drain(self):
        h=self.out[m.FLOW_H]
        self.assertLess(h.index('native_admission_registration_;'),h.index('web_contents_;'))
        registry=(ROOT/'native_web_auth_admission.inc').read_text()
        destructor=registry.split('NativeWebAuthFlowRegistration::~',1)[1].split('RegisterNativeWebAuthFlow(',1)[0]
        self.assertIn('PostTask',destructor)
        self.assertIn('ForgetNativeAuthRequest',destructor)
    def test_rejected_teardown_flow_is_counted_without_a_late_profile_observer(self):
        body=self.out[m.FLOW_CC].split('WebAuthFlow::WebAuthFlow(',1)[1].split('WebAuthFlow::~WebAuthFlow()',1)[0]
        self.assertIn('if (!native_profile_closing) profile_observation_.Observe(profile_);',body)
        self.assertLess(body.index('RegisterNativeWebAuthFlow('),body.index('if (native_profile_closing) profile_ = nullptr;'))
        registry=(ROOT/'native_web_auth_admission.inc').read_text()
        register=registry.split('RegisterNativeWebAuthFlow(',1)[1].split('bool IsNativeWebAuthAdmissionBlocked(',1)[0]
        self.assertNotIn('IsNativeWebAuthAdmissionBlocked',register)
        self.assertNotIn('ShutdownStarted()) return nullptr',register)
        self.assertIn('state.overflow_requests',register)
    def test_shown_flow_never_forcibly_completed(self):
        body=self.out[m.FLOW_CC].split('void WebAuthFlow::CancelUnpresentedForNativeAdmission()',1)[1].split('void WebAuthFlow::DetachDelegateAndDelete()',1)[0]
        self.assertIn('(!web_contents_ && web_contents())',body)
        self.assertEqual(body.count('delegate_->OnAuthFlowFailure'),1)
        self.assertNotIn('Close()',body)
    def test_native_interface_uses_existing_identity(self):
        export=(ROOT/'native_auxiliary_export.inc').read_text()
        self.assertIn('CefRequestContextCppToC_Unwrap(raw)',export)
        self.assertIn('raw->base.base.add_ref(&raw->base.base)',export)
        self.assertIn('GetInitializedBrowserContextForNativeAdmission',export)
        self.assertNotIn('GetOrCreate',export)
        self.assertNotIn('GetGlobal',export)
    def test_search_rejects_through_original_response_before_navigation(self):
        body=self.out[m.SEARCH_CC].split('SearchQueryFunction::Run()',1)[1]
        gate=body.index('IsNativeWebAuthAdmissionBlocked(profile)')
        self.assertLess(gate,body.index('ExtensionTabUtil::GetTabById'))
        self.assertLess(gate,body.index('ExtensionTabUtil::NavigateToURL'))
        self.assertIn('RespondNow(Error("The browser context is closing."))',body)
        # macOS creation is synchronous. Its posted callback cannot become a
        # delayed Browser producer after the admission check has returned.
        navigator=(SOURCE/'chrome/browser/ui/navigator/browser_navigator.cc').read_text()
        body=navigator.split('void Navigate(NavigateParams* params,',1)[1]
        self.assertLess(body.index('Navigate(params);'),body.index('PostTask('))
    def test_optional_uninstall_navigation_has_no_fabricated_api_response(self):
        body=self.out[m.RUNTIME_CC].split('ChromeRuntimeAPIDelegate::OpenURL(',1)[1].split('// Helper function',1)[0]
        self.assertLess(body.index('IsNativeWebAuthAdmissionBlocked'),body.index('NavigateParams params'))
        self.assertIn('if (extensions::IsNativeWebAuthAdmissionBlocked(profile)) return;',body)
        self.assertNotIn('Respond',body)
        self.assertNotIn('UninstallExtension',body)
    def test_compile_actual_registry(self):
        if os.environ.get('ZACRO_SKIP_NATIVE_FIXTURE')=='1':self.skipTest('Compiler intentionally withheld during integrated app validation')
        header=(ROOT/'native_web_auth_admission.h.in').read_text().split('namespace extensions {\n',1)[1].split('}  // namespace extensions',1)[0]
        code=(ROOT/'auxiliary_admission_fixture_prelude.inc').read_text()+'\nnamespace extensions {\n'+header+'\n'+(ROOT/'native_web_auth_admission.inc').read_text()+'\n}\n'+(ROOT/'auxiliary_admission_fixture_main.inc').read_text()
        with tempfile.TemporaryDirectory(prefix='zacro-auth-admission-') as tmp:
            source=Path(tmp)/'fixture.cc';binary=Path(tmp)/'fixture';source.write_text(code)
            subprocess.run(['xcrun','clang++','-std=c++20','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',str(source),'-o',str(binary)],check=True)
            result=json.loads(subprocess.check_output([str(binary)],text=True));self.assertEqual(result['checks'],298)
if __name__=='__main__':unittest.main(argv=[sys.argv[0], *remaining])
