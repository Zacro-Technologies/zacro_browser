#!/usr/bin/env python3
"""Test pinned transformations and the generated authorization gate in isolation.

The compiled fixture executes the production gate with callback/context stand-ins;
it does not claim to exercise Chromium's UI, CRX verifier or live installer.
"""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("adapter", ROOT / "apply_install_lease_adapter.py")
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


def method(source, start, next_method):
    return source[source.index(start):source.index(next_method, source.index(start))]


class InstallLeaseTests(unittest.TestCase):
    def test_pinned_transformation_is_repeatable(self):
        self.assertEqual(adapter.generated(self.originals), adapter.generated(self.originals))

    def test_pristine_or_exact_generated_only(self):
        output = adapter.generated(self.originals)
        adapter.validate_current(self.originals, output, self.originals)
        adapter.validate_current(self.originals, output, output)
        modified = dict(output)
        modified[adapter.INSTALLER_CC] += "// unrelated change\n"
        with self.assertRaisesRegex(SystemExit, "unrelated edits"):
            adapter.validate_current(self.originals, output, modified)

    def test_pinned_source_drift_is_rejected(self):
        modified = dict(self.originals)
        modified[adapter.APPROVAL] = modified[adapter.APPROVAL].replace(
            "  // Whether to withhold permissions at installation.", "  // drift")
        with self.assertRaisesRegex(SystemExit, "source drift"):
            adapter.generated(modified)

    def test_upgrade_requires_exact_recorded_generated_bytes_and_pin(self):
        output = adapter.generated(self.originals)
        previous = dict(output)
        previous[adapter.INSTALLER_CC] += "// previous generated revision\n"
        receipt = {"revision": adapter.PIN, "files": {p: adapter.digest(c) for p, c in previous.items()}}
        adapter.validate_current(self.originals, output, previous, receipt)
        changed = dict(previous)
        changed[adapter.INSTALLER_CC] += "// unrelated edit after generation\n"
        with self.assertRaisesRegex(SystemExit, "unrelated edits"):
            adapter.validate_current(self.originals, output, changed, receipt)
        receipt["revision"] = "wrong-pin"
        with self.assertRaisesRegex(SystemExit, "unrelated edits"):
            adapter.validate_current(self.originals, output, previous, receipt)

    def test_authority_is_checked_before_ui_grants_and_registration(self):
        output = adapter.generated(self.originals)[adapter.INSTALLER_CC]
        final = method(output, "void CrxInstaller::ReportSuccessFromUIThread()", "void CrxInstaller::ReportInstallationStage(")
        gate = final.index("CheckNativeInstallAuthorization()")
        for mutation in ["BindToCurrentThread()", "OnInstallSuccess(", "GrantActivePermissions(", "OnExtensionInstalled("]:
            self.assertLess(gate, final.index(mutation))
        prepare = method(output, "void CrxInstaller::UpdateCreationFlagsAndCompleteInstall(", "void CrxInstaller::CompleteInstall(")
        self.assertLess(prepare.index("CheckNativeInstallAuthorization()"), prepare.index("creation_flags_ ="))

    def test_existing_verification_and_non_ui_file_work_are_unchanged(self):
        output = adapter.generated(self.originals)[adapter.INSTALLER_CC]
        original = self.originals[adapter.INSTALLER_CC]
        for start, end in [
            ("void CrxInstaller::CompleteInstall(", "void CrxInstaller::ReloadExtensionAfterInstall("),
            ("std::optional<CrxInstallError> CrxInstaller::AllowInstall(", "void CrxInstaller::OnUnpackFailure(")]:
            self.assertEqual(method(original, start, end), method(output, start, end))

    def test_real_generated_gate_handles_revocation_and_reentrant_completion(self):
        if self.source_only:
            self.skipTest("Source-only check; compile the isolated production gate separately.")
        output = adapter.generated(self.originals)
        gate = method(output[adapter.INSTALLER_CC], "bool CrxInstaller::CheckNativeInstallAuthorization()", "void CrxInstaller::CheckInstall()")
        propagation = method(output[adapter.WEBSTORE], "    if (approval_) {\n      approval->native_install_authorized", "    const SharedModuleInfo::ImportInfo& info")
        with tempfile.TemporaryDirectory(prefix="zacro-install-lease-") as temporary:
            root = Path(temporary)
            source = root / "gate.cc"
            source.write_text(PRELUDE + gate + "\nvoid CopyLease(Approval* approval, Approval* approval_) {\n" + propagation + "}\n" + FIXTURES)
            executable = root / "gate"
            subprocess.run(["xcrun", "clang++", "-std=c++20", "-O0", str(source), "-o", str(executable)], check=True)
            result = subprocess.check_output([str(executable)], text=True)
            self.assertEqual(result.strip(), "8 isolated production install lease checks passed")


PRELUDE = r'''
#include <functional>
#include <iostream>
#include <memory>
#include <stdexcept>
#define DCHECK_CURRENTLY_ON(thread) do {} while (0)
enum class CrxInstallErrorType { OTHER };
enum class CrxInstallErrorDetail { USER_ABORTED };
struct CrxInstallError { CrxInstallError(CrxInstallErrorType, CrxInstallErrorDetail) {} };
struct Callback {
  std::function<bool()> value;
  explicit operator bool() const { return bool(value); }
  bool Run() { return value(); }
};
struct Approval { Callback native_install_authorized; };
struct CrxInstaller {
  void* browser_context_ = this;
  Callback native_install_authorized_;
  bool native_install_aborted_ = false;
  int failures = 0;
  bool reenter = false;
  bool CheckNativeInstallAuthorization();
  void ReportFailureFromUIThread(CrxInstallError) {
    ++failures;
    if (reenter && CheckNativeInstallAuthorization()) throw std::runtime_error("Reentrant authorization");
  }
};
'''

FIXTURES = r'''
int main() {
  int checks = 0;
  auto expect = [&](bool ok) { if (!ok) throw std::runtime_error("Lease invariant failed"); ++checks; };
  CrxInstaller ordinary;
  expect(ordinary.CheckNativeInstallAuthorization() && ordinary.failures == 0);
  auto authorized = std::make_shared<bool>(true);
  int calls = 0;
  Approval parent;
  parent.native_install_authorized.value = [authorized, &calls] { ++calls; return *authorized; };
  Approval dependency;
  CopyLease(&dependency, &parent);
  CrxInstaller main_install, dependent_install;
  main_install.native_install_authorized_ = parent.native_install_authorized;
  dependent_install.native_install_authorized_ = dependency.native_install_authorized;
  expect(main_install.CheckNativeInstallAuthorization() && calls == 1);
  expect(dependent_install.CheckNativeInstallAuthorization() && calls == 2);
  parent.native_install_authorized = {}; // The copied lease survives approval ownership transfer.
  *authorized = false;
  main_install.reenter = true;
  expect(!main_install.CheckNativeInstallAuthorization() && main_install.failures == 1 && calls == 3);
  expect(!dependent_install.CheckNativeInstallAuthorization() && dependent_install.failures == 1 && calls == 4);
  *authorized = true; // A terminal cancellation cannot be revived by later state.
  expect(!main_install.CheckNativeInstallAuthorization() && main_install.failures == 1 && calls == 4);
  CrxInstaller shut_down;
  shut_down.browser_context_ = nullptr;
  shut_down.native_install_authorized_.value = [] { throw std::runtime_error("Dead context callback"); return true; };
  expect(!shut_down.CheckNativeInstallAuthorization() && shut_down.failures == 0);
  Approval ordinary_dependency;
  CopyLease(&ordinary_dependency, &parent);
  expect(!ordinary_dependency.native_install_authorized);
  std::cout << checks << " isolated production install lease checks passed\n";
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chromium-root", required=True, type=Path)
    parser.add_argument("--source-only", action="store_true")
    args = parser.parse_args()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=args.chromium_root, text=True).strip()
    if revision != adapter.PIN:
        raise SystemExit("This fixture requires pinned Chromium source.")
    InstallLeaseTests.originals = {path: subprocess.check_output(["git", "show", "HEAD:" + path], cwd=args.chromium_root, text=True) for path in adapter.PATHS}
    InstallLeaseTests.source_only = args.source_only
    unittest.main(argv=["native-install-lease"], verbosity=2)


if __name__ == "__main__":
    main()
