#!/usr/bin/env python3
"""Bind original Chrome extension prompts to a revocable native operation."""
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
INSTALL_H = BASE + "extension_install_prompt.h"
INSTALL_CC = BASE + "extension_install_prompt.cc"
PARAMS = BASE + "extension_install_prompt_show_params.h"
VIEW = "chrome/browser/ui/views/extensions/extension_install_dialog_view.cc"
UNINSTALL_H = BASE + "extension_uninstall_dialog.h"
UNINSTALL_CC = BASE + "extension_uninstall_dialog.cc"
CONSTRAINED = "components/constrained_window/constrained_window_views.cc"
PATHS = (INSTALL_H, INSTALL_CC, PARAMS, VIEW, UNINSTALL_H, UNINSTALL_CC, CONSTRAINED)


def replace(text, old, new):
    if text.count(old) != 1:
        raise SystemExit(f"Pinned native prompt source drift: {old[:100]!r}")
    return text.replace(old, new)


def generated(originals):
    output = dict(originals)
    callback_decl = '''  // Native browser operations retain Chrome's consent UI and result callback.
  // Validation and cancellation registration run only on the UI thread. The
  // registration replaces the prior pending-icon/widget cancellation closure.
  void SetNativeOperationCallbacks(
      base::RepeatingCallback<bool()> authorized,
      base::RepeatingCallback<void(base::OnceClosure)> register_cancellation);

'''
    output[INSTALL_H] = replace(output[INSTALL_H], '  bool did_call_show_dialog() const', callback_decl + '  bool did_call_show_dialog() const')
    output[INSTALL_H] = replace(output[INSTALL_H], ' private:\n', ''' private:
  void CancelNativeOperation();
  base::RepeatingCallback<bool()> native_operation_authorized_;
  base::RepeatingCallback<void(base::OnceClosure)> native_register_cancellation_;

''')
    output[PARAMS] = replace(output[PARAMS], '#include "base/memory/raw_ptr.h"', '#include "base/functional/callback.h"\n#include "base/memory/raw_ptr.h"')
    output[PARAMS] = replace(output[PARAMS], '  Profile* profile() {', '''  base::RepeatingCallback<bool()> native_operation_authorized;
  base::RepeatingCallback<void(base::OnceClosure)> native_register_cancellation;

  Profile* profile() {''')
    source = replace(output[INSTALL_CC], 'ExtensionInstallPrompt::~ExtensionInstallPrompt() = default;', '''ExtensionInstallPrompt::~ExtensionInstallPrompt() = default;

void ExtensionInstallPrompt::SetNativeOperationCallbacks(
    base::RepeatingCallback<bool()> authorized,
    base::RepeatingCallback<void(base::OnceClosure)> register_cancellation) {
  DCHECK(ui_thread_checker_.CalledOnValidThread());
  DCHECK(!done_callback_);
  native_operation_authorized_ = std::move(authorized);
  native_register_cancellation_ = std::move(register_cancellation);
  show_params_->native_operation_authorized = native_operation_authorized_;
  show_params_->native_register_cancellation = native_register_cancellation_;
}

void ExtensionInstallPrompt::CancelNativeOperation() {
  DCHECK(ui_thread_checker_.CalledOnValidThread());
  // An icon reply must not create a prompt after cancellation. Once ownership
  // moves to Views, its registered weak widget closure performs cancellation.
  weak_factory_.InvalidateWeakPtrs();
  if (done_callback_) {
    std::move(done_callback_).Run(DoneCallbackPayload(Result::ABORTED));
  }
}''')
    source = replace(source, '  done_callback_ = std::move(done_callback);', '''  done_callback_ = base::BindOnce(
      [](base::RepeatingCallback<bool()> authorized, DoneCallback completion,
         DoneCallbackPayload payload) {
        // Also covers theme/autoconfirm paths which never create a widget.
        if (authorized && !authorized.Run()) {
          std::move(completion).Run(DoneCallbackPayload(Result::ABORTED));
          return;
        }
        std::move(completion).Run(std::move(payload));
      }, native_operation_authorized_, std::move(done_callback));
  if (native_operation_authorized_ && !native_operation_authorized_.Run()) {
    CancelNativeOperation();
    return;
  }
  if (native_register_cancellation_) {
    auto weak_this = weak_factory_.GetWeakPtr();
    auto register_cancellation = native_register_cancellation_;
    register_cancellation.Run(base::BindOnce(
        &ExtensionInstallPrompt::CancelNativeOperation, weak_this));
    // Registration can immediately cancel an already-revoked operation and
    // release this prompt through its original completion callback.
    if (!weak_this || !weak_this->done_callback_) {
      return;
    }
  }''')
    source = replace(source, 'void ExtensionInstallPrompt::ShowConfirmation() {', '''void ExtensionInstallPrompt::ShowConfirmation() {
  if (!done_callback_) {
    return;
  }
  if (native_operation_authorized_ && !native_operation_authorized_.Run()) {
    CancelNativeOperation();
    return;
  }''')
    source = replace(source, '''  // Notify observers.
  prompt_->OnDialogOpened();''', '''  // Notify observers. Native cancellation can reenter during notification.
  auto weak_this = weak_factory_.GetWeakPtr();
  prompt_->OnDialogOpened();
  if (!weak_this || !weak_this->done_callback_) {
    return;
  }''')
    output[INSTALL_CC] = source
    source = replace(output[VIEW], """  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);

  // If the dialog has to be parented""", """  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto authorized = show_params->native_operation_authorized;
  auto register_cancellation = show_params->native_register_cancellation;
  if ((authorized && !authorized.Run()) || show_params->WasParentDestroyed()) {
    std::move(done_callback).Run(ExtensionInstallPrompt::DoneCallbackPayload(
        ExtensionInstallPrompt::Result::ABORTED));
    return;
  }

  // If the dialog has to be parented""")
    source = replace(source, '''  constrained_window::CreateBrowserModalDialogViews(std::move(dialog),
                                                    parent_window)
      ->Show();''', '''  auto* widget = constrained_window::CreateBrowserModalDialogViews(
      std::move(dialog), parent_window);
  auto weak_widget = widget->GetWeakPtr();
  if (register_cancellation) {
    register_cancellation.Run(base::BindOnce(
        [](base::WeakPtr<views::Widget> widget) {
          if (widget && !widget->IsClosed()) {
            if (auto* dialog = widget->widget_delegate()->AsDialogDelegate()) {
              dialog->CancelDialog();
            }
          }
        }, weak_widget));
  }
  if (!weak_widget || weak_widget->IsClosed()) {
    return;
  }
  if (authorized && !authorized.Run()) {
    if (weak_widget && !weak_widget->IsClosed()) {
      weak_widget->widget_delegate()->AsDialogDelegate()->CancelDialog();
    }
    return;
  }
  weak_widget->Show();''')
    source = replace(source, '''void ExtensionInstallDialogView::OnDialogAccepted() {
  DCHECK(done_callback_);''', '''void ExtensionInstallDialogView::OnDialogAccepted() {
  DCHECK(done_callback_);
  if (show_params_->native_operation_authorized &&
      !show_params_->native_operation_authorized.Run()) {
    OnDialogCanceled();
    return;
  }''')
    output[VIEW] = source
    output[UNINSTALL_H] = replace(output[UNINSTALL_H], '#include "base/memory/raw_ptr.h"', '#include "base/functional/callback.h"\n#include "base/memory/raw_ptr.h"')
    output[UNINSTALL_H] = replace(output[UNINSTALL_H], '  // This is called to verify whether the uninstallation should proceed.', callback_decl + '  // This is called to verify whether the uninstallation should proceed.')
    output[UNINSTALL_H] = replace(output[UNINSTALL_H], ''' private:
  // Uninstalls the extension.''', ''' private:
  void CancelNativeOperation();
  bool NativeOperationIsAuthorized() const;
  base::RepeatingCallback<bool()> native_operation_authorized_;
  base::RepeatingCallback<void(base::OnceClosure)> native_register_cancellation_;
  bool native_operation_cancelled_ = false;
  bool native_operation_completed_ = false;
  bool native_dialog_creating_ = false;
  bool native_dialog_visible_ = false;

  // Uninstalls the extension.''')
    source = replace(output[UNINSTALL_CC], 'ExtensionUninstallDialog::~ExtensionUninstallDialog() = default;', '''ExtensionUninstallDialog::~ExtensionUninstallDialog() = default;

void ExtensionUninstallDialog::SetNativeOperationCallbacks(
    base::RepeatingCallback<bool()> authorized,
    base::RepeatingCallback<void(base::OnceClosure)> register_cancellation) {
  DCHECK(thread_checker_.CalledOnValidThread());
  DCHECK(!extension_);
  native_operation_authorized_ = std::move(authorized);
  native_register_cancellation_ = std::move(register_cancellation);
}

bool ExtensionUninstallDialog::NativeOperationIsAuthorized() const {
  if (native_operation_cancelled_ || !profile_) {
    return false;
  }
  if (!native_operation_authorized_) {
    return true;
  }
  return native_operation_authorized_.Run() && extension_ &&
      ExtensionRegistry::Get(profile_)->GetExtensionById(
          extension_->id(), ExtensionRegistry::EVERYTHING) == extension_.get();
}

void ExtensionUninstallDialog::CancelNativeOperation() {
  DCHECK(thread_checker_.CalledOnValidThread());
  if (native_operation_completed_) {
    return;
  }
  native_operation_cancelled_ = true;
  // Show() can reenter through native widget creation. Its dialog model has
  // no host yet, so defer Close() until that handoff has completed.
  if (native_dialog_creating_) {
    return;
  }
  if (native_dialog_visible_) {
    Close();
    return;
  }
  OnDialogClosed(CLOSE_ACTION_CANCELED);
}''')
    source = replace(source, '''  extension_ = extension;
  uninstall_reason_ = reason;

  if (!profile_)''', '''  extension_ = extension;
  uninstall_reason_ = reason;

  if (native_register_cancellation_) {
    auto weak_this = weak_ptr_factory_.GetWeakPtr();
    auto register_cancellation = native_register_cancellation_;
    register_cancellation.Run(base::BindOnce(
        &ExtensionUninstallDialog::CancelNativeOperation, weak_this));
    if (!weak_this || weak_this->native_operation_completed_) {
      return;
    }
  }
  if (native_operation_authorized_ && !NativeOperationIsAuthorized()) {
    CancelNativeOperation();
    return;
  }
  if (!profile_)''')
    source = replace(source, '''  if (!icon_ || dialog_shown_)
    return;''', '''  if (!icon_ || dialog_shown_ || native_operation_completed_)
    return;''')
    source = replace(source, '''  if (g_on_will_show_callback != nullptr) {
    g_on_will_show_callback->Run();
  }

  switch''', '''  auto weak_this = weak_ptr_factory_.GetWeakPtr();
  if (g_on_will_show_callback != nullptr) {
    g_on_will_show_callback->Run();
  }
  if (!weak_this || weak_this->native_operation_completed_) {
    return;
  }
  if (native_operation_authorized_ && !NativeOperationIsAuthorized()) {
    CancelNativeOperation();
    return;
  }

  switch''')
    source = replace(source, '''    case ScopedTestDialogAutoConfirm::NONE:
      Show();
      break;''', '''    case ScopedTestDialogAutoConfirm::NONE:
      native_dialog_creating_ = true;
      Show();
      if (!weak_this || weak_this->native_operation_completed_) {
        return;
      }
      native_dialog_creating_ = false;
      native_dialog_visible_ = true;
      if (native_operation_cancelled_ ||
          (native_operation_authorized_ && !NativeOperationIsAuthorized())) {
        CancelNativeOperation();
      }
      break;''')
    source = replace(source, '''  extension_uninstalled_early_ = true;
  Close();''', '''  extension_uninstalled_early_ = true;
  CancelNativeOperation();''')
    source = replace(source, '''void ExtensionUninstallDialog::OnDialogClosed(CloseAction action) {
  // Ensure''', '''void ExtensionUninstallDialog::OnDialogClosed(CloseAction action) {
  DCHECK(thread_checker_.CalledOnValidThread());
  if (native_operation_completed_) {
    return;
  }
  // Gate BEFORE Uninstall(), report-abuse navigation, and delegate callbacks.
  // An updated/reinstalled object with the same ID is a different operation.
  if (native_operation_cancelled_ || !profile_ ||
      (native_operation_authorized_ && !NativeOperationIsAuthorized())) {
    action = CLOSE_ACTION_CANCELED;
  }
  native_operation_completed_ = true;
  native_dialog_visible_ = false;
  // Ensure''')
    source = replace(source, """  profile_ = nullptr;
  profile_observation_.Reset();
  OnDialogClosed(CLOSE_ACTION_CANCELED);""", """  profile_ = nullptr;
  profile_observation_.Reset();
  CancelNativeOperation();""")
    output[UNINSTALL_CC] = source
    output[CONSTRAINED] = replace(output[CONSTRAINED], '''    gfx::AcceleratedWidget parent_widget =
        parent ? CurrentBrowserModalClient()
                     ->GetModalDialogHost(parent)
                     ->GetAcceleratedWidget()
               : gfx::kNullAcceleratedWidget;''', '''    auto* parent_host = parent
        ? CurrentBrowserModalClient()->GetModalDialogHost(parent) : nullptr;
    gfx::AcceleratedWidget parent_widget = parent_host
        ? parent_host->GetAcceleratedWidget() : gfx::kNullAcceleratedWidget;''')
    output[CONSTRAINED] = replace(output[CONSTRAINED], '''  gfx::AcceleratedWidget parent_widget = parent
                                             ? CurrentBrowserModalClient()
                                                   ->GetModalDialogHost(parent)
                                                   ->GetAcceleratedWidget()
                                             : gfx::kNullAcceleratedWidget;''', '''  // Native AppKit owners have a host view but no Chrome ModalDialogHost.
  auto* parent_host = parent
      ? CurrentBrowserModalClient()->GetModalDialogHost(parent) : nullptr;
  gfx::AcceleratedWidget parent_widget = parent_host
      ? parent_host->GetAcceleratedWidget() : gfx::kNullAcceleratedWidget;''')
    return output


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def source_baselines(source):
    originals = {p: subprocess.check_output(["git", "show", "HEAD:" + p], cwd=source, text=True) for p in PATHS}
    cef = source / "cef"
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=cef, text=True).strip()
    if not revision.startswith(CEF_PIN):
        raise SystemExit("Unexpected pinned CEF revision: " + revision)
    patch = subprocess.check_output(["git", "show", "HEAD:patch/patches/chrome_browser_dialogs_widget.patch"], cwd=cef, text=True)
    selected = ["diff --git " + section for section in patch.split("diff --git ")[1:]
                if section.splitlines()[0].split()[0] == CONSTRAINED]
    if len(selected) != 1:
        raise SystemExit("Pinned CEF constrained-window patch changed")
    with tempfile.TemporaryDirectory(prefix="zacro-prompt-baseline-") as temporary:
        root = Path(temporary); target = root / CONSTRAINED
        target.parent.mkdir(parents=True); target.write_text(originals[CONSTRAINED])
        subprocess.run(["git", "apply", "-p0", "--unsafe-paths", "-"], input=selected[0], cwd=root, text=True, check=True)
        originals[CONSTRAINED] = target.read_text()
    return originals


def validate_current(originals, output, current, prior=None):
    prior = prior or {}
    previous = prior.get("files", {}) if prior.get("revision") == PIN else {}
    for path in PATHS:
        if current[path] not in (originals[path], output[path]) and digest(current[path]) != previous.get(path):
            raise SystemExit("Refusing to overwrite unrelated prompt edits: " + path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chromium-root", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--emit-patch", action="store_true")
    args = parser.parse_args(); source = args.chromium_root.resolve()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if revision != PIN:
        raise SystemExit("Unexpected pinned Chromium revision: " + revision)
    originals = source_baselines(source); output = generated(originals)
    receipt = source / "out/zacro-native-management-prompts.json"
    prior = json.loads(receipt.read_text()) if receipt.exists() else {}
    validate_current(originals, output, {p: (source / p).read_text() for p in PATHS}, prior)
    patch = "".join("".join(difflib.unified_diff(originals[p].splitlines(True), output[p].splitlines(True),
        fromfile="a/" + p, tofile="b/" + p)) for p in PATHS)
    if args.emit_patch or not args.check:
        (ROOT / "native-management-prompts.patch").write_text(patch)
    if not args.check and not args.emit_patch:
        for path, contents in output.items():
            target = source / path
            if target.read_text() != contents:
                temporary = target.with_suffix(target.suffix + ".zacro-tmp")
                temporary.write_text(contents); temporary.replace(target)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps({"revision":PIN,"files":{p:digest(c) for p,c in output.items()}},indent=2) + "\n")
    print(f"{'Emitted' if args.emit_patch else 'Checked' if args.check else 'Applied'} native management prompts for Chromium {revision[:12]}")


if __name__ == "__main__":
    main()
