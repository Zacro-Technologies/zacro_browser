// Exact pinned Chromium + accepted CEF methods; transformed by the actual adapter in the lifetime fixture.
using remote_cocoa::mojom::VisibilityTransition;

void NativeWidgetNSWindowBridge::CloseWindow() {
  if (fullscreen_controller_.HasDeferredWindowClose())
    return;

  // Make a local variable of the window on the stack so that the block can
  // capture a reference to it.
  NSWindow* window = ns_window();

  if (IsWindowModalSheet() && window.sheet) {
    // Sheets can't be closed normally. This starts the sheet closing. Once the
    // sheet has finished animating, it will call the end-sheet block defined
    // when the sheet was displayed. Note it still needs to be asynchronous,
    // since code calling Widget::Close() doesn't expect things to be deleted
    // upon return. Ensure |window| is retained by a block. Note in some cases
    // during teardown, [window sheetParent] may be nil.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(^{
          [NSApp endSheet:window];
        }));
    return;
  }

  // For other modal types, animate the close.
  if (ShouldRunCustomAnimationFor(VisibilityTransition::kHide) &&
      [ns_window() isVisible]) {
    [ViewsNSWindowCloseAnimator closeWindowWithAnimation:window];
    return;
  }

  // If the window wants to be visible and has a parent, then the parent may
  // order it back in (in the period between orderOut: and close).
  wants_to_be_visible_ = false;

  // Widget::Close() ensures [Non]ClientView::CanClose() returns true, so there
  // is no need to call the NSWindow or its delegate's -windowShouldClose:
  // implementation in the manner of -[NSWindow performClose:]. But,
  // like -performClose:, first remove the window from AppKit's display
  // list to avoid crashes like http://crbug.com/156101.
  [window orderOut:nil];

  // Defer closing windows until after fullscreen transitions complete.
  fullscreen_controller_.OnWindowWantsToClose();
  if (fullscreen_controller_.HasDeferredWindowClose())
    return;

  // Many tests assume that base::RunLoop().RunUntilIdle() is always sufficient
  // to execute a close. However, in rare cases, -performSelector:..afterDelay:0
  // does not do this. So post a regular task.
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
                                                              base::BindOnce(^{
                                                                [window close];
                                                              }));
}

bool NativeWidgetNSWindowBridge::IsWindowModalSheet() const {
  return parent_ && modal_type_ == ui::mojom::ModalType::kWindow;
}

void NativeWidgetNSWindowBridge::ShowAsModalSheet() {
  // -[NSWindow beginSheet:completionHandler:] will block the UI thread while
  // the animation runs. So that it doesn't animate a fully transparent window,
  // first wait for a frame. The first step is to pretend that the window is
  // already visible.
  window_visible_ = true;
  host_->OnVisibilityChanged(window_visible_);

  NSWindow* parent_window = parent_->ns_window();
  if (NativeWidgetMacNSWindow* parent_widget_window =
          base::apple::ObjCCast<NativeWidgetMacNSWindow>(parent_window)) {
    parent_window = [parent_widget_window preferredSheetParent];
  }
  DCHECK(parent_window);
  NSWindow* __weak weak_window = window_;

  // Don't show a sheet twice. If a sheet is shown twice but endSheet: only
  // once it will leave a dangling blank sheet. This happened when the browser
  // is restored from minimization.
  if (parent_window.attachedSheet == window_) {
    return;
  }

  base::WeakPtr<NativeWidgetNSWindowBridge> weak_this = factory_.GetWeakPtr();
  // AppKit's sheet presentation animation runs a nested run loop. We post
  // this task to run the animation asynchronously for two reasons:
  // 1. For remote cocoa (out-of-process), it prevents a deadlock by allowing
  //    the sizing message to be processed before entering the nested run loop.
  // 2. For in-process windows, it prevents Use-After-Free (UAF) bugs and
  //    undefined behavior when returning from the nested run loop if the
  //    window was closed during presentation, causing its bridge (this) to be
  //    destroyed.
  // https://crbug.com/40781530, https://crbug.com/517040438,
  // https://crbug.com/518006007
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{
        NativeWidgetNSWindowBridge* bridge = weak_this.get();
        if (!bridge || !bridge->wants_to_be_visible_) {
          return;
        }
        [parent_window beginSheet:bridge->ns_window()
                completionHandler:^(NSModalResponse return_code) {
                  // This class, NativeWidgetNSWindowBridge, clears the window's
                  // delegate as an indication of its death, in which case this
                  // completion handler will no-op. This is necessary to handle
                  // AppKit invoking this selector via a posted task. See
                  // https://crbug.com/41393772
                  NSWindow* window = weak_window;
                  if (!window.delegate) {
                    return;
                  }
                  // Make sure to mark ourselves as not wanting to be visible.
                  // Otherwise if during the orderOut call our parent becomes
                  // the key window, it would try to show us as a new modal
                  // sheet.
                  if (weak_this) {
                    weak_this->wants_to_be_visible_ = false;
                  }
                  [window orderOut:nil];
                  if (weak_this) {
                    weak_this->OnWindowWillClose();
                  }
                }];
      }));
}

