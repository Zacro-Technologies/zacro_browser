#!/usr/bin/env python3
"""Compile the production single-use native uninstall producer receipt queue."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent


class PostUninstallNavigationTests(unittest.TestCase):
    def test_original_native_producer_and_profile_fences(self):
        applier = (ROOT / "apply_auxiliary_admission.py").read_text()
        self.assertIn("NativeUninstallURLHandlerStorage()", applier)
        body = applier.split("// This is a post-uninstall optional navigation", 1)[1]
        self.assertLess(body.index("IsNativeWebAuthAdmissionBlocked(profile)"), body.index("handler.Run(browser_context_, uninstall_url)"))
        self.assertLess(body.index("handler.Run(browser_context_, uninstall_url)"), body.index("NavigateParams params"))
        topology = (ROOT / "devtools_topology_adapter.inc").read_text()
        take = topology.split("std::optional<GURL> TakePostUninstallNavigation", 1)[1].split("void NotifyPostUninstallNavigation", 1)[0]
        self.assertIn("context_->IsOffTheRecord()", take)
        self.assertIn("IsNativeWebAuthAdmissionBlocked(Profile::FromBrowserContext(context_))", take)
        self.assertIn("for (const auto& token : post_uninstall_.Pending())", topology)
        host = (ROOT.parents[2] / "Sources/ZacroApp/NativeExtensionBrowser.swift").read_text()
        method = host.split("func handlePostUninstallNavigation", 1)[1].split("private func checkPostUninstallNavigation", 1)[0]
        self.assertNotIn("ChromeExtensionHostRequest(", method)
        self.assertNotIn("userGesture", method)
        self.assertIn("try checkPostUninstallNavigation(profile)\n        try scope.commit", method)
        self.assertIn("kind: .normal", method)

    def test_actual_single_use_queue(self):
        source = (ROOT / "devtools_topology_adapter.inc").read_text()
        queue = source.split("// BEGIN ZACRO POST-UNINSTALL NAVIGATION QUEUE", 1)[1].split("// END ZACRO POST-UNINSTALL NAVIGATION QUEUE", 1)[0]
        prelude = r'''
#include <cassert>
#include <cstdio>
#include <map>
#include <optional>
#include <string>
#include <vector>
class GURL {
 public:
  explicit GURL(std::string spec, bool valid=true, bool http=true, bool user=false, bool password=false)
      : spec_(std::move(spec)), valid_(valid), http_(http), user_(user), password_(password) {}
  bool is_valid() const { return valid_; }
  bool SchemeIsHTTPOrHTTPS() const { return http_; }
  bool has_username() const { return user_; }
  bool has_password() const { return password_; }
  const std::string& spec() const { return spec_; }
 private:
  std::string spec_;
  bool valid_, http_, user_, password_;
};
namespace base {
class UnguessableToken {
 public:
  static UnguessableToken Create() { static int next=0; return UnguessableToken(++next); }
  std::string ToString() const { return "native-token-"+std::to_string(id_); }
 private:
  explicit UnguessableToken(int id) : id_(id) {}
  int id_;
};
}
'''
        cases = r'''
int main() {
  int checks=0;
  const auto require=[&](bool value) { assert(value); ++checks; };
  const GURL url("http://127.0.0.1/owned-uninstall");
  ZacroPostUninstallNavigationQueue a, b;
  require(!a.Enqueue(url,true));
  require(a.Pending().empty());
  require(!a.Enqueue(GURL("invalid",false),false));
  require(!a.Enqueue(GURL("file://local",true,false),false));
  require(!a.Enqueue(GURL("http://user@localhost",true,true,true),false));
  require(!a.Enqueue(GURL("http://localhost",true,true,false,true),false));
  require(!a.Enqueue(GURL(std::string(8193,'x')),false));
  const auto first=a.Enqueue(url,false);
  require(first.has_value());
  require(a.Pending().size()==1);
  require(!b.Take(*first,false));
  require(a.Pending().size()==1);
  const auto taken=a.Take(*first,false);
  require(taken && taken->spec()==url.spec());
  require(!a.Take(*first,false));
  require(a.Pending().empty());
  const auto fenced=a.Enqueue(url,false);
  require(fenced.has_value());
  require(!a.Take(*fenced,true));
  require(!a.Take(*fenced,false));
  for(int i=0;i<128;++i) require(a.Enqueue(url,false).has_value());
  require(a.Pending().size()==128);
  require(!a.Enqueue(url,false));
  auto all=a.Pending();
  require(a.Take(all[0],false).has_value());
  require(a.Enqueue(url,false).has_value());
  require(!a.Take(all[0],false));
  ZacroPostUninstallNavigationQueue replacement;
  require(!replacement.Take(all[1],false));
  std::printf("{\"checks\":%d}\n",checks);
}
'''
        with tempfile.TemporaryDirectory(prefix="zacro-uninstall-queue-") as temp:
            path = Path(temp) / "queue.cc"
            binary = Path(temp) / "queue"
            path.write_text(prelude + queue + cases)
            subprocess.run(["xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined", str(path), "-o", str(binary)], check=True)
            result = json.loads(subprocess.check_output([str(binary)], text=True))
            self.assertEqual(result["checks"], 151)


if __name__ == "__main__":
    unittest.main()
