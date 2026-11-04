// Included only by native_widget_ns_window_bridge.mm, after its native headers.
// An associated marker survives a weak owner's destruction: a later Show must
// close the original widget, never turn its consent UI into an unowned window.
@interface ZacroExternalWindowModalParent : NSObject
@property(nonatomic, weak) NSWindow* parent;
@property(nonatomic) BOOL closed;
@property(nonatomic, strong) id closeObserver;
@end

@implementation ZacroExternalWindowModalParent
@synthesize parent = _parent;
@synthesize closed = _closed;
@synthesize closeObserver = _closeObserver;

- (void)dealloc {
  if (_closeObserver) {
    [[NSNotificationCenter defaultCenter] removeObserver:_closeObserver];
  }
}
@end

namespace remote_cocoa {
namespace {
const char kExternalWindowModalParentKey = 0;

ZacroExternalWindowModalParent* ExternalWindowModalParent(NSWindow* child) {
  return objc_getAssociatedObject(child, &kExternalWindowModalParentKey);
}

bool ExternalWindowModalParentIsReady(NSWindow* child, NSWindow* parent) {
  auto* state = ExternalWindowModalParent(child);
  return state && !state.closed && parent && state.parent == parent &&
      [NSApp windowWithWindowNumber:parent.windowNumber] == parent &&
      parent.visible && !parent.miniaturized &&
      (!parent.attachedSheet || parent.attachedSheet == child) &&
      (!NSApp.modalWindow || NSApp.modalWindow == child);
}
}  // namespace

bool SetExternalWindowModalParent(gfx::NativeWindow native_child,
                                  gfx::NativeWindow native_parent) {
  DCHECK([NSThread isMainThread]);
  NSWindow* child = native_child.GetNativeNSWindow();
  NSWindow* parent = native_parent.GetNativeNSWindow();
  auto* bridge = NativeWidgetNSWindowBridge::GetFromNSWindow(child);
  if (!child || !parent || child == parent || !bridge || bridge->parent() ||
      NativeWidgetNSWindowBridge::GetFromNSWindow(parent) ||
      bridge->modal_type() != ui::mojom::ModalType::kWindow || child.visible ||
      child.parentWindow || child.sheetParent || ExternalWindowModalParent(child)) {
    return false;
  }
  auto* state = [[ZacroExternalWindowModalParent alloc] init];
  state.parent = parent;
  objc_setAssociatedObject(child, &kExternalWindowModalParentKey, state,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if (!ExternalWindowModalParentIsReady(child, parent)) {
    state.closed = YES;
    return false;
  }
  __weak ZacroExternalWindowModalParent* weak_state = state;
  __weak NSWindow* weak_child = child;
  // Do not pass the parent as the notification filter: retain only its weak
  // identity, never keep an external browser shell alive through the observer.
  state.closeObserver = [[NSNotificationCenter defaultCenter]
      addObserverForName:NSWindowWillCloseNotification object:nil queue:nil
      usingBlock:^(NSNotification* notification) {
        auto* current = weak_state;
        if (!current || notification.object != current.parent) return;
        current.closed = YES;
        if (auto* live = NativeWidgetNSWindowBridge::GetFromNSWindow(weak_child)) {
          live->CloseWindow();
        }
      }];
  return true;
}
}  // namespace remote_cocoa
