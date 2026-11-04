// CefSwift — CEFApplication implementation.
//
// Mirrors the official cefsimple_capi sample (tests/cefsimple_capi/
// cefsimple_mac.m): sendEvent: wraps the handlingSendEvent flag, and
// terminate: routes through a registered handler so quitting closes CEF
// browsers cleanly before the application exits.

#import "CCefAppKit.h"
#import <objc/runtime.h>

#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>

static CEFApplicationTerminateHandler g_terminate_handler = NULL;

// Diagnostic interception of public NSEvent monitor registration. It is never
// installed in ordinary runs and never changes an event, mask, or monitor token.
typedef NSEvent* _Nullable (^ZacroLocalEventHandler)(NSEvent*);
typedef id _Nullable (*ZacroAddLocalMonitorIMP)(id, SEL, NSEventMask,
                                               ZacroLocalEventHandler);
typedef void (*ZacroRemoveMonitorIMP)(id, SEL, id);
static ZacroAddLocalMonitorIMP g_original_add_local_monitor = NULL;
static ZacroRemoveMonitorIMP g_original_remove_monitor = NULL;
static _Atomic(uint64_t) g_next_monitor_id = 1;
static BOOL g_logged_scroll_stack = NO;

static BOOL ZacroEventMonitorTraceEnabled(void) {
  static BOOL enabled;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    enabled =
        [NSProcessInfo.processInfo.arguments containsObject:@"--engine-acceptance"] &&
        [NSProcessInfo.processInfo.arguments
            containsObject:@"--native-integration-acceptance"] &&
        [NSProcessInfo.processInfo.environment[@"ZACRO_NATIVE_EVENT_MONITOR_TRACE"]
            isEqualToString:@"1"];
  });
  return enabled;
}

static void ZacroInstallEventMonitorTrace(void) {
  if (!ZacroEventMonitorTraceEnabled()) return;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    SEL add_selector = @selector(addLocalMonitorForEventsMatchingMask:handler:);
    Method add_method = class_getClassMethod(NSEvent.class, add_selector);
    if (!add_method) {
      fputs("Native event monitor stage=installation-unavailable\n", stderr);
      return;
    }
    g_original_add_local_monitor =
        (ZacroAddLocalMonitorIMP)method_getImplementation(add_method);
    IMP replacement = imp_implementationWithBlock(
        ^id(id receiver, NSEventMask mask, ZacroLocalEventHandler handler) {
          if (!(mask & NSEventMaskScrollWheel) || !handler) {
            return g_original_add_local_monitor(receiver, add_selector, mask, handler);
          }
          const uint64_t registration_id = atomic_fetch_add_explicit(
              &g_next_monitor_id, 1, memory_order_relaxed);
          ZacroLocalEventHandler original_handler = [handler copy];
          ZacroLocalEventHandler wrapped_handler = ^NSEvent*(NSEvent* event) {
            if (event.type != NSEventTypeScrollWheel) return original_handler(event);
            // Snapshot only documented scroll fields. The original handler may
            // remove this monitor, destroy its owner, or return another event.
            const uint64_t monitor_id = registration_id;
            ZacroLocalEventHandler callback = original_handler;
            const NSInteger window_number = event.windowNumber;
            const NSUInteger phase = event.phase;
            const NSUInteger momentum = event.momentumPhase;
            const int64_t timestamp_micros = (int64_t)(event.timestamp * 1000000.0);
            const CGFloat delta_x = event.scrollingDeltaX;
            const CGFloat delta_y = event.scrollingDeltaY;
            const void* input_identity = (__bridge const void*)event;
            fprintf(stderr,
                    "Native event monitor stage=scroll-enter id=%llu mask=%llu "
                    "window=%ld type=%lu phase=%lu momentum=%lu timestamp_us=%lld "
                    "delta_x=%.9g delta_y=%.9g\n",
                    (unsigned long long)monitor_id, (unsigned long long)mask,
                    (long)window_number, (unsigned long)NSEventTypeScrollWheel,
                    (unsigned long)phase, (unsigned long)momentum,
                    (long long)timestamp_micros, (double)delta_x, (double)delta_y);
            NSEvent* result = callback(event);
            const void* result_identity = (__bridge const void*)result;
            fprintf(stderr,
                    "Native event monitor stage=scroll-return id=%llu window=%ld "
                    "phase=%lu timestamp_us=%lld nil=%d same=%d replaced=%d\n",
                    (unsigned long long)monitor_id, (long)window_number,
                    (unsigned long)phase, (long long)timestamp_micros, result == nil,
                    result != nil && result_identity == input_identity,
                    result != nil && result_identity != input_identity);
            return result;
          };
          id token = g_original_add_local_monitor(receiver, add_selector, mask,
                                                 wrapped_handler);
          fprintf(stderr,
                  "Native event monitor stage=registered id=%llu mask=%llu token=%p\n",
                  (unsigned long long)registration_id, (unsigned long long)mask,
                  (__bridge void*)token);
          NSArray<NSString*>* frames = NSThread.callStackSymbols;
          const NSUInteger count = MIN(frames.count, 12);
          for (NSUInteger index = 0; index < count; ++index) {
            NSString* frame = frames[index];
            if (frame.length > 500) frame = [frame substringToIndex:500];
            fprintf(stderr, "Native event monitor stage=registration-frame id=%llu "
                            "index=%lu frame=%s\n",
                    (unsigned long long)registration_id, (unsigned long)index,
                    frame.UTF8String ?: "");
          }
          return token;
        });
    if (!replacement) {
      fputs("Native event monitor stage=installation-unavailable\n", stderr);
      return;
    }
    method_setImplementation(add_method, replacement);

    // Observe removal without retaining, substituting, or indexing opaque
    // monitor tokens. Pointer identity correlates with registration above.
    SEL remove_selector = @selector(removeMonitor:);
    Method remove_method = class_getClassMethod(NSEvent.class, remove_selector);
    if (remove_method) {
      g_original_remove_monitor =
          (ZacroRemoveMonitorIMP)method_getImplementation(remove_method);
      IMP remove_replacement = imp_implementationWithBlock(^(id receiver, id token) {
        fprintf(stderr, "Native event monitor stage=remove token=%p\n",
                (__bridge void*)token);
        g_original_remove_monitor(receiver, remove_selector, token);
      });
      if (remove_replacement) method_setImplementation(remove_method, remove_replacement);
    }
    fputs("Native event monitor stage=installed\n", stderr);
  });
}

@implementation CEFApplication {
  BOOL _handlingSendEvent;
}

+ (void)install {
  NSApplication* app = [CEFApplication sharedApplication];
  NSCAssert([app isKindOfClass:[CEFApplication class]],
            @"NSApp is %@, not CEFApplication. CEFApplication.install (or "
            @"CefRuntime.initialize) must run before anything else touches "
            @"NSApp — e.g. before NSApplicationMain or SwiftUI's App.main().",
            [app className]);
  (void)app;
  ZacroInstallEventMonitorTrace();
}

+ (void)setTerminateHandler:(nullable CEFApplicationTerminateHandler)handler {
  g_terminate_handler = handler;
}

- (BOOL)isHandlingSendEvent {
  return _handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent*)event {
  BOOL previous = _handlingSendEvent;
  _handlingSendEvent = YES;
  const BOOL trace_scroll = ZacroEventMonitorTraceEnabled() &&
      event.type == NSEventTypeScrollWheel;
  const NSInteger trace_window = trace_scroll ? event.windowNumber : 0;
  const NSUInteger trace_phase = trace_scroll ? event.phase : 0;
  const int64_t trace_timestamp = trace_scroll
      ? (int64_t)(event.timestamp * 1000000.0) : 0;
  if (trace_scroll) {
    fprintf(stderr, "Native event monitor stage=send-enter window=%ld phase=%lu "
                    "timestamp_us=%lld previous_handling=%d\n",
            (long)trace_window, (unsigned long)trace_phase,
            (long long)trace_timestamp, previous);
    if (!g_logged_scroll_stack) {
      g_logged_scroll_stack = YES;
      NSArray<NSString*>* frames = NSThread.callStackSymbols;
      const NSUInteger count = MIN(frames.count, 32);
      for (NSUInteger index = 0; index < count; ++index) {
        NSString* frame = frames[index];
        if (frame.length > 500) frame = [frame substringToIndex:500];
        fprintf(stderr, "Native event monitor stage=first-send-frame index=%lu "
                        "frame=%s\n", (unsigned long)index,
                frame.UTF8String ?: "");
      }
    }
  }
  [super sendEvent:event];
  _handlingSendEvent = previous;
  if (trace_scroll) {
    fprintf(stderr, "Native event monitor stage=send-exit window=%ld phase=%lu "
                    "timestamp_us=%lld restored_handling=%d\n",
            (long)trace_window, (unsigned long)trace_phase,
            (long long)trace_timestamp, _handlingSendEvent);
  }
}

- (void)terminate:(id)sender {
  if (g_terminate_handler != NULL && !g_terminate_handler()) {
    // The handler deferred termination (e.g. CEF browsers are still closing).
    // It is responsible for calling -terminate: again when ready.
    return;
  }
  [super terminate:sender];
}

@end
