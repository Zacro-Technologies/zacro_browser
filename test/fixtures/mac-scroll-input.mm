// Test-only AppKit input source. Dispatches NSEvents through the owned application's
// normal AppKit sendEvent path; it does not emit Electron events or bypass the
// production local monitor. Never included in the packaged browser.
#import <Cocoa/Cocoa.h>
#include <node_api.h>
#include <cstring>
#include <vector>

@interface ZacroTestScrollEvent : NSEvent
@property NSWindow* targetWindow;
@property NSEvent* backingEvent;
@property NSPoint point;
@property double dx;
@property double dy;
@property double eventTime;
@property NSEventPhase contactPhase;
@property NSEventPhase inertialPhase;
@end
@implementation ZacroTestScrollEvent
- (NSEventType)type { return NSEventTypeScrollWheel; }
- (NSWindow*)window { return self.targetWindow; }
- (NSInteger)windowNumber { return self.targetWindow.windowNumber; }
- (NSPoint)locationInWindow { return self.point; }
- (CGFloat)scrollingDeltaX { return self.dx; }
- (CGFloat)scrollingDeltaY { return self.dy; }
- (CGFloat)deltaX { return self.dx; }
- (CGFloat)deltaY { return self.dy; }
- (CGFloat)deltaZ { return 0; }
- (BOOL)hasPreciseScrollingDeltas { return YES; }
- (NSEventPhase)phase { return self.contactPhase; }
- (NSEventPhase)momentumPhase { return self.inertialPhase; }
- (NSTimeInterval)timestamp { return self.eventTime; }
- (NSEventModifierFlags)modifierFlags { return 0; }
- (BOOL)isDirectionInvertedFromDevice { return NO; }
- (CGEventRef)CGEvent { return self.backingEvent.CGEvent; }
@end

namespace {
NSWindow* Window(napi_env env, napi_value handle) {
  void* bytes;
  size_t length;
  napi_get_buffer_info(env, handle, &bytes, &length);
  void* address;
  std::memcpy(&address, bytes, sizeof(address));
  return ((__bridge NSView*)address).window;
}
double Number(napi_env env, napi_value object, const char* key, double fallback = 0) {
  napi_value value;
  double result;
  return napi_get_named_property(env, object, key, &value) == napi_ok &&
                 napi_get_value_double(env, value, &result) == napi_ok
             ? result
             : fallback;
}
napi_value PostScroll(napi_env env, napi_callback_info info) {
  napi_value args[2], result;
  size_t count = 2;
  napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
  NSWindow* window = Window(env, args[0]);
  NSView* content = window.contentView;
  ZacroTestScrollEvent* event = [ZacroTestScrollEvent new];
  event.targetWindow = window;
  event.dx = -Number(env, args[1], "deltaX");
  event.dy = -Number(env, args[1], "deltaY");
  const CGFloat x = Number(env, args[1], "x");
  const CGFloat y = Number(env, args[1], "y");
  event.point = [content convertPoint:NSMakePoint(x, content.isFlipped ? y : content.bounds.size.height - y)
                              toView:nil];
  event.eventTime = Number(env, args[1], "time", NSProcessInfo.processInfo.systemUptime * 1000) / 1000;
  event.contactPhase = static_cast<NSEventPhase>(static_cast<NSUInteger>(Number(env, args[1], "phase")));
  event.inertialPhase = static_cast<NSEventPhase>(static_cast<NSUInteger>(Number(env, args[1], "momentumPhase")));
  CGEventRef cg = CGEventCreateScrollWheelEvent(nullptr, kCGScrollEventUnitPixel, 2,
                                               static_cast<int32_t>(event.dy), static_cast<int32_t>(event.dx));
  event.backingEvent = [NSEvent eventWithCGEvent:cg];
  CFRelease(cg);
  [NSApp sendEvent:event];
  napi_get_undefined(env, &result);
  return result;
}
napi_value PostMouse(napi_env env, napi_callback_info info) {
  napi_value args[2], result;
  size_t count = 2;
  napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
  NSWindow* window = Window(env, args[0]);
  NSView* content = window.contentView;
  const CGFloat x = Number(env, args[1], "x");
  const CGFloat y = Number(env, args[1], "y");
  const NSPoint point = [content convertPoint:NSMakePoint(x, content.isFlipped ? y : content.bounds.size.height - y)
                                     toView:nil];
  static NSInteger eventNumber = 1;
  NSEvent* event = [NSEvent mouseEventWithType:static_cast<NSEventType>(static_cast<NSUInteger>(Number(env, args[1], "type")))
                                    location:point
                               modifierFlags:0
                                   timestamp:NSProcessInfo.processInfo.systemUptime
                                windowNumber:window.windowNumber
                                     context:nil
                                 eventNumber:eventNumber++
                                  clickCount:1
                                    pressure:1];
  // AppKit routes the drag across sibling WebContentsViews in this owned window.
  // No global mouse events or Accessibility permission are involved.
  [NSApp postEvent:event atStart:NO];
  napi_get_undefined(env, &result);
  return result;
}
void ReadEffects(NSView* view, std::vector<double>& values) {
  if ([view isKindOfClass:NSVisualEffectView.class]) values.push_back(view.alphaValue);
  for (NSView* child in view.subviews) ReadEffects(child, values);
}
napi_value ReadEffectAlphas(napi_env env, napi_callback_info info) {
  napi_value handle, result;
  size_t count = 1;
  napi_get_cb_info(env, info, &count, &handle, nullptr, nullptr);
  std::vector<double> values;
  ReadEffects(Window(env, handle).contentView, values);
  napi_create_array_with_length(env, values.size(), &result);
  for (size_t index = 0; index < values.size(); index++) {
    napi_value value;
    napi_create_double(env, values[index], &value);
    napi_set_element(env, result, index, value);
  }
  return result;
}
napi_value Initialize(napi_env env, napi_value exports) {
  napi_value method;
  napi_create_function(env, "postMouse", NAPI_AUTO_LENGTH, PostMouse, nullptr, &method);
  napi_set_named_property(env, exports, "postMouse", method);
  napi_create_function(env, "postScroll", NAPI_AUTO_LENGTH, PostScroll, nullptr, &method);
  napi_set_named_property(env, exports, "postScroll", method);
  napi_create_function(env, "readEffectAlphas", NAPI_AUTO_LENGTH, ReadEffectAlphas, nullptr, &method);
  napi_set_named_property(env, exports, "readEffectAlphas", method);
  return exports;
}
}  // namespace
NAPI_MODULE(NODE_GYP_MODULE_NAME, Initialize)
