// Harness around the exact production lifecycle methods. Native callbacks,
// weak lifetime and WebContents identity are controlled; no UI is simulated.
#include <functional>
#include <iostream>
#include <map>
#include <memory>
#include <stdexcept>
#include <utility>
namespace base {
template<class T> class WeakPtr {
  T* pointer_ = nullptr;
  std::weak_ptr<int> life_;
 public:
  WeakPtr() = default;
  WeakPtr(T* pointer, std::weak_ptr<int> life) : pointer_(pointer), life_(life) {}
  T* get() const { return life_.expired() ? nullptr : pointer_; }
};
class CallbackListSubscription {
  std::function<void()> cancel_;
 public:
  CallbackListSubscription() = default;
  explicit CallbackListSubscription(std::function<void()> cancel) : cancel_(std::move(cancel)) {}
  CallbackListSubscription(CallbackListSubscription&& other) : cancel_(std::exchange(other.cancel_, {})) {}
  CallbackListSubscription& operator=(CallbackListSubscription&& other) {
    if (cancel_) cancel_(); cancel_ = std::exchange(other.cancel_, {}); return *this;
  }
  ~CallbackListSubscription() { if (cancel_) cancel_(); }
  explicit operator bool() const { return bool(cancel_); }
};
template<class T> T* Unretained(T* value) { return value; }
template<class F, class T> auto BindRepeating(F method, T* self) {
  return [method, self](auto* tab, auto reason) { method(self, tab, reason); };
}
}
namespace tabs { class TabInterface; }
struct Context { int transfers = 0; void* transferred = nullptr; };
namespace content {
struct WebContents {
  Context* context;
  tabs::TabInterface* tab = nullptr;
  Context* GetBrowserContext() { return context; }
};
}
namespace tabs {
class TabInterface {
 public:
  enum class DetachReason { kDelete, kInsertIntoOtherWindow };
  using Callback = std::function<void(TabInterface*, DetachReason)>;
  std::shared_ptr<int> life = std::make_shared<int>(1);
  std::shared_ptr<std::map<int, Callback>> callbacks = std::make_shared<std::map<int, Callback>>();
  content::WebContents* contents;
  int registrations = 0;
  explicit TabInterface(content::WebContents* c) : contents(c) { c->tab = this; }
  ~TabInterface() { if (contents->tab == this) contents->tab = nullptr; }
  static TabInterface* MaybeGetFromContents(content::WebContents* c) { return c->tab; }
  content::WebContents* GetContents() { return contents; }
  base::WeakPtr<TabInterface> GetWeakPtr() { return {this, life}; }
  base::CallbackListSubscription RegisterWillDetach(Callback callback) {
    const int id = ++registrations; (*callbacks)[id] = std::move(callback);
    return base::CallbackListSubscription([weak=std::weak_ptr(callbacks), id] { if (auto live=weak.lock()) live->erase(id); });
  }
  void Notify(DetachReason reason = DetachReason::kDelete) {
    const auto snapshot = *callbacks;
    for (auto& [id, callback] : snapshot) if (callbacks->contains(id)) callback(this, reason);
  }
};
}
struct Registry {
  Context* context = nullptr;
  void ReconcileGlobalPanels(content::WebContents* contents) {
    ++context->transfers; context->transferred = contents;
  }
};
Registry registry;
Registry* Get(Context* context) { registry.context = context; return &registry; }
struct Tab {
  content::WebContents* contents_ = nullptr;
  bool closing = false;
  base::WeakPtr<tabs::TabInterface> observed_tab;
  base::CallbackListSubscription detach_subscription;
  content::WebContents* web_contents() { return contents_; }
  void Observe(content::WebContents* contents) { contents_ = contents; }
  // EXACT_PRODUCTION_METHODS
};
int checks = 0;
void require(bool result, const char* label) { if (!result) throw std::runtime_error(label); ++checks; }
int main() {
  Context a, b;
  content::WebContents first{&a}, second{&b};
  Tab owner;
  owner.Bind(&first);
  require(!owner.detach_subscription && !owner.closing, "pre-TabModel reservation has no invented observer");
  auto native = std::make_unique<tabs::TabInterface>(&first);
  owner.ObserveTabLifecycle();
  require(native->callbacks->size()==1 && owner.observed_tab.get()==native.get(), "materialization attaches exact native tab");
  owner.ObserveTabLifecycle();
  require(native->registrations==1, "same materialization is idempotent");
  require(a.transfers==0 && !owner.closing, "registration and veto do not transfer");
  native->Notify(tabs::TabInterface::DetachReason::kInsertIntoOtherWindow);
  require(a.transfers==0 && !owner.closing, "tab move is not accepted deletion");
  native->Notify();
  require(a.transfers==1 && a.transferred==&first && owner.closing, "accepted deletion transfers exact document");
  owner.ObserveTabLifecycle(); native->Notify();
  require(a.transfers==1 && owner.closing, "re-registration cannot reset accepted-close identity");
  tabs::TabInterface next(&second);
  owner.Bind(&second);
  require(native->callbacks->empty() && !owner.closing && next.callbacks->size()==1, "rebind releases old observer and adopts exact new tab");
  native->Notify();
  require(a.transfers==1 && b.transfers==0, "old document has no remaining close authority");
  next.Notify();
  require(b.transfers==1 && b.transferred==&second, "new document close targets only its own profile");
  owner.Bind(&first);
  native.reset();
  auto replacement = std::make_unique<tabs::TabInterface>(&first);
  owner.ObserveTabLifecycle();
  require(owner.observed_tab.get()==replacement.get() && replacement->callbacks->size()==1, "replacement native tab on same contents attaches after weak expiry");
  content::WebContents foreign{&b};
  replacement->contents=&foreign;
  replacement->Notify();
  require(a.transfers==1 && !owner.closing, "mismatched native contents cannot transfer");
  replacement->contents=&first;
  owner.Bind(nullptr);
  require(replacement->callbacks->empty() && !owner.detach_subscription, "unbind clears all close authority");
  {
    Tab temporary; temporary.Bind(&first);
    require(replacement->callbacks->size()==1, "scoped listener registered");
  }
  require(replacement->callbacks->empty(), "listener destruction removes callback");
  std::cout << "PASS " << checks << " exact lifecycle checks\n";
}
