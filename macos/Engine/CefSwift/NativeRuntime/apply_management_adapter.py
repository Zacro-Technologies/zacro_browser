#!/usr/bin/env python3
"""Bind genuine Chromium management functions to a revocable native owner."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
PIN = "d0c02bfad08ec92a6ffcf989e53cd995e6381a4c"
CEF_PIN = "4fa4ab516dac"
BASE = "chrome/browser/extensions/"
DELEGATE = "extensions/browser/api/management/management_api_delegate.h"
API = "extensions/browser/api/management/management_api.cc"
CH = BASE + "api/management/chrome_management_api_delegate.h"
CC = BASE + "api/management/chrome_management_api_delegate.cc"
WH = BASE + "webstore_standalone_installer.h"
WC = BASE + "webstore_standalone_installer.cc"
BUILD = BASE + "BUILD.gn"
NEW = {BASE + "native_management_operation.h": "native_management_operation.h.in",
       BASE + "native_management_operation.cc": "native_management_operation.cc.in",
       BASE + "native_management_operation_mac.mm": "native_management_operation_mac.mm.in"}
PATHS = (DELEGATE, API, CH, CC, WH, WC, BUILD, *NEW)


def replace(text, old, new):
    if text.count(old) != 1:
        raise SystemExit(f"Pinned management source drift: {old[:120]!r}")
    return text.replace(old, new)


def originals(source):
    result = {path: "" if path in NEW else subprocess.check_output(
        ["git", "show", "HEAD:" + path], cwd=source, text=True) for path in PATHS}
    # CEF's pinned background-mode fix is part of the baseline, not our edit.
    cef = source / "cef"
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=cef, text=True).strip()
    if not revision.startswith(CEF_PIN): raise SystemExit("Unexpected CEF revision: " + revision)
    patch = subprocess.check_output(["git", "show", "HEAD:patch/patches/chrome_browser_extensions_background.patch"],
                                    cwd=cef, text=True)
    with tempfile.TemporaryDirectory(prefix="zacro-management-base-") as directory:
        staging = Path(directory)
        target = staging / BUILD
        target.parent.mkdir(parents=True)
        target.write_text(result[BUILD])
        subprocess.run(["git", "apply", "-p0", "-"], input=patch, text=True,
                       cwd=staging, check=True, capture_output=True)
        result[BUILD] = target.read_text()
    return result


def generated(original):
    out = dict(original)
    for path, template in NEW.items():
        out[path] = (ROOT / template).read_text()
    out[DELEGATE] = replace(out[DELEGATE], "namespace content {", "class ExtensionFunction;\n\nnamespace content {")
    out[DELEGATE] = replace(out[DELEGATE], "  // Enables the extension identified by `extension_id`.", """  // Ordinary renderer calls preserve their original behavior. Native shell
  // invocations additionally carry an exact revocable operation lease.
  virtual bool NativeOperationIsValid(ExtensionFunction* function) const {
    return true;
  }
  virtual std::unique_ptr<InstallPromptDelegate> SetEnabledFunctionDelegateForNative(
      ExtensionFunction* function, content::WebContents* web_contents,
      content::BrowserContext* browser_context, const Extension* extension,
      base::OnceCallback<void(bool)> callback) const {
    return SetEnabledFunctionDelegate(web_contents, browser_context, extension,
                                     std::move(callback));
  }

  // Enables the extension identified by `extension_id`.""")
    out[DELEGATE] = replace(out[DELEGATE], '#include "base/functional/callback.h"', '#include <utility>\n#include "base/functional/callback.h"')
    validity = "ManagementAPI::GetFactoryInstance()->Get(browser_context())->GetDelegate()->NativeOperationIsValid(this)"
    out[API] = replace(out[API], "ExtensionFunction::ResponseAction ManagementSetEnabledFunction::Run() {", "ExtensionFunction::ResponseAction ManagementSetEnabledFunction::Run() {\n  if (!" + validity + ") return RespondNow(Error(\"The native extension operation was cancelled.\"));")
    for signature in ("void ManagementSetEnabledFunction::CheckPermissionsIncrease() {", "void ManagementSetEnabledFunction::CheckManifestV2Deprecation() {"):
        out[API] = replace(out[API], signature, signature + "\n  if (!" + validity + ") {\n    FinishEnable(Error(\"The native extension operation was cancelled.\")); return;\n  }")
    out[API] = replace(out[API], "install_prompt_ = delegate->SetEnabledFunctionDelegate(\n        GetSenderWebContents()", "install_prompt_ = delegate->SetEnabledFunctionDelegateForNative(\n        this, GetSenderWebContents()")
    out[API] = replace(out[API], "    SupervisedExtensionApprovalResult result) {", "    SupervisedExtensionApprovalResult result) {\n  if (!" + validity + ") {\n    Respond(Error(\"The native extension operation was cancelled.\"));\n    Release(); return;\n  }")
    out[CH] = replace(out[CH], "  // ManagementAPIDelegate.", """  bool NativeOperationIsValid(ExtensionFunction* function) const override;
  std::unique_ptr<InstallPromptDelegate> SetEnabledFunctionDelegateForNative(
      ExtensionFunction* function, content::WebContents* web_contents,
      content::BrowserContext* browser_context, const Extension* extension,
      base::OnceCallback<void(bool)> callback) const override;

  // ManagementAPIDelegate.""")
    out[CC] = replace(out[CC], '#include "chrome/browser/extensions/extension_management.h"', '#include "chrome/browser/extensions/extension_management.h"\n#include "chrome/browser/extensions/native_management_operation.h"')
    out[CC] = replace(out[CC], "      base::OnceCallback<void(bool)> callback)\n      : callback_(std::move(callback)) {", "      base::OnceCallback<void(bool)> callback,\n      base::WeakPtr<NativeManagementOperation> operation = {})\n      : callback_(std::move(callback)) {")
    out[CC] = replace(out[CC], """    install_prompt_ = std::make_unique<ExtensionInstallPrompt>(
        web_contents, std::make_unique<InstallPromptData>(type));""", """    if (operation) {
      install_prompt_ = std::make_unique<ExtensionInstallPrompt>(
          Profile::FromBrowserContext(browser_context), operation->parent(),
          std::make_unique<InstallPromptData>(type));
      operation->ConfigurePrompt(install_prompt_.get());
    } else {
      install_prompt_ = std::make_unique<ExtensionInstallPrompt>(
          web_contents, std::make_unique<InstallPromptData>(type));
    }""")
    out[CC] = replace(out[CC], """        details.GetNativeWindowForUI(), this);""", """        NativeManagementOperation::ForFunction(function)
            ? NativeManagementOperation::ForFunction(function)->parent()
            : details.GetNativeWindowForUI(), this);
    if (auto operation = NativeManagementOperation::ForFunction(function))
      operation->ConfigureUninstallDialog(extension_uninstall_dialog_.get());""")
    out[CC] = replace(out[CC], "std::unique_ptr<UninstallDialogDelegate>\nChromeManagementAPIDelegate::UninstallFunctionDelegate(", """bool ChromeManagementAPIDelegate::NativeOperationIsValid(ExtensionFunction* function) const {
  return NativeManagementOperation::FunctionIsValid(function);
}

std::unique_ptr<InstallPromptDelegate>
ChromeManagementAPIDelegate::SetEnabledFunctionDelegateForNative(
    ExtensionFunction* function, content::WebContents* web_contents,
    content::BrowserContext* browser_context, const Extension* extension,
    base::OnceCallback<void(bool)> callback) const {
  return std::make_unique<ManagementSetEnabledFunctionInstallPromptDelegate>(
      web_contents, browser_context, extension, std::move(callback),
      NativeManagementOperation::ForFunction(function));
}

std::unique_ptr<UninstallDialogDelegate>
ChromeManagementAPIDelegate::UninstallFunctionDelegate(""")
    # Cancellation must not balance BeginInstall twice or leave late callbacks
    # able to restart an already revoked standalone flow.
    out[WH] = replace(out[WH], "  // Input configuration.", "  bool started_ = false;\n  bool terminal_ = false;\n  bool cleaned_up_ = false;\n\n  // Input configuration.")
    out[WC] = replace(out[WC], "void WebstoreStandaloneInstaller::BeginInstall() {", "void WebstoreStandaloneInstaller::BeginInstall() {\n  CHECK(!started_ && !terminal_);\n  started_ = true;")
    out[WC] = replace(out[WC], "void WebstoreStandaloneInstaller::AbortInstall() {", """void WebstoreStandaloneInstaller::AbortInstall() {
  if (terminal_) return;
  auto keep_alive = base::WrapRefCounted(this);
  terminal_ = true;
  weak_ptr_factory_.InvalidateWeakPtrs();""")
    out[WC] = replace(out[WC], """    const std::string& error) {
  scoped_active_install_.reset();""", """    const std::string& error) {
  if (terminal_) return;
  auto keep_alive = base::WrapRefCounted(this);
  terminal_ = true;
  weak_ptr_factory_.InvalidateWeakPtrs();
  scoped_active_install_.reset();""")
    out[WC] = replace(out[WC], "void WebstoreStandaloneInstaller::ProceedWithInstallPrompt() {", "void WebstoreStandaloneInstaller::ProceedWithInstallPrompt() {\n  if (terminal_) return;")
    out[WC] = replace(out[WC], "    ExtensionInstallPrompt::DoneCallbackPayload payload) {", "    ExtensionInstallPrompt::DoneCallbackPayload payload) {\n  if (terminal_) return;")
    out[WC] = replace(out[WC], "void WebstoreStandaloneInstaller::CleanUp() {", """void WebstoreStandaloneInstaller::CleanUp() {
  if (cleaned_up_) return;
  cleaned_up_ = true;
  CHECK(started_);
  weak_ptr_factory_.InvalidateWeakPtrs();""")
    out[BUILD] = replace(out[BUILD], '    "extension_install_prompt.cc",', '    "native_management_operation.h",\n    "native_management_operation.cc",\n    "extension_install_prompt.cc",')
    out[BUILD] = replace(out[BUILD], '  if (is_mac) {\n    deps += [ "//chrome/browser/mac" ]', '  if (is_mac) {\n    sources += [ "native_management_operation_mac.mm" ]\n    deps += [ "//chrome/browser/mac" ]')
    return out


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chromium-root", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    source = args.chromium_root.resolve()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if revision != PIN: raise SystemExit("Unexpected Chromium revision: " + revision)
    before = originals(source)
    after = generated(before)
    receipt = source / "out/zacro-management-operation.json"
    previous = json.loads(receipt.read_text()) if receipt.exists() else {}
    if previous.get("revision") != PIN: previous = {}
    for path, contents in after.items():
        target = source / path
        current = target.read_text() if target.exists() else ""
        if current not in (before[path], contents) and digest(current) != previous.get("files", {}).get(path):
            raise SystemExit("Refusing unrelated management edits: " + path)
    patch = "".join("".join(difflib.unified_diff(before[p].splitlines(True), c.splitlines(True),
        fromfile="a/" + p if before[p] else "/dev/null", tofile="b/" + p)) for p, c in after.items())
    if not args.check:
        (ROOT / "native-management-operation.patch").write_text(patch)
        for path, contents in after.items():
            target = source / path
            if not target.exists() or target.read_text() != contents:
                temporary = target.with_suffix(target.suffix + ".zacro-tmp")
                temporary.write_text(contents); temporary.replace(target)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps({"revision": PIN, "files": {p: digest(c) for p, c in after.items()}}, indent=2) + "\n")
    print(("Checked" if args.check else "Applied") + " native management ownership")


if __name__ == "__main__": main()
