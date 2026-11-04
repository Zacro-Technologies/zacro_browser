#!/usr/bin/env python3
"""Exact production modal-parent/bridge lifecycle with real ObjC weak references.

The windows/App are Foundation stand-ins, not AppKit/Views presentation. Current
adapter bridge transforms execute against exact pinned method bodies; the real
parent include, notification center, association and ARC lifetimes are compiled.
"""
import argparse
import ast
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("modal_prompt_adapter", ROOT / "apply_management_prompt_adapter.py")
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


def transformed_methods():
    original = (ROOT / "fixtures/native_external_modal_bridge_baseline.mm.inc").read_text()
    scope = dict(vars(adapter), output={adapter.BRIDGE: original})
    tree = ast.parse((ROOT / "apply_management_prompt_adapter.py").read_text())
    generated = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "generated")
    for statement in generated.body:
        if not isinstance(statement, ast.Assign):
            continue
        target = statement.targets[0]
        if (isinstance(target, ast.Subscript) and isinstance(target.value, ast.Name)
                and target.value.id == "output" and isinstance(target.slice, ast.Name)
                and target.slice.id == "BRIDGE"):
            exec(compile(ast.Module(body=[statement], type_ignores=[]), "actual-bridge-transform", "exec"), scope)
    output = scope["output"][adapter.BRIDGE]
    first = "void NativeWidgetNSWindowBridge::CloseWindow()"
    end = "bool NativeWidgetNSWindowBridge::IsWindowModalSheet() const"
    assert original[original.index(first):original.index(end)] == output[output.index(first):output.index(end)], "Pinned CloseWindow changed"
    assert "NSWindow* __weak external_sheet_parent" in output
    assert "owned_sheet_parent = external_parent ? nil : parent_window" in output
    assert output.count("ExternalWindowModalParentIsReady") == 2
    # Headers are already represented by the fixture declarations below. The
    # actual production include is inserted once, outside the C++ namespace.
    return "\n".join(line for line in output.splitlines() if not line.startswith("#include"))


def actual_modal_host_selectors():
    """Execute both current production selector replacements, not a duplicate."""
    tree = ast.parse((ROOT / "apply_management_prompt_adapter.py").read_text())
    generated = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "generated")
    replacements = []
    for statement in generated.body:
        if not isinstance(statement, ast.Assign):
            continue
        target, value = statement.targets[0], statement.value
        if not (isinstance(target, ast.Subscript) and isinstance(target.value, ast.Name)
                and target.value.id == "output" and isinstance(target.slice, ast.Name)
                and target.slice.id == "CONSTRAINED" and isinstance(value, ast.Call)):
            continue
        replacement = ast.literal_eval(value.args[2])
        if "auto* parent_host" in replacement and "gfx::AcceleratedWidget parent_widget" in replacement:
            assert "#if BUILDFLAG(IS_MAC)" in replacement
            assert "parent && !has_external_parent_view" in replacement
            replacements.append(replacement)
    assert len(replacements) == 2, "Both actual native modal host selection sites must execute"
    functions = []
    for index, replacement in enumerate(replacements):
        for mac in [1, 0]:
            functions.append(f"""
#define IS_MAC {mac}
#define BUILDFLAG(flag) flag
gfx::AcceleratedWidget Select{index}Mac{mac}(int parent, int parent_view) {{
{replacement}
  return parent_widget;
}}
#undef BUILDFLAG
#undef IS_MAC
""")
    return SELECTOR_PRELUDE + "\nnamespace modal_fixture {\n" + "\n".join(functions) + "\n}\n" + SELECTOR_CASES


PRELUDE = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <cassert>
#include <functional>
#include <iostream>
#include <map>
#include <memory>
#include <stdexcept>
#include <vector>
#include <type_traits>
@class TestWindow;
@interface WeakWindow : NSObject
@property(nonatomic, weak) TestWindow* value;
@end
@implementation WeakWindow
@synthesize value = _value;
@end
@interface TestWindow : NSObject
@property NSInteger windowNumber;
@property(getter=isVisible) BOOL visible;
@property BOOL miniaturized;
@property BOOL sheet;
@property(nonatomic, weak) TestWindow* attachedSheet;
@property(nonatomic, weak) TestWindow* parentWindow;
@property(nonatomic, weak) TestWindow* sheetParent;
@property(nonatomic, weak) id delegate;
@property(nonatomic, copy) void (^completion)(NSInteger);
@property int shown;
@property int closed;
- (void)beginSheet:(TestWindow*)child completionHandler:(void (^)(NSInteger))handler;
- (void)orderOut:(id)sender;
- (void)close;
@end
@interface TestViewsWindow : TestWindow
- (TestWindow*)preferredSheetParent;
@end
@interface TestApp : NSObject
@property(nonatomic, strong) NSMutableDictionary<NSNumber*, WeakWindow*>* windows;
@property(nonatomic, weak) TestWindow* modalWindow;
- (TestWindow*)windowWithWindowNumber:(NSInteger)number;
- (void)endSheet:(TestWindow*)window;
@end
static TestApp* app;
static NSString* const Closing = @"ZacroTestWindowWillClose";
@implementation TestWindow
@synthesize windowNumber = _windowNumber;
@synthesize visible = _visible;
@synthesize miniaturized = _miniaturized;
@synthesize sheet = _sheet;
@synthesize attachedSheet = _attachedSheet;
@synthesize parentWindow = _parentWindow;
@synthesize sheetParent = _sheetParent;
@synthesize delegate = _delegate;
@synthesize completion = _completion;
@synthesize shown = _shown;
@synthesize closed = _closed;
- (void)beginSheet:(TestWindow*)child completionHandler:(void (^)(NSInteger))handler {
  self.attachedSheet=child; child.sheetParent=self; child.sheet=YES;
  child.visible=YES; child.completion=handler; child.shown++;
}
- (void)orderOut:(id)sender { self.visible=NO; }
- (void)close { self.closed++; self.visible=NO; self.delegate=nil;
  [[NSNotificationCenter defaultCenter] postNotificationName:Closing object:self]; }
@end
@implementation TestViewsWindow
- (TestWindow*)preferredSheetParent { return self; }
@end
@implementation TestApp
@synthesize windows = _windows;
@synthesize modalWindow = _modalWindow;
- (TestWindow*)windowWithWindowNumber:(NSInteger)number { return self.windows[@(number)].value; }
- (void)endSheet:(TestWindow*)window {
  auto completion=window.completion; window.completion=nil;
  window.sheetParent.attachedSheet=nil; window.sheetParent=nil; window.sheet=NO;
  if(completion)completion(0);
}
@end
@interface ViewsNSWindowCloseAnimator : NSObject
+ (void)closeWindowWithAnimation:(TestWindow*)window;
@end
@implementation ViewsNSWindowCloseAnimator
+ (void)closeWindowWithAnimation:(TestWindow*)window { [window close]; }
@end
#define NSWindow TestWindow
#define NativeWidgetMacNSWindow TestViewsWindow
#define NSModalResponse NSInteger
#define NSApp app
#define NSWindowWillCloseNotification Closing
#define FROM_HERE 0
#define DCHECK(value) assert(value)
namespace gfx { struct NativeWindow {
  __weak TestWindow* value;
  NativeWindow(TestWindow* v):value(v){}
  TestWindow* GetNativeNSWindow() const { return value; }
}; }
namespace ui::mojom { enum class ModalType { kNone, kWindow }; }
namespace base {
template<class T> struct WeakPtr {
  std::weak_ptr<T*> value;
  T* get() const { auto v=value.lock();return v?*v:nullptr; }
  explicit operator bool() const { return get()!=nullptr; }
  T* operator->() const { return get(); }
};
template<class T> struct Factory {
  std::shared_ptr<T*> value;
  explicit Factory(T* v):value(std::make_shared<T*>(v)){}
  WeakPtr<T> GetWeakPtr() { return {value}; }
};
inline void (^BindOnce(void (^block)()))() { return [block copy]; }
struct SingleThreadTaskRunner {
  std::vector<std::function<void()>> tasks;
  static SingleThreadTaskRunner* GetCurrentDefault(){ static SingleThreadTaskRunner r;return &r; }
  void PostTask(int,void (^block)()){tasks.emplace_back([block]{block();});}
  void Drain(){while(!tasks.empty()){auto task=std::move(tasks.front());tasks.erase(tasks.begin());task();}}
};
namespace apple {template<class T>T* ObjCCast(id object) {
  if constexpr(std::is_same_v<T,TestViewsWindow>) return [object isKindOfClass:TestViewsWindow.class]?(T*)object:nil;
  return nil;
}}
}
namespace remote_cocoa {
namespace mojom {enum class VisibilityTransition{kHide};}
struct Host {void OnVisibilityChanged(bool){};};
struct Fullscreen {bool HasDeferredWindowClose(){return false;}void OnWindowWantsToClose(){};};
class NativeWidgetNSWindowBridge {
 public:
  static std::map<void*,NativeWidgetNSWindowBridge*> registry;
  static NativeWidgetNSWindowBridge* GetFromNSWindow(TestWindow* w){auto p=registry.find((__bridge void*)w);return p==registry.end()?nullptr:p->second;}
  __strong TestWindow* window_;
  NativeWidgetNSWindowBridge* parent_=nullptr;
  ui::mojom::ModalType modal_type_=ui::mojom::ModalType::kWindow;
  bool wants_to_be_visible_=true,window_visible_=false;
  int completions=0;
  Host host;Host* host_=&host;Fullscreen fullscreen_controller_;
  base::Factory<NativeWidgetNSWindowBridge> factory_{this};
  explicit NativeWidgetNSWindowBridge(TestWindow* w):window_(w){registry[(__bridge void*)w]=this;w.delegate=w;}
  ~NativeWidgetNSWindowBridge(){registry.erase((__bridge void*)window_);window_.delegate=nil;}
  NativeWidgetNSWindowBridge* parent(){return parent_;}
  ui::mojom::ModalType modal_type(){return modal_type_;}
  TestWindow* ns_window(){return window_;}
  bool IsWindowModalSheet() const;
  void ShowAsModalSheet();void CloseWindow();
  bool ShouldRunCustomAnimationFor(mojom::VisibilityTransition){return false;}
  void OnWindowWillClose(){++completions;window_.delegate=nil;}
};
std::map<void*,NativeWidgetNSWindowBridge*> NativeWidgetNSWindowBridge::registry;
}
'''

SELECTOR_PRELUDE = r'''
// These platform-neutral stand-ins deliberately fail if a Mac external shell
// consults any Chrome modal client. The exact production condition decides.
namespace gfx {using AcceleratedWidget=int;constexpr AcceleratedWidget kNullAcceleratedWidget=0;}
namespace views {
struct Widget {
  static inline int lookups=0;
  static Widget* GetWidgetForNativeView(int view) {
    ++lookups;static Widget normal;return view==17?&normal:nullptr;
  }
};
}
namespace modal_fixture {
struct ModalHost {
  int accelerated_calls=0;
  gfx::AcceleratedWidget GetAcceleratedWidget(){++accelerated_calls;return 44;}
};
struct ModalClient {
  int lookups=0;bool allow_nonmac_external=false,missing=false;
  ModalHost host;
  ModalHost* GetModalDialogHost(int parent) {
    ++lookups;
    if(parent==23&&!allow_nonmac_external)throw std::runtime_error("external shell borrowed Chrome modal lookup");
    return missing?nullptr:&host;
  }
};
static ModalClient client;
static ModalClient* CurrentBrowserModalClient(){return &client;}
static void reset(){client=ModalClient{};views::Widget::lookups=0;}
}
static void expect(bool,const char*);
'''

SELECTOR_CASES = r'''
static void checkModalHostSelectors(){
  using namespace modal_fixture;
  for(int site=0;site<2;++site){
    auto mac=site==0?Select0Mac1:Select1Mac1;
    auto nonmac=site==0?Select0Mac0:Select1Mac0;
    reset();expect(mac(23,23)==0&&client.lookups==0&&views::Widget::lookups==1,
      "actual Mac external empty shell never performs Chrome host lookup");
    reset();expect(mac(17,17)==44&&client.lookups==1&&client.host.accelerated_calls==1&&views::Widget::lookups==1,
      "actual Mac Views parent keeps its own real modal host");
    reset();expect(mac(0,0)==0&&client.lookups==0&&views::Widget::lookups==0,
      "actual Mac null parent preserves windowless fallback");
    reset();expect(mac(0,23)==0&&client.lookups==0&&views::Widget::lookups==1,
      "actual Mac external view without parent never borrows a host");
    reset();expect(mac(17,0)==44&&client.lookups==1&&views::Widget::lookups==0,
      "actual Mac missing view preserves existing parent host lookup");
    reset();client.missing=true;expect(mac(17,17)==0&&client.lookups==1&&client.host.accelerated_calls==0,
      "actual Mac missing Chrome host returns null accelerated widget");
    reset();client.allow_nonmac_external=true;
    expect(nonmac(23,23)==44&&client.lookups==1&&views::Widget::lookups==0,
      "actual non-Mac native owner keeps Chrome lookup without Mac classification");
    reset();expect(nonmac(0,23)==0&&client.lookups==0&&views::Widget::lookups==0,
      "actual non-Mac null parent preserves windowless fallback");
    reset();client.missing=true;expect(nonmac(17,17)==0&&client.lookups==1&&views::Widget::lookups==0,
      "actual non-Mac missing modal host preserves null fallback");
  }
}
'''

FIXTURES = r'''
static int checks=0;
static void expect(bool value,const char* name){if(!value){std::cerr<<"FAIL "<<name<<"\n";std::abort();}++checks;}
static TestWindow* window(){auto w=[TestWindow new];static int next=1;w.windowNumber=next++;w.visible=YES;
  auto box=[WeakWindow new];box.value=w;app.windows[@(w.windowNumber)]=box;return w;}
static void drain(){base::SingleThreadTaskRunner::GetCurrentDefault()->Drain();}
int main(){@autoreleasepool {
 app=[TestApp new];app.windows=[NSMutableDictionary new];
 using remote_cocoa::NativeWidgetNSWindowBridge;
 using remote_cocoa::SetExternalWindowModalParent;
 using remote_cocoa::ExternalWindowModalParentIsReady;
 using remote_cocoa::ExternalWindowModalParent;
 {
  auto p=window(),c=window();c.visible=NO;NativeWidgetNSWindowBridge b(c);
  expect(SetExternalWindowModalParent(p?gfx::NativeWindow(c):gfx::NativeWindow(nil),gfx::NativeWindow(p)),"exact external owner attaches");
  expect(ExternalWindowModalParentIsReady(c,p)&&b.IsWindowModalSheet(),"external sheet marker and readiness");
  expect(!SetExternalWindowModalParent(gfx::NativeWindow(c),gfx::NativeWindow(p)),"cannot replace consumed parent authority");
  auto unrelated=window();[unrelated close];drain();expect(c.closed==0&&!ExternalWindowModalParent(c).closed,"unrelated close no cancellation");
  b.ShowAsModalSheet();expect(c.shown==0,"presentation is posted");drain();expect(c.shown==1&&p.attachedSheet==c,"actual posted show uses original parent");
  b.ShowAsModalSheet();drain();expect(c.shown==1,"shown sheet never presents twice");
  [p close];expect(ExternalWindowModalParent(c).closed,"close notification permanently revokes parent");drain();
  expect(!c.sheet&&b.completions==1&&!b.wants_to_be_visible_,"unchanged CloseWindow uses endSheet completion");
  p.visible=YES;expect(!ExternalWindowModalParentIsReady(c,p),"reopened same parent does not revive consent");
 }
 {
  auto c=window();c.visible=NO;NativeWidgetNSWindowBridge b(c);__weak TestWindow* weak;
  @autoreleasepool{auto p=window();weak=p;expect(SetExternalWindowModalParent(gfx::NativeWindow(c),gfx::NativeWindow(p)),"weak parent attaches");b.ShowAsModalSheet();}
  expect(weak==nil&&ExternalWindowModalParent(c).parent==nil,"associated observer and posted external task do not retain parent");
  drain();expect(c.shown==0&&c.closed==1&&b.IsWindowModalSheet(),"dead parent cancels original widget without orphan show");
 }
 {
  auto p=window(),c=window();c.visible=NO;NativeWidgetNSWindowBridge b(c);
  expect(SetExternalWindowModalParent(gfx::NativeWindow(c),gfx::NativeWindow(p)),"queued-close parent attaches");
  b.ShowAsModalSheet();[p close];p.visible=YES;drain();expect(c.shown==0&&c.closed>0,"closed latch wins over posted show and same pointer reuse");
 }
 {
  auto p=window(),c=window();c.visible=NO;NativeWidgetNSWindowBridge b(c);
  expect(SetExternalWindowModalParent(gfx::NativeWindow(c),gfx::NativeWindow(p)),"readiness cases attach");
  p.miniaturized=YES;expect(!ExternalWindowModalParentIsReady(c,p),"miniaturized parent blocked");p.miniaturized=NO;
  auto other=window();p.attachedSheet=other;expect(!ExternalWindowModalParentIsReady(c,p),"unrelated sheet blocked");p.attachedSheet=nil;
  app.modalWindow=other;expect(!ExternalWindowModalParentIsReady(c,p),"unrelated app modal blocked");app.modalWindow=nil;
  app.windows[@(p.windowNumber)].value=other;expect(!ExternalWindowModalParentIsReady(c,p),"window number reuse is not owner identity");
 }
 {
  auto p=window(),c=window();c.visible=NO;NativeWidgetNSWindowBridge parent(p),child(c);
  expect(!SetExternalWindowModalParent(gfx::NativeWindow(c),gfx::NativeWindow(p)),"genuine Views parent cannot become external");
  child.parent_=&parent;expect(child.IsWindowModalSheet(),"normal Views sheet branch retained");child.ShowAsModalSheet();drain();
  expect(c.shown==1&&p.attachedSheet==c,"normal bridge parent shows through original branch");child.CloseWindow();drain();expect(child.completions==1,"normal sheet close completion retained");
 }
 {
  auto p=window(),c=window();c.visible=NO;
  {auto bridge=std::make_unique<NativeWidgetNSWindowBridge>(c);expect(SetExternalWindowModalParent(gfx::NativeWindow(c),gfx::NativeWindow(p)),"child destruction case attaches");bridge->ShowAsModalSheet();}
  drain();[p close];drain();expect(c.shown==0,"destroyed bridge and later owner notification are safe no-ops");
 }
 checkModalHostSelectors();
 app=nil;std::cout<<checks<<" exact external modal parent lifecycle and host-selection checks passed (26 lifecycle + 18 selectors)\n";
}}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-only", action="store_true")
    parser.add_argument("--sanitizers", action="store_true")
    args = parser.parse_args()
    methods = transformed_methods()
    selectors = actual_modal_host_selectors()
    production = (ROOT / "native_external_window_modal_parent.inc").read_text()
    assert "object:nil queue:nil" in production and "__weak NSWindow* weak_child" in production
    assert "@property(nonatomic, weak) NSWindow* parent" in production
    print(json.dumps({"sourceGuardsPassed": True, "actualAppKitOrViewsPresentation": False}))
    if args.source_only:
        print("Compiled lifecycle fixture explicitly not run (--source-only)")
        return
    with tempfile.TemporaryDirectory(prefix="zacro-native-modal-parent-") as temporary:
        source = Path(temporary) / "fixture.mm"
        executable = Path(temporary) / "fixture"
        source.write_text(PRELUDE + "\n" + production + "\nnamespace remote_cocoa {\n" + methods + "\n}\n" + selectors + FIXTURES)
        command = ["xcrun", "clang++", "-std=c++20", "-fobjc-arc", "-fblocks", "-O0", "-g",
                   "-Wobjc-missing-property-synthesis", "-Wshadow", "-Werror",
                   "-framework", "Foundation", str(source), "-o", str(executable)]
        if args.sanitizers:
            command += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
        subprocess.run(command, check=True, timeout=35)
        result = subprocess.run([str(executable)], check=True, text=True, capture_output=True, timeout=10,
                                env=dict(os.environ, ASAN_OPTIONS="detect_leaks=0:abort_on_error=1", UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1"))
        print(result.stdout, end="")
        if result.stderr:
            print(result.stderr, end="")
        print(json.dumps({"compiledExactProductionInclude": True, "realObjectiveCWeakAndNotifications": True,
                          "sanitizers": args.sanitizers, "actualAppKitOrViewsPresentation": False}))


if __name__ == "__main__":
    main()
