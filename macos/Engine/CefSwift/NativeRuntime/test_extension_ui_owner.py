#!/usr/bin/env python3
"""Extract the actual logical native prompt owner resolver; never grant consent."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent


class ExtensionUIOwnerTests(unittest.TestCase):
    def test_original_api_and_cocoa_owner_guards(self):
        applier = (ROOT / "apply_topology_adapter.py").read_text()
        self.assertIn("if (auto& resolver = NativeUIWindowResolverStorage(); resolver) return resolver.Run(function_);", applier)
        self.assertNotIn("permissions_api.cc", applier)
        cocoa = (ROOT / "native_management_operation_mac.mm.in").read_text().split("NativeExtensionUIWindowForLogicalWindow", 1)[1]
        for guard in ["NSApp.modalWindow", "!window.visible", "window.miniaturized", "window.attachedSheet", "ZacroBrowserWindow:%d", "window.identifier", "current.parentWindow", "if (!descendant) continue"]:
            self.assertIn(guard, cocoa)
        topology = (ROOT / "devtools_topology_adapter.inc").read_text()
        hook = topology.split("SetNativeUIWindowResolver", 1)[1].split("ChromeRuntimeAPIDelegate", 1)[0]
        for guard in ["ForFunction(function)", "operation->IsValid()", "Find(context)", "IsNativeWebAuthAdmissionBlocked"]:
            self.assertIn(guard, hook)

    def test_actual_native_owner_resolver(self):
        text = (ROOT / "devtools_topology_adapter.inc").read_text()
        method = "  gfx::NativeWindow NativeUIWindowForFunction" + text.split("  gfx::NativeWindow NativeUIWindowForFunction", 1)[1].split("  std::optional<GURL> TakePostUninstallNavigation", 1)[0]
        prelude = r'''
#include <cassert>
#include <cstdio>
#include <map>
#include <memory>
#include <optional>
namespace gfx {
struct NativeWindow {
  int id=0;
  explicit NativeWindow(int value=0) : id(value) {}
  explicit operator bool() const { return id>0; }
};
}
struct Context {};
struct Contents {
  Context* context=nullptr;
  int native=0;
  Context* GetBrowserContext() { return context; }
  gfx::NativeWindow GetTopLevelNativeWindow() { return gfx::NativeWindow(native); }
};
struct ExtensionFunction {
  Contents* sender=nullptr;
  Contents* GetSenderWebContents() { return sender; }
};
namespace extensions {
std::map<int,bool> visible;
std::map<int,int> parents;
gfx::NativeWindow NativeExtensionUIWindowForLogicalWindow(int logical, gfx::NativeWindow source=gfx::NativeWindow()) {
  if(logical<=0 || !visible[logical] || (source && parents[source.id]!=logical)) return gfx::NativeWindow();
  return gfx::NativeWindow(logical);
}
}
struct Resolver {
  struct Tab {
    Contents* contents=nullptr;
    int window=0;
    bool closing=false,discarded=false;
    Contents* web_contents() { return contents; }
  };
  Context* context_;
  std::map<int,std::unique_ptr<Tab>> tabs_;
  std::optional<int> focused_window_,last_focused_window_;
'''
        cases = r'''
};
int main() {
  int checks=0;
  const auto require=[&](bool condition){assert(condition);++checks;};
  Context a,b;
  Contents documentA{&a,101},documentB{&a,102},popup{&a,103},foreign{&b,104};
  Resolver resolver{&a,{},2,2};
  resolver.tabs_[1]=std::make_unique<Resolver::Tab>(Resolver::Tab{&documentA,1});
  resolver.tabs_[2]=std::make_unique<Resolver::Tab>(Resolver::Tab{&documentB,2});
  extensions::visible[1]=true;extensions::visible[2]=true;
  extensions::parents[101]=1;extensions::parents[102]=2;extensions::parents[103]=1;
  ExtensionFunction function{&documentA};
  require(resolver.NativeUIWindowForFunction(&function).id==1);
  function.sender=&popup;
  require(resolver.NativeUIWindowForFunction(&function).id==1);
  function.sender=nullptr;
  require(resolver.NativeUIWindowForFunction(&function).id==2);
  resolver.focused_window_.reset();
  require(resolver.NativeUIWindowForFunction(&function).id==2);
  resolver.last_focused_window_.reset();
  require(!resolver.NativeUIWindowForFunction(&function));
  resolver.focused_window_=2;resolver.last_focused_window_=1;
  extensions::visible[2]=false;
  require(!resolver.NativeUIWindowForFunction(&function));
  function.sender=&documentA;resolver.tabs_[1]->closing=true;
  require(!resolver.NativeUIWindowForFunction(&function));
  resolver.tabs_[1]->closing=false;resolver.tabs_[1]->discarded=true;
  require(!resolver.NativeUIWindowForFunction(&function));
  resolver.tabs_[1]->discarded=false;extensions::visible[1]=false;
  require(!resolver.NativeUIWindowForFunction(&function));
  extensions::visible[1]=true;extensions::visible[2]=true;
  function.sender=&foreign;
  require(!resolver.NativeUIWindowForFunction(&function));
  resolver.tabs_.clear();function.sender=nullptr;resolver.focused_window_=1;
  require(resolver.NativeUIWindowForFunction(&function).id==1);
  resolver.focused_window_=0;
  require(!resolver.NativeUIWindowForFunction(&function));
  std::printf("{\"checks\":%d}\n",checks);
}
'''
        with tempfile.TemporaryDirectory(prefix="zacro-native-ui-owner-") as temp:
            source = Path(temp) / "owner.cc"
            binary = Path(temp) / "owner"
            source.write_text(prelude + method + cases)
            subprocess.run(["xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined", str(source), "-o", str(binary)], check=True)
            result = json.loads(subprocess.check_output([str(binary)], text=True))
            self.assertEqual(result["checks"], 12)


if __name__ == "__main__":
    unittest.main()
