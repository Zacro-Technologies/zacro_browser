#import <Cocoa/Cocoa.h>
#include <node_api.h>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <unordered_map>

namespace {
struct ScrollSample {
  double x, y, deltaX, deltaY, time;
  uint32_t phase, momentumPhase;
  bool precise, shift, control, option, command, buttons;
};
struct ScrollMonitor {
  napi_env env;
  napi_threadsafe_function callback;
  __weak NSWindow* window;
  id token;
};
std::unordered_map<uint32_t, ScrollMonitor*> monitors;
uint32_t nextMonitor = 1;

NSWindow* Window(napi_env env, napi_value handle) {
  bool buffer = false;
  void* bytes = nullptr;
  size_t length = 0;
  if (napi_is_buffer(env, handle, &buffer) != napi_ok || !buffer ||
      napi_get_buffer_info(env, handle, &bytes, &length) != napi_ok || length < sizeof(void*)) return nil;
  void* address = nullptr;
  std::memcpy(&address, bytes, sizeof(address));
  NSView* view = (__bridge NSView*)address;
  return view.window;
}
void Number(napi_env env, napi_value object, const char* key, double value) {
  napi_value number;
  napi_create_double(env, value, &number);
  napi_set_named_property(env, object, key, number);
}
void Boolean(napi_env env, napi_value object, const char* key, bool value) {
  napi_value boolean;
  napi_get_boolean(env, value, &boolean);
  napi_set_named_property(env, object, key, boolean);
}
void Deliver(napi_env env, napi_value callback, void*, void* data) {
  auto* sample = static_cast<ScrollSample*>(data);
  if (env && callback) {
    napi_value object, global, ignored;
    napi_create_object(env, &object);
    Number(env, object, "x", sample->x);
    Number(env, object, "y", sample->y);
    Number(env, object, "deltaX", sample->deltaX);
    Number(env, object, "deltaY", sample->deltaY);
    Number(env, object, "time", sample->time);
    Number(env, object, "phase", sample->phase);
    Number(env, object, "momentumPhase", sample->momentumPhase);
    Boolean(env, object, "precise", sample->precise);
    Boolean(env, object, "shiftKey", sample->shift);
    Boolean(env, object, "ctrlKey", sample->control);
    Boolean(env, object, "altKey", sample->option);
    Boolean(env, object, "metaKey", sample->command);
    Boolean(env, object, "buttons", sample->buttons);
    napi_get_global(env, &global);
    napi_call_function(env, global, callback, 1, &object, &ignored);
  }
  delete sample;
}
void Finalize(napi_env, void* data, void*) {
  delete static_cast<ScrollMonitor*>(data);
}
void Stop(uint32_t id) {
  const auto found = monitors.find(id);
  if (found == monitors.end()) return;
  ScrollMonitor* monitor = found->second;
  monitors.erase(found);
  if (monitor->token) [NSEvent removeMonitor:monitor->token];
  monitor->token = nil;
  napi_release_threadsafe_function(monitor->callback, napi_tsfn_abort);
}
void Cleanup(void* data) {
  auto env = static_cast<napi_env>(data);
  for (auto it = monitors.begin(); it != monitors.end();) {
    const auto id = it->first;
    const bool same = it->second->env == env;
    ++it;
    if (same) Stop(id);
  }
}
napi_value MonitorScroll(napi_env env, napi_callback_info info) {
  napi_value args[2], result;
  size_t count = 2;
  napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
  napi_create_uint32(env, 0, &result);
  if (count != 2 || ![NSThread isMainThread]) return result;
  NSWindow* window = Window(env, args[0]);
  napi_valuetype type;
  if (!window || napi_typeof(env, args[1], &type) != napi_ok || type != napi_function) return result;
  auto* monitor = new ScrollMonitor{env, nullptr, window, nil};
  napi_value name;
  napi_create_string_utf8(env, "Zacro native scroll phases", NAPI_AUTO_LENGTH, &name);
  if (napi_create_threadsafe_function(env, args[1], nullptr, name, 0, 1, monitor, Finalize,
                                    nullptr, Deliver, &monitor->callback) != napi_ok) {
    delete monitor;
    return result;
  }
  napi_unref_threadsafe_function(env, monitor->callback);
  monitor->token = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
      handler:^NSEvent*(NSEvent* event) {
        NSWindow* target = monitor->window;
        if (!target || event.window != target) return event;
        NSView* content = target.contentView;
        const NSPoint point = [content convertPoint:event.locationInWindow fromView:nil];
        const NSEventModifierFlags modifiers = event.modifierFlags;
        auto* sample = new ScrollSample{
            point.x, content.isFlipped ? point.y : content.bounds.size.height - point.y,
            -event.scrollingDeltaX, -event.scrollingDeltaY, event.timestamp * 1000,
            static_cast<uint32_t>(event.phase), static_cast<uint32_t>(event.momentumPhase),
            static_cast<bool>(event.hasPreciseScrollingDeltas),
            static_cast<bool>(modifiers & NSEventModifierFlagShift),
            static_cast<bool>(modifiers & NSEventModifierFlagControl),
            static_cast<bool>(modifiers & NSEventModifierFlagOption),
            static_cast<bool>(modifiers & NSEventModifierFlagCommand),
            static_cast<bool>(NSEvent.pressedMouseButtons)};
        // The complete ordered stream owns Space navigation. DOM wheel events
        // remain available to ordinary scrolling, but never add duplicate travel.
        if (napi_call_threadsafe_function(monitor->callback, sample, napi_tsfn_nonblocking) != napi_ok)
          delete sample;
        return event;
      }];
  const uint32_t id = nextMonitor++;
  monitors.emplace(id, monitor);
  napi_create_uint32(env, id, &result);
  return result;
}
napi_value StopScroll(napi_env env, napi_callback_info info) {
  napi_value argument, result;
  size_t count = 1;
  napi_get_cb_info(env, info, &count, &argument, nullptr, nullptr);
  uint32_t id = 0;
  if (count && napi_get_value_uint32(env, argument, &id) == napi_ok) Stop(id);
  napi_get_undefined(env, &result);
  return result;
}
bool SetEffects(NSView* view, double strength) {
  bool changed = false;
  if ([view isKindOfClass:NSVisualEffectView.class]) {
    view.alphaValue = strength;
    changed = true;
  }
  for (NSView* child in view.subviews) changed = SetEffects(child, strength) || changed;
  return changed;
}
napi_value SetBlurStrength(napi_env env, napi_callback_info info) {
  napi_value args[2], result;
  size_t count = 2;
  napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
  double strength = 0;
  NSWindow* window = count == 2 ? Window(env, args[0]) : nil;
  const bool changed = window && [NSThread isMainThread] &&
      napi_get_value_double(env, args[1], &strength) == napi_ok && std::isfinite(strength) &&
      SetEffects(window.contentView, std::fmax(0, std::fmin(1, strength)));
  napi_get_boolean(env, changed, &result);
  return result;
}
napi_value PerformHaptic(napi_env env, napi_callback_info info) {
  napi_value argument, result;
  size_t count = 1;
  napi_get_cb_info(env, info, &count, &argument, nullptr, nullptr);
  uint32_t pattern = 0;
  if ([NSThread isMainThread] && count && napi_get_value_uint32(env, argument, &pattern) == napi_ok && pattern <= 1) {
    [NSHapticFeedbackManager.defaultPerformer
        performFeedbackPattern:pattern == 0 ? NSHapticFeedbackPatternAlignment : NSHapticFeedbackPatternLevelChange
        performanceTime:NSHapticFeedbackPerformanceTimeNow];
  }
  napi_get_undefined(env, &result);
  return result;
}
napi_value Initialize(napi_env env, napi_value exports) {
  const napi_property_descriptor methods[] = {
      {"monitorScroll", nullptr, MonitorScroll, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"stopScroll", nullptr, StopScroll, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"setBlurStrength", nullptr, SetBlurStrength, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"performHaptic", nullptr, PerformHaptic, nullptr, nullptr, nullptr, napi_default, nullptr}};
  napi_define_properties(env, exports, sizeof(methods) / sizeof(methods[0]), methods);
  napi_add_env_cleanup_hook(env, Cleanup, env);
  return exports;
}
}  // namespace
NAPI_MODULE(NODE_GYP_MODULE_NAME, Initialize)
