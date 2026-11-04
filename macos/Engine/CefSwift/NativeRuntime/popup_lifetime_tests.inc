// Harness for the exact production OnNativeBrowserDidClose body.
// This proves method ordering/reentrancy, not actual Chromium widget behavior.
#include <functional>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>

class ExtensionPopup;
struct Probe {
  ExtensionPopup* popup = nullptr;
  int views = 0, hosts = 0, completions = 0, closes = 0, destructions = 0;
  bool nested = false, deferred = false;
  bool viewBeforeHost = true, hostBeforeBrowser = true, ownerDetached = true;
  std::function<void()> duringView, duringHost, duringCompletion;
};
struct TabStripModel {
  int removals = 0;
  void RemoveObserver(ExtensionPopup*) { ++removals; }
};
struct BrowserWindowInterface {
  bool alive = true;
  TabStripModel tabs;
  TabStripModel* GetTabStripModel() { return &tabs; }
};
struct Observation {
  bool observing = true;
  void Reset() { observing = false; }
};
struct Subscription {
  bool subscribed = false;
};
struct Callback {
  std::function<void(std::nullptr_t)> function;
  Callback() = default;
  explicit Callback(std::function<void(std::nullptr_t)> value) : function(std::move(value)) {}
  Callback(Callback&& other) : function(std::exchange(other.function, {})) {}
  Callback& operator=(Callback&& other) { function = std::exchange(other.function, {}); return *this; }
  explicit operator bool() const { return bool(function); }
  void Run(std::nullptr_t value) { auto moved = std::exchange(function, {}); moved(value); }
};
struct WeakState { ExtensionPopup* pointer; int generation = 0; };
struct Weak {
  std::shared_ptr<WeakState> state;
  int generation;
  explicit operator bool() const { return state->pointer && state->generation == generation; }
  ExtensionPopup* operator->() const { return state->pointer; }
};
struct WeakFactory {
  std::shared_ptr<WeakState> state;
  explicit WeakFactory(ExtensionPopup* pointer) : state(std::make_shared<WeakState>(WeakState{pointer})) {}
  void InvalidateWeakPtrs() { ++state->generation; }
  Weak GetWeakPtr() { return {state, state->generation}; }
};
struct View {
  Probe& probe;
  ~View() { ++probe.views; if (probe.duringView) { auto action = std::move(probe.duringView); action(); } }
};
struct RawView {
  View* pointer = nullptr;
  explicit operator bool() const { return pointer != nullptr; }
  View* ExtractAsDangling() { return std::exchange(pointer, nullptr); }
};
struct Host {
  Probe& probe;
  BrowserWindowInterface& browser;
  Host(Probe& p, BrowserWindowInterface& b) : probe(p), browser(b) {}
  ~Host();
};
class ExtensionPopup {
 public:
  Probe& probe;
  std::unique_ptr<int> native_anchor_;
  Subscription native_browser_close_subscription_{true};
  WeakFactory deferred_close_weak_ptr_factory_{this};
  bool contentsObserved = true;
  Observation anchor_widget_observation_, extension_registry_observation_, security_dialog_tracker_observation_;
  std::unique_ptr<int> withheld_from_view_ = std::make_unique<int>(1);
  BrowserWindowInterface* browser_;
  Callback shown_callback_;
  RawView extension_view_;
  std::unique_ptr<Host> host_;
  ExtensionPopup(Probe& p, BrowserWindowInterface& browser, bool prepared = true)
      : probe(p), native_anchor_(prepared ? std::make_unique<int>(1) : nullptr), browser_(&browser) {
    probe.popup = this;
    extension_view_.pointer = new View{p};
    host_ = std::make_unique<Host>(p, browser);
    shown_callback_ = Callback([&p](std::nullptr_t) {
      ++p.completions;
      if (p.duringCompletion) { auto action = std::move(p.duringCompletion); action(); }
    });
  }
  ~ExtensionPopup() {
    probe.popup = nullptr;
    ++probe.destructions;
    native_browser_close_subscription_ = {};
    deferred_close_weak_ptr_factory_.state->pointer = nullptr;
    if (shown_callback_) std::move(shown_callback_).Run(nullptr);
    delete extension_view_.ExtractAsDangling();
    host_.reset();
  }
  void Observe(std::nullptr_t) { contentsObserved = false; }
  std::unique_ptr<View> RemoveChildViewT(View* view) { return std::unique_ptr<View>(view); }
  void CloseDeferredIfNecessary() { ++probe.closes; probe.deferred = probe.nested; }
  void OnNativeBrowserDidClose(BrowserWindowInterface* browser);
};
Host::~Host() {
  ++probe.hosts;
  probe.viewBeforeHost = probe.viewBeforeHost && probe.views == 1;
  probe.hostBeforeBrowser = probe.hostBeforeBrowser && browser.alive;
  probe.ownerDetached = probe.ownerDetached && (!probe.popup || probe.popup->browser_ == nullptr);
  if (probe.duringHost) { auto action = std::move(probe.duringHost); action(); }
}

// EXACT_PRODUCTION_METHOD

void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
void checkDestroyed(const Probe& probe) {
  require(probe.views == 1 && probe.hosts == 1 && probe.completions == 1 && probe.destructions == 1,
          "payload/completion/destruction must occur exactly once");
  require(probe.viewBeforeHost && probe.hostBeforeBrowser, "payload must die in order before Browser");
}
int main() {
  try {
    int checks = 0;
    {
      BrowserWindowInterface browser, unrelated; Probe p;
      auto* popup = new ExtensionPopup(p, browser);
      popup->OnNativeBrowserDidClose(&unrelated);
      require(p.views == 0 && p.hosts == 0 && p.closes == 0 && popup->browser_ == &browser,
              "foreign Browser must not close popup");
      popup->OnNativeBrowserDidClose(&browser);
      require(!popup->contentsObserved && !popup->native_browser_close_subscription_.subscribed &&
              !popup->anchor_widget_observation_.observing && !popup->extension_registry_observation_.observing &&
              !popup->security_dialog_tracker_observation_.observing && !popup->withheld_from_view_ &&
              !popup->browser_ && browser.tabs.removals == 1 && p.ownerDetached,
              "all ownership and observers must revoke before host teardown");
      popup->OnNativeBrowserDidClose(&browser);
      require(p.closes == 1, "detached repeated callback must be inert");
      browser.alive = false; delete popup; checkDestroyed(p); checks += 3;
    }
    {
      BrowserWindowInterface browser; Probe p;
      auto* popup = new ExtensionPopup(p, browser, false);
      popup->OnNativeBrowserDidClose(&browser);
      require(p.views == 0 && p.hosts == 0 && p.closes == 0 && popup->browser_ == &browser,
              "ordinary unprepared popup must retain original path");
      delete popup; checkDestroyed(p); ++checks;
    }
    {
      BrowserWindowInterface browser; Probe p; p.nested = true;
      auto* popup = new ExtensionPopup(p, browser);
      // A veto does not dispatch BrowserDidClose at all; payload remains live.
      require(p.views == 0 && p.hosts == 0 && popup->host_, "veto must preserve popup host");
      popup->OnNativeBrowserDidClose(&browser);
      require(p.views == 1 && p.hosts == 1 && p.deferred && p.destructions == 0,
              "accepted close must release payload before deferred Widget destruction");
      browser.alive = false; delete popup; checkDestroyed(p); checks += 2;
    }
    for (int phase = 0; phase != 3; ++phase) {
      BrowserWindowInterface browser; Probe p;
      auto* popup = new ExtensionPopup(p, browser);
      auto destroy = [&p] { delete p.popup; };
      if (phase == 0) p.duringView = destroy;
      else if (phase == 1) p.duringHost = destroy;
      else p.duringCompletion = destroy;
      popup->OnNativeBrowserDidClose(&browser);
      require(p.popup == nullptr, "reentrant observer must have destroyed popup");
      checkDestroyed(p); ++checks;
    }
    {
      BrowserWindowInterface browser; Probe p;
      auto* popup = new ExtensionPopup(p, browser);
      delete popup->extension_view_.ExtractAsDangling(); popup->host_.reset();
      popup->OnNativeBrowserDidClose(&browser);
      require(p.closes == 1 && p.completions == 1, "already unloaded payload still completes and closes");
      browser.alive = false; delete popup; checkDestroyed(p); ++checks;
    }
    std::cout << checks << " exact-method lifetime checks passed\n";
    return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
