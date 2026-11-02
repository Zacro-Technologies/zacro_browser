#!/usr/bin/env python3
"""Pinned transformation and extracted production consent/cancellation checks.

The standalone fixture executes generated guards with native callback/registry
stand-ins. It does not claim real Views presentation or Chrome API acceptance.
"""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("prompt_adapter", ROOT / "apply_management_prompt_adapter.py")
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


def method(source, first, following):
    return source[source.index(first):source.index(following, source.index(first))]


class ManagementPromptTests(unittest.TestCase):
    def test_reconstructed_cef_base_preserves_known_upstream_edits(self):
        source = self.originals[adapter.CONSTRAINED]
        self.assertIn("parent_widget", source)
        self.assertIn("GetAcceleratedWidget()", source)
        output = adapter.generated(self.originals)[adapter.CONSTRAINED]
        self.assertEqual(output.count("auto* parent_host = parent"), 2)
        self.assertEqual(output.count("? parent_host->GetAcceleratedWidget()"), 2)
        self.assertIn("CreateDialogWidget(\n      dialog, gfx::NativeWindow(), parent_view, parent_widget)", output)

    def test_generation_is_repeatable_and_rejects_source_drift(self):
        output = adapter.generated(self.originals)
        self.assertEqual(output, adapter.generated(self.originals))
        changed = dict(self.originals)
        changed[adapter.INSTALL_CC] = changed[adapter.INSTALL_CC].replace("  done_callback_ = std::move(done_callback);", "// drift")
        with self.assertRaisesRegex(SystemExit, "source drift"):
            adapter.generated(changed)

    def test_only_exact_baseline_current_or_receipted_previous_output_is_allowed(self):
        output = adapter.generated(self.originals)
        adapter.validate_current(self.originals, output, self.originals)
        adapter.validate_current(self.originals, output, output)
        previous = dict(output); previous[adapter.VIEW] += "// previous generated version\n"
        receipt = {"revision":adapter.PIN,"files":{p:adapter.digest(c) for p,c in previous.items()}}
        adapter.validate_current(self.originals,output,previous,receipt)
        previous[adapter.VIEW] += "// unrelated change\n"
        with self.assertRaisesRegex(SystemExit,"unrelated prompt edits"):
            adapter.validate_current(self.originals,output,previous,receipt)

    def test_uninstall_revocation_precedes_mutation_and_late_icon_handoff(self):
        source = adapter.generated(self.originals)[adapter.UNINSTALL_CC]
        closed = method(source,"void ExtensionUninstallDialog::OnDialogClosed(","bool ExtensionUninstallDialog::Uninstall(")
        self.assertLess(closed.index("NativeOperationIsAuthorized()"),closed.index("Uninstall(&error)"))
        self.assertLess(closed.index("native_operation_completed_ = true"),closed.index("HandleReportAbuse()"))
        self.assertLess(closed.index("native_operation_completed_ = true"),closed.index("delegate_->OnExtensionUninstallDialogClosed"))
        icon = method(source,"void ExtensionUninstallDialog::OnIconUpdated(","void ExtensionUninstallDialog::OnExtensionUninstalled(")
        self.assertIn("!icon_ || dialog_shown_ || native_operation_completed_",icon)
        self.assertLess(icon.index("native_dialog_creating_ = true"),icon.index("Show();"))
        self.assertGreater(icon.index("native_dialog_visible_ = true"),icon.index("Show();"))
        authorize = method(source,"bool ExtensionUninstallDialog::NativeOperationIsAuthorized()", "void ExtensionUninstallDialog::CancelNativeOperation()")
        self.assertIn("== extension_.get()", authorize)

    def test_install_covers_non_widget_completion_and_registers_real_cancel_before_show(self):
        output = adapter.generated(self.originals)
        install = output[adapter.INSTALL_CC]
        self.assertLess(install.index("// Also covers theme/autoconfirm"),install.index("extension->is_theme()"))
        self.assertIn("weak_factory_.InvalidateWeakPtrs();",install)
        self.assertIn("if (!weak_this || !weak_this->done_callback_)",install)
        view = method(output[adapter.VIEW],"void ShowExtensionInstallDialogImpl(","}  // namespace")
        self.assertLess(view.index("authorized && !authorized.Run()"),view.index("ActivateContents"))
        self.assertLess(view.index("register_cancellation.Run"),view.index("weak_widget->Show()"))
        self.assertIn("base::WeakPtr<views::Widget>",view)
        self.assertIn("dialog->CancelDialog();",view)
        accept = method(output[adapter.VIEW],"void ExtensionInstallDialogView::OnDialogAccepted()", "bool ExtensionInstallDialogView::IsDialogButtonEnabled(")
        self.assertLess(accept.index("native_operation_authorized.Run()"),accept.index("prompt_->OnDialogAccepted()"))

    def test_extracted_production_lifetime_guards(self):
        if self.source_only:
            self.skipTest("Source-only; run compiled extracted production guards separately.")
        output = adapter.generated(self.originals)
        uninstall = output[adapter.UNINSTALL_CC]
        authorization = method(uninstall,"bool ExtensionUninstallDialog::NativeOperationIsAuthorized()", "void ExtensionUninstallDialog::CancelNativeOperation()")
        cancel = method(uninstall,"void ExtensionUninstallDialog::CancelNativeOperation()", "void ExtensionUninstallDialog::ConfirmUninstallByExtension(")
        closing = method(uninstall,"void ExtensionUninstallDialog::OnDialogClosed(", "  // Ensure the dialog isn't notified")
        completion = method(output[adapter.INSTALL_CC], "      [](base::RepeatingCallback<bool()> authorized", "      }, native_operation_authorized_") + "      }"
        with tempfile.TemporaryDirectory(prefix="zacro-prompt-guards-") as temporary:
            root = Path(temporary); source = root / "guards.cc"; executable = root / "guards"
            source.write_text(PRELUDE + authorization + cancel + closing + CLOSING_TAIL +
                              "\nauto CompleteInstall = " + completion + ";\n" + FIXTURES)
            subprocess.run(["xcrun","clang++","-std=c++20","-O0",str(source),"-o",str(executable)],check=True)
            result = subprocess.check_output([str(executable)],text=True)
            self.assertEqual(result.strip(),"11 extracted production prompt checks passed")


PRELUDE = r'''
#include <functional>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#define DCHECK(value) do { if (!(value)) throw std::runtime_error("DCHECK"); } while (0)
namespace base {
template<typename> struct RepeatingCallback;
template<> struct RepeatingCallback<bool()> {
  std::function<bool()> callback;
  explicit operator bool() const { return bool(callback); }
  bool Run() const { return callback(); }
};
}
struct Profile {};
struct Extension { std::string id() const { return "same-extension-id"; } };
struct ExtensionRegistry {
  enum { EVERYTHING };
  const Extension* installed = nullptr;
  static ExtensionRegistry* Get(Profile*) { static ExtensionRegistry registry; return &registry; }
  const Extension* GetExtensionById(const std::string&, int) { return installed; }
};
struct ExtensionUninstallDialog {
  enum CloseAction { CLOSE_ACTION_UNINSTALL, CLOSE_ACTION_UNINSTALL_AND_CHECKBOX_CHECKED, CLOSE_ACTION_CANCELED };
  struct ThreadChecker { bool CalledOnValidThread() const { return true; } } thread_checker_;
  Profile* profile_ = nullptr;
  std::shared_ptr<Extension> extension_;
  base::RepeatingCallback<bool()> native_operation_authorized_;
  bool native_operation_cancelled_ = false, native_operation_completed_ = false;
  bool native_dialog_creating_ = false, native_dialog_visible_ = false;
  int closed = 0, completions = 0, mutations = 0;
  bool reenter = false;
  bool NativeOperationIsAuthorized() const;
  void CancelNativeOperation();
  void OnDialogClosed(CloseAction action);
  void Close() {
    DCHECK(native_dialog_visible_ && !native_dialog_creating_);
    ++closed; OnDialogClosed(CLOSE_ACTION_CANCELED);
  }
};
enum class Result { ACCEPTED, USER_CANCELED, ABORTED };
struct DoneCallbackPayload {
  const Result result;
  const std::string justification;
  explicit DoneCallbackPayload(Result value, std::string text = {}) : result(value), justification(std::move(text)) {}
};
struct DoneCallback {
  std::function<void(DoneCallbackPayload)> callback;
  void Run(DoneCallbackPayload value) { callback(std::move(value)); }
};
'''
CLOSING_TAIL = '''  ++completions;
  if (action != CLOSE_ACTION_CANCELED) ++mutations;
  if (reenter) CancelNativeOperation();
}
'''
FIXTURES = r'''
int main() {
  int checks = 0;
  auto expect = [&](bool value) { if (!value) throw std::runtime_error("Prompt lifetime invariant"); ++checks; };
  Profile profile;
  auto extension = std::make_shared<Extension>();
  ExtensionRegistry::Get(&profile)->installed = extension.get();
  bool allowed = true;
  auto setup = [&] {
    ExtensionUninstallDialog dialog;
    dialog.profile_ = &profile; dialog.extension_ = extension;
    dialog.native_operation_authorized_.callback = [&] { return allowed; };
    return dialog;
  };
  auto early = setup(); early.reenter = true;
  early.CancelNativeOperation(); early.OnDialogClosed(ExtensionUninstallDialog::CLOSE_ACTION_UNINSTALL);
  expect(early.completions == 1 && early.closed == 0 && early.mutations == 0);
  auto creating = setup(); creating.native_dialog_creating_ = true;
  creating.CancelNativeOperation();
  expect(creating.completions == 0 && creating.closed == 0);
  creating.native_dialog_creating_ = false; creating.native_dialog_visible_ = true;
  creating.CancelNativeOperation();
  expect(creating.closed == 1 && creating.completions == 1 && creating.mutations == 0);
  auto changed = setup(); auto replacement = std::make_shared<Extension>();
  ExtensionRegistry::Get(&profile)->installed = replacement.get();
  changed.OnDialogClosed(ExtensionUninstallDialog::CLOSE_ACTION_UNINSTALL_AND_CHECKBOX_CHECKED);
  expect(changed.mutations == 0 && changed.completions == 1);
  ExtensionRegistry::Get(&profile)->installed = extension.get();
  auto revoked = setup(); allowed = false;
  revoked.OnDialogClosed(ExtensionUninstallDialog::CLOSE_ACTION_UNINSTALL);
  expect(revoked.mutations == 0 && revoked.completions == 1);
  allowed = true; auto accepted = setup(); accepted.reenter = true;
  accepted.OnDialogClosed(ExtensionUninstallDialog::CLOSE_ACTION_UNINSTALL);
  accepted.OnDialogClosed(ExtensionUninstallDialog::CLOSE_ACTION_CANCELED);
  expect(accepted.mutations == 1 && accepted.completions == 1);
  auto destroyed = setup(); destroyed.profile_ = nullptr;
  destroyed.OnDialogClosed(ExtensionUninstallDialog::CLOSE_ACTION_UNINSTALL);
  expect(destroyed.mutations == 0 && destroyed.completions == 1);
  auto legacy = setup(); legacy.native_operation_authorized_ = {};
  legacy.OnDialogClosed(ExtensionUninstallDialog::CLOSE_ACTION_UNINSTALL);
  expect(legacy.mutations == 1);
  Result result = Result::USER_CANCELED; std::string justification;
  DoneCallback done{[&](DoneCallbackPayload payload) { result = payload.result; justification = payload.justification; }};
  base::RepeatingCallback<bool()> authorization{[&] { return allowed; }};
  CompleteInstall(authorization,done,DoneCallbackPayload(Result::ACCEPTED,"user explanation"));
  expect(result == Result::ACCEPTED && justification == "user explanation");
  allowed = false;
  CompleteInstall(authorization,done,DoneCallbackPayload(Result::ACCEPTED,"must not pass"));
  expect(result == Result::ABORTED && justification.empty());
  CompleteInstall({},done,DoneCallbackPayload(Result::ACCEPTED));
  expect(result == Result::ACCEPTED);
  std::cout << checks << " extracted production prompt checks passed\n";
}
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--chromium-root",required=True,type=Path)
    parser.add_argument("--source-only",action="store_true")
    args = parser.parse_args()
    revision = subprocess.check_output(["git","rev-parse","HEAD"],cwd=args.chromium_root,text=True).strip()
    if revision != adapter.PIN:
        raise SystemExit("Pinned Chromium revision required")
    ManagementPromptTests.originals = adapter.source_baselines(args.chromium_root)
    ManagementPromptTests.source_only = args.source_only
    unittest.main(argv=[__file__],verbosity=2)


if __name__ == "__main__":
    main()
