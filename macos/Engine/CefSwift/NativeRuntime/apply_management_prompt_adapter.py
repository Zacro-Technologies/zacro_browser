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
CONSTRAINED_BUILD = "components/constrained_window/BUILD.gn"
BRIDGE = "components/remote_cocoa/app_shim/native_widget_ns_window_bridge.mm"
BRIDGE_BUILD = "components/remote_cocoa/app_shim/BUILD.gn"
CAPTURE = "components/remote_cocoa/app_shim/mouse_capture.mm"
EXTERNAL_PARENT = "components/remote_cocoa/app_shim/external_window_modal_parent.h"
EXTERNAL_PARENT_IMPL = "components/remote_cocoa/app_shim/zacro_external_window_modal_parent.inc"
NEW = {EXTERNAL_PARENT: "native_external_window_modal_parent.h.in",
       EXTERNAL_PARENT_IMPL: "native_external_window_modal_parent.inc"}
PATHS = (INSTALL_H, INSTALL_CC, PARAMS, VIEW, UNINSTALL_H, UNINSTALL_CC, CONSTRAINED,
         CONSTRAINED_BUILD, BRIDGE, BRIDGE_BUILD, CAPTURE, *NEW)


def replace(text, old, new):
    if text.count(old) != 1:
        raise SystemExit(f"Pinned native prompt source drift: {old[:100]!r}")
    return text.replace(old, new)


def generated(originals):
    output = dict(originals)
    # Keep the dispatch/capture contract byte-for-byte: these optional scalar
    # diagnostics only observe the pinned local monitor's actual return path.
    capture = replace(output[CAPTURE], '#include "base/check_op.h"',
                      '#include "base/check_op.h"\n#include "base/logging.h"')
    capture = replace(capture, '#include <memory>', '#include <cstdint>\n#include <memory>')
    capture = replace(capture, 'namespace remote_cocoa {\n', '''namespace remote_cocoa {
namespace {
bool NativeCaptureTraceEnabled() {
  static const bool enabled =
      [NSProcessInfo.processInfo.arguments containsObject:@"--engine-acceptance"] &&
      [NSProcessInfo.processInfo.arguments
          containsObject:@"--native-integration-acceptance"] &&
      [NSProcessInfo.processInfo.environment[@"ZACRO_NATIVE_CAPTURE_TRACE"]
          isEqualToString:@"1"];
  return enabled;
}
}  // namespace
''')
    capture = replace(capture, '''  [NSEvent removeMonitor:global_monitor_];
  [NSEvent removeMonitor:local_monitor_];
  g_active_event_tap = nullptr;''', '''  // Snapshot before removing monitors or notifying a possibly reentrant owner.
  const bool trace_capture = NativeCaptureTraceEnabled();
  const NSInteger capture_window_number = trace_capture
      ? [GetCaptureWindow() windowNumber] : 0;
  [NSEvent removeMonitor:global_monitor_];
  [NSEvent removeMonitor:local_monitor_];
  g_active_event_tap = nullptr;
  if (trace_capture) {
    LOG(ERROR) << "Native mouse capture stage=released capture_window="
               << capture_window_number << " active_count=0";
  }''')
    capture = replace(capture, '''    bool handled = weak_ptr->delegate_->PostCapturedEvent(event);''', '''    // The delegate may destroy the capture, its window, or another monitor.
    // Read only scalar values before dispatch; never touch its owner afterward.
    const bool trace_capture = NativeCaptureTraceEnabled() &&
        event.type == NSEventTypeScrollWheel;
    NSInteger capture_window_number = 0;
    NSInteger target_window_number = 0;
    NSUInteger phase = 0;
    NSUInteger momentum_phase = 0;
    int64_t timestamp_micros = 0;
    CGFloat delta_x = 0;
    CGFloat delta_y = 0;
    if (trace_capture) {
      capture_window_number = [weak_ptr->delegate_->GetWindow() windowNumber];
      target_window_number = event.windowNumber;
      phase = event.phase;
      momentum_phase = event.momentumPhase;
      timestamp_micros = static_cast<int64_t>(event.timestamp * 1'000'000);
      delta_x = event.scrollingDeltaX;
      delta_y = event.scrollingDeltaY;
      LOG(ERROR) << "Native mouse capture stage=local-scroll-enter capture_window="
                 << capture_window_number << " target_window=" << target_window_number
                 << " phase=" << phase << " momentum=" << momentum_phase
                 << " timestamp_us=" << timestamp_micros
                 << " delta_x=" << delta_x << " delta_y=" << delta_y
                 << " active_count=1";
    }
    bool handled = weak_ptr->delegate_->PostCapturedEvent(event);
    if (trace_capture) {
      LOG(ERROR) << "Native mouse capture stage=local-scroll-return capture_window="
                 << capture_window_number << " target_window=" << target_window_number
                 << " phase=" << phase << " momentum=" << momentum_phase
                 << " timestamp_us=" << timestamp_micros
                 << " delta_x=" << delta_x << " delta_y=" << delta_y
                 << " handled=" << handled << " returns_nil=" << handled;
    }''')
    capture = replace(capture, '''      [NSEvent addGlobalMonitorForEventsMatchingMask:event_mask
                                             handler:global_block];''', '''      [NSEvent addGlobalMonitorForEventsMatchingMask:event_mask
                                             handler:global_block];
  if (NativeCaptureTraceEnabled()) {
    LOG(ERROR) << "Native mouse capture stage=installed capture_window="
               << [GetCaptureWindow() windowNumber]
               << " local_monitor=" << (local_monitor_ != nil)
               << " global_monitor=" << (global_monitor_ != nil)
               << " active_count=" << (g_active_event_tap == this ? 1 : 0);
  }''')
    output[CAPTURE] = capture
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
               : gfx::kNullAcceleratedWidget;''', '''#if BUILDFLAG(IS_MAC)
    // AppKit shells have their own sheet owner, not a Chrome/Alloy browser
    // ModalDialogHost. Looking one up may borrow another focused browser or
    // DCHECK when the exact shell has no document. The external-parent bridge
    // below still validates the actual owner before any consent is displayed.
    const bool has_external_parent_view = parent_view &&
        !views::Widget::GetWidgetForNativeView(parent_view);
#else
    constexpr bool has_external_parent_view = false;
#endif
    auto* parent_host = parent && !has_external_parent_view
        ? CurrentBrowserModalClient()->GetModalDialogHost(parent) : nullptr;
    gfx::AcceleratedWidget parent_widget = parent_host
        ? parent_host->GetAcceleratedWidget() : gfx::kNullAcceleratedWidget;''')
    output[CONSTRAINED] = replace(output[CONSTRAINED], '''  gfx::AcceleratedWidget parent_widget = parent
                                             ? CurrentBrowserModalClient()
                                                   ->GetModalDialogHost(parent)
                                                   ->GetAcceleratedWidget()
                                             : gfx::kNullAcceleratedWidget;''', '''#if BUILDFLAG(IS_MAC)
  // Match BrowserModalHelper: an external AppKit sheet owner must never
  // resolve its ModalDialogHost through an unrelated focused CEF browser.
  const bool has_external_parent_view = parent_view &&
      !views::Widget::GetWidgetForNativeView(parent_view);
#else
  constexpr bool has_external_parent_view = false;
#endif
  auto* parent_host = parent && !has_external_parent_view
      ? CurrentBrowserModalClient()->GetModalDialogHost(parent) : nullptr;
  gfx::AcceleratedWidget parent_widget = parent_host
      ? parent_host->GetAcceleratedWidget() : gfx::kNullAcceleratedWidget;''')
    output[CONSTRAINED] = replace(output[CONSTRAINED], '#if BUILDFLAG(IS_OZONE)', '''#if BUILDFLAG(IS_MAC)
#include "components/remote_cocoa/app_shim/external_window_modal_parent.h"
#endif

#if BUILDFLAG(IS_OZONE)''')
    output[CONSTRAINED] = replace(output[CONSTRAINED], '''  bool requires_positioning = dialog->use_custom_frame();''', '''#if BUILDFLAG(IS_MAC)
  if (parent && !views::Widget::GetWidgetForNativeView(parent_view) &&
      !remote_cocoa::SetExternalWindowModalParent(widget->GetNativeWindow(), parent)) {
    // Unsupported remote/closed native owners must not display orphan consent.
    widget->Close();
  }
#endif

  bool requires_positioning = dialog->use_custom_frame();''')
    output[CONSTRAINED] = replace(output[CONSTRAINED], '''    widget->Show();
    return widget;
  }
};''', '''    if (!widget->IsClosed()) widget->Show();
    return widget;
  }
};''')
    output[CONSTRAINED_BUILD] = replace(output[CONSTRAINED_BUILD], '''  if (use_aura) {''', '''  if (is_mac) {
    deps += [ "//components/remote_cocoa/app_shim" ]
  }

  if (use_aura) {''')
    output[BRIDGE_BUILD] = replace(output[BRIDGE_BUILD], '''    "drag_drop_client.h",''', '''    "drag_drop_client.h",
    "external_window_modal_parent.h",
    "zacro_external_window_modal_parent.inc",''')
    output[BRIDGE] = replace(output[BRIDGE], '''using remote_cocoa::mojom::VisibilityTransition;''', '''#include "components/remote_cocoa/app_shim/external_window_modal_parent.h"
#include "components/remote_cocoa/app_shim/zacro_external_window_modal_parent.inc"

using remote_cocoa::mojom::VisibilityTransition;''')
    output[BRIDGE] = replace(output[BRIDGE], '''  return parent_ && modal_type_ == ui::mojom::ModalType::kWindow;''', '''  return (parent_ || ExternalWindowModalParent(window_)) &&
      modal_type_ == ui::mojom::ModalType::kWindow;''')
    output[BRIDGE] = replace(output[BRIDGE], '''void NativeWidgetNSWindowBridge::ShowAsModalSheet() {
  // -[NSWindow beginSheet''', '''void NativeWidgetNSWindowBridge::ShowAsModalSheet() {
  auto* external_parent = ExternalWindowModalParent(window_);
  NSWindow* parent_window = external_parent ? external_parent.parent : parent_->ns_window();
  if (external_parent && !ExternalWindowModalParentIsReady(window_, parent_window)) {
    CloseWindow();
    return;
  }
  // -[NSWindow beginSheet''')
    output[BRIDGE] = replace(output[BRIDGE], '''  NSWindow* parent_window = parent_->ns_window();
  if (NativeWidgetMacNSWindow* parent_widget_window =
          base::apple::ObjCCast<NativeWidgetMacNSWindow>(parent_window)) {''', '''  if (NativeWidgetMacNSWindow* parent_widget_window = !external_parent
          ? base::apple::ObjCCast<NativeWidgetMacNSWindow>(parent_window) : nil) {''')
    output[BRIDGE] = replace(output[BRIDGE], '''        [parent_window beginSheet:bridge->ns_window()''', '''        if (ExternalWindowModalParent(bridge->ns_window()) &&
            !ExternalWindowModalParentIsReady(bridge->ns_window(), parent_window)) {
          bridge->CloseWindow();
          return;
        }
        [parent_window beginSheet:bridge->ns_window()''')
    output[BRIDGE] = replace(output[BRIDGE], '''  base::WeakPtr<NativeWidgetNSWindowBridge> weak_this = factory_.GetWeakPtr();
  // AppKit's sheet presentation''', '''  // Retain a normal Views parent's original lifetime contract, while the
  // external AppKit shell stays weak even across the posted presentation task.
  NSWindow* __weak external_sheet_parent = external_parent ? parent_window : nil;
  NSWindow* owned_sheet_parent = external_parent ? nil : parent_window;
  const bool has_external_parent = external_parent != nil;
  base::WeakPtr<NativeWidgetNSWindowBridge> weak_this = factory_.GetWeakPtr();
  // AppKit's sheet presentation''')
    output[BRIDGE] = replace(output[BRIDGE], '''        if (ExternalWindowModalParent(bridge->ns_window()) &&
            !ExternalWindowModalParentIsReady(bridge->ns_window(), parent_window)) {''', '''        NSWindow* sheet_parent_window = has_external_parent
            ? external_sheet_parent : owned_sheet_parent;
        if (has_external_parent &&
            !ExternalWindowModalParentIsReady(bridge->ns_window(), sheet_parent_window)) {''')
    output[BRIDGE] = replace(output[BRIDGE], '''        [parent_window beginSheet:bridge->ns_window()''',
        '''        [sheet_parent_window beginSheet:bridge->ns_window()''')
    for path, template in NEW.items(): output[path] = (ROOT / template).read_text()
    return output


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def source_baselines(source):
    originals = {p: "" if p in NEW else subprocess.check_output(["git", "show", "HEAD:" + p], cwd=source, text=True) for p in PATHS}
    cef = source / "cef"
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=cef, text=True).strip()
    if not revision.startswith(CEF_PIN):
        raise SystemExit("Unexpected pinned CEF revision: " + revision)
    for patch_name, path in [("chrome_browser_dialogs_widget.patch", CONSTRAINED),
                             ("mac_print_preview_modal.patch", BRIDGE)]:
        patch = subprocess.check_output(["git", "show", "HEAD:patch/patches/" + patch_name], cwd=cef, text=True)
        selected = ["diff --git " + section for section in patch.split("diff --git ")[1:]
                    if section.splitlines()[0].split()[0] == path]
        if len(selected) != 1:
            raise SystemExit("Pinned CEF native-window patch changed: " + patch_name)
        with tempfile.TemporaryDirectory(prefix="zacro-prompt-baseline-") as temporary:
            root = Path(temporary); target = root / path
            target.parent.mkdir(parents=True); target.write_text(originals[path])
            subprocess.run(["git", "apply", "-p0", "--unsafe-paths", "-"], input=selected[0], cwd=root, text=True, check=True)
            originals[path] = target.read_text()
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
    validate_current(originals, output, {p: (source / p).read_text() if (source / p).exists() else "" for p in PATHS}, prior)
    patch = "".join("".join(difflib.unified_diff(originals[p].splitlines(True), output[p].splitlines(True),
        fromfile="a/" + p if originals[p] else "/dev/null", tofile="b/" + p)) for p in PATHS)
    if args.emit_patch or not args.check:
        (ROOT / "native-management-prompts.patch").write_text(patch)
    if not args.check and not args.emit_patch:
        for path, contents in output.items():
            target = source / path
            target.parent.mkdir(parents=True, exist_ok=True)
            if not target.exists() or target.read_text() != contents:
                temporary = target.with_suffix(target.suffix + ".zacro-tmp")
                temporary.write_text(contents); temporary.replace(target)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps({"revision":PIN,"files":{p:digest(c) for p,c in output.items()}},indent=2) + "\n")
    print(f"{'Emitted' if args.emit_patch else 'Checked' if args.check else 'Applied'} native management prompts for Chromium {revision[:12]}")


if __name__ == "__main__":
    main()
