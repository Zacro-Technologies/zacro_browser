#!/usr/bin/env python3
"""Carry a native operation's revocable approval through Chromium CRX installation."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
PIN = "d0c02bfad08ec92a6ffcf989e53cd995e6381a4c"
APPROVAL = "extensions/browser/install_approval.h"
INSTALLER_H = "extensions/browser/crx_installer.h"
INSTALLER_CC = "extensions/browser/crx_installer.cc"
WEBSTORE = "extensions/browser/webstore_installer.cc"
PATHS = (APPROVAL, INSTALLER_H, INSTALLER_CC, WEBSTORE)


def replace(text, old, new):
    if text.count(old) != 1:
        raise SystemExit(f"Pinned native install source drift: {old[:100]!r}")
    return text.replace(old, new)


def generated(originals):
    output = dict(originals)
    output[APPROVAL] = replace(output[APPROVAL], '#include "base/memory/raw_ptr.h"',
        '#include "base/functional/callback.h"\n#include "base/memory/raw_ptr.h"')
    output[APPROVAL] = replace(output[APPROVAL], '  // Whether to withhold permissions at installation.', '''  // Optional authority for a browser-owned native installation. Invoked only
  // on the UI thread; false revokes the operation before permissions or native
  // registration. Ordinary Chromium installs leave this empty. The callback
  // must not grant permissions, present UI, or retain its owning window.
  base::RepeatingCallback<bool()> native_install_authorized;

  // Whether to withhold permissions at installation.''')
    output[INSTALLER_H] = replace(output[INSTALLER_H], '#include "base/files/file_path.h"',
        '#include "base/files/file_path.h"\n#include "base/functional/callback.h"')
    output[INSTALLER_H] = replace(output[INSTALLER_H], '  // Called after OnUnpackSuccess check to see whether the install expectations', '''  // Revalidates an optional native lease on the UI thread, including after
  // unpacking and shared-file work. Rejection completes the installer once.
  bool CheckNativeInstallAuthorization();
  base::RepeatingCallback<bool()> native_install_authorized_;
  bool native_install_aborted_ = false;

  // Called after OnUnpackSuccess check to see whether the install expectations''')
    source = replace(output[INSTALLER_CC], '''  CHECK(ExtensionsBrowserClient::Get()->IsSameContext(
      browser_context(), approval->browser_context));''', '''  CHECK(ExtensionsBrowserClient::Get()->IsSameContext(
      browser_context(), approval->browser_context));
  native_install_authorized_ = approval->native_install_authorized;''')
    source = replace(source, 'void CrxInstaller::CheckInstall() {', '''bool CrxInstaller::CheckNativeInstallAuthorization() {
  DCHECK_CURRENTLY_ON(BrowserThread::UI);
  if (!browser_context_ || native_install_aborted_) {
    return false;
  }
  if (!native_install_authorized_ || native_install_authorized_.Run()) {
    return true;
  }
  // Failure callbacks may re-enter or release the last external reference.
  // Mark terminal first, and touch no members after reporting the rejection.
  native_install_aborted_ = true;
  ReportFailureFromUIThread(CrxInstallError(
      CrxInstallErrorType::OTHER, CrxInstallErrorDetail::USER_ABORTED));
  return false;
}

void CrxInstaller::CheckInstall() {''')
    source = replace(source, '''void CrxInstaller::CheckInstall() {
  DCHECK_CURRENTLY_ON(BrowserThread::UI);
  if (!browser_context_) {''', '''void CrxInstaller::CheckInstall() {
  DCHECK_CURRENTLY_ON(BrowserThread::UI);
  if (!CheckNativeInstallAuthorization()) {''')
    source = replace(source, '''void CrxInstaller::UpdateCreationFlagsAndCompleteInstall(
    WithholdingBehavior withholding_behavior) {
  creation_flags_''', '''void CrxInstaller::UpdateCreationFlagsAndCompleteInstall(
    WithholdingBehavior withholding_behavior) {
  if (!CheckNativeInstallAuthorization()) {
    return;
  }
  creation_flags_''')
    source = replace(source, '''void CrxInstaller::ReportSuccessFromUIThread() {
  DCHECK_CURRENTLY_ON(BrowserThread::UI);

  if (!browser_context_) {''', '''void CrxInstaller::ReportSuccessFromUIThread() {
  DCHECK_CURRENTLY_ON(BrowserThread::UI);

  // Shared-file work can finish after the owner closes or approval is revoked.
  // Check before success UI, permissions grants, or registrar installation.
  if (!CheckNativeInstallAuthorization()) {''')
    output[INSTALLER_CC] = source
    output[WEBSTORE] = replace(output[WEBSTORE], '''    std::unique_ptr<InstallApproval> approval =
        InstallApproval::CreateForSharedModule(browser_context_);
    const SharedModuleInfo::ImportInfo& info''', '''    std::unique_ptr<InstallApproval> approval =
        InstallApproval::CreateForSharedModule(browser_context_);
    // Dependencies belong to the same reviewed operation. Revoking the main
    // install must also prevent a delayed shared module from being registered.
    if (approval_) {
      approval->native_install_authorized = approval_->native_install_authorized;
    }
    const SharedModuleInfo::ImportInfo& info''')
    return output


def digest(contents):
    return hashlib.sha256(contents.encode()).hexdigest()


def validate_current(originals, output, current, prior=None):
    prior = prior or {}
    previous = prior.get("files", {}) if prior.get("revision") == PIN else {}
    for path in PATHS:
        if current[path] not in (originals[path], output[path]) and digest(current[path]) != previous.get(path):
            raise SystemExit("Refusing to overwrite unrelated edits: " + path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chromium-root", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--emit-patch", action="store_true", help="Write the reviewable patch without mutating Chromium.")
    args = parser.parse_args()
    source = args.chromium_root.resolve()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if revision != PIN:
        raise SystemExit(f"Expected pinned Chromium {PIN}, found {revision}")
    originals = {path: subprocess.check_output(["git", "show", "HEAD:" + path], cwd=source, text=True) for path in PATHS}
    output = generated(originals)
    receipt = source / "out/zacro-native-install-lease.json"
    prior = json.loads(receipt.read_text()) if receipt.exists() else {}
    validate_current(originals, output, {path: (source / path).read_text() for path in PATHS}, prior)
    patch = "".join("".join(difflib.unified_diff(originals[path].splitlines(True), output[path].splitlines(True),
        fromfile="a/" + path, tofile="b/" + path)) for path in PATHS)
    if args.emit_patch or not args.check:
        (ROOT / "native-install-lease.patch").write_text(patch)
    if not args.check and not args.emit_patch:
        for path, contents in output.items():
            target = source / path
            if target.read_text() != contents:
                temporary = target.with_suffix(target.suffix + ".zacro-tmp")
                temporary.write_text(contents); temporary.replace(target)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps({"revision": PIN, "files": {
            p: digest(c) for p, c in output.items()}}, indent=2) + "\n")
    print(f"{'Emitted' if args.emit_patch else 'Checked' if args.check else 'Applied'} native install lease for Chromium {revision[:12]}")


if __name__ == "__main__":
    main()
