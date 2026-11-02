#!/usr/bin/env python3
"""Pinned history patch checks and exact barrier methods with native stand-ins.

The small C++ fixture executes the generated renderer, RFH, and lifecycle method
bodies. It checks ordering/invalidation without claiming a full renderer IPC test;
the packaged EngineAcceptance large/oversized form test remains the real gate.
"""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("history_adapter", ROOT / "apply_history_flush_adapter.py")
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


def method(source, first, following):
    return source[source.index(first):source.index(following, source.index(first))]


class HistoryFlushTests(unittest.TestCase):
    def test_idempotent_generated_output_and_review_patch(self):
        output = adapter.generated(self.originals)
        self.assertEqual(output, adapter.generated(self.originals))
        adapter.validate_current(self.originals, output, self.originals)
        adapter.validate_current(self.originals, output, output)

    def test_pinned_source_drift_fails_closed(self):
        changed = dict(self.originals)
        changed[adapter.RENDER_CC] = changed[adapter.RENDER_CC].replace(
            "void RenderFrameImpl::SendUpdateState() {", "void RenderFrameImpl::SendState() {")
        with self.assertRaisesRegex(SystemExit, "source drift"):
            adapter.generated(changed)

    def test_unrelated_edits_rejected_and_exact_previous_receipt_allowed(self):
        output = adapter.generated(self.originals)
        previous = dict(output)
        previous[adapter.HOST_CC] += "\n// exact previous generated revision\n"
        with self.assertRaisesRegex(SystemExit, "unrelated edits"):
            adapter.validate_current(self.originals, output, previous)
        receipt = {"revision": adapter.PIN, "files": {p: adapter.digest(s) for p, s in previous.items()}}
        adapter.validate_current(self.originals, output, previous, receipt)
        previous[adapter.HOST_CC] += "// unrelated user change\n"
        with self.assertRaisesRegex(SystemExit, "unrelated edits"):
            adapter.validate_current(self.originals, output, previous, receipt)

    def test_existing_validation_and_freeze_flush_remain_unchanged(self):
        output = adapter.generated(self.originals)
        # The new entrypoint must not rewrite the existing state generator or
        # bypass the existing security checks by sending PageState in the ACK.
        for path, marker in [(adapter.RENDER_CC, "void RenderFrameImpl::SendUpdateState() {"),
                             (adapter.HOST_CC, "void RenderFrameHostImpl::UpdateState(")]:
            original = self.originals[path]
            old_body = method(original, marker, "\n}\n")
            new_body = method(output[path], marker, "\n}\n")
            self.assertEqual(old_body, new_body)
        self.assertIn("FlushStateForNativeNavigation() => (bool captured);", output[adapter.MOJO])
        self.assertNotIn("PageState state", output[adapter.MOJO][output[adapter.MOJO].index("  // Flush current"):output[adapter.MOJO].index("  // Requests a one-time snapshot")])

    def test_exact_native_methods(self):
        if self.source_only:
            self.skipTest("Native compile intentionally deferred; real packaged fixture remains required.")
        output = adapter.generated(self.originals)
        bodies = "\n".join([
            method(output[adapter.RENDER_CC], "void RenderFrameImpl::FlushStateForNativeNavigation(", "void RenderFrameImpl::SendUpdateState() {"),
            method(output[adapter.HOST_CC], "void RenderFrameHostImpl::FlushStateForNativeNavigation(", "void RenderFrameHostImpl::RequestAXTreeSnapshot("),
            method(output[adapter.LIFECYCLE_CC], "void PageLifecycleStateManager::ConfirmFrozenStateForNativeHistory(", "void PageLifecycleStateManager::SetIsFrozen(bool frozen) {")])
        with tempfile.TemporaryDirectory(prefix="zacro-history-barrier-") as directory:
            root = Path(directory)
            source = root / "barrier.cc"; binary = root / "barrier"
            source.write_text(PRELUDE + bodies + FIXTURE)
            subprocess.run(["xcrun", "clang++", "-std=c++20", str(source), "-o", str(binary)], check=True)
            result = subprocess.check_output([str(binary)], text=True)
            self.assertEqual(result.strip(), "12 native history barrier checks passed")


PRELUDE = r'''
#include <functional>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <tuple>
#include <utility>
#include <vector>
namespace base {
template<class> struct OnceCallback;
template<class... A> struct OnceCallback<void(A...)> {
  std::function<void(A...)> fn;
  OnceCallback() = default;
  template<class F> OnceCallback(F fn):fn(std::move(fn)){}
  void Run(A... args) { auto invoke=std::move(fn); invoke(std::forward<A>(args)...); }
};
template<class F, class... A> auto BindOnce(F fn, A... args) {
  return [fn=std::move(fn), saved=std::tuple<A...>(std::move(args)...)](auto... rest) mutable {
    return std::apply([&](auto&... bound) { return fn(std::move(bound)..., rest...); }, saved);
  };
}
template<class T> struct WeakPtr {
  T* value; explicit operator bool() const { return value!=nullptr; }
  T* operator->() const { return value; }
};
template<class T> struct WeakPtrFactory {
  T* value; WeakPtr<T> GetWeakPtr() { return {value}; }
};
}
using Callback=base::OnceCallback<void(bool)>;
struct HistoryItem { bool empty=false; bool IsNull() const { return empty; } };
struct WebFrame { HistoryItem item; HistoryItem GetCurrentHistoryItem() { return item; } };
struct RenderFrameImpl {
  using FlushStateForNativeNavigationCallback=Callback;
  WebFrame* frame=nullptr;
  std::vector<std::string> events;
  WebFrame* GetWebFrame() { return frame; }
  void SendUpdateState() { events.push_back("state"); }
  void FlushStateForNativeNavigation(Callback callback);
};
struct State { bool is_frozen=false; };
struct PageLifecycleStateManager;
struct RenderViewHost {
  PageLifecycleStateManager* lifecycle=nullptr;
  bool broadcast=true;
  bool GetAssociatedPageBroadcast() { return broadcast; }
  PageLifecycleStateManager* GetPageLifecycleStateManager() { return lifecycle; }
};
struct PageLifecycleStateManager {
  RenderViewHost* render_view_host_impl_;
  State expected, acknowledged;
  State* last_acknowledged_state_=&acknowledged;
  base::WeakPtrFactory<PageLifecycleStateManager> weak_ptr_factory_{this};
  base::OnceCallback<void()> completion;
  explicit PageLifecycleStateManager(RenderViewHost* rvh):render_view_host_impl_(rvh) {rvh->lifecycle=this;}
  State* CalculatePageLifecycleState() { return &expected; }
  void SendUpdatesToRendererIfNeeded(std::nullptr_t, base::OnceCallback<void()> done) { completion=std::move(done); }
  void ConfirmFrozenStateForNativeHistory(Callback callback);
};
struct RenderFrameHostImpl;
struct WeakDocumentPtr {
  std::shared_ptr<RenderFrameHostImpl*> document;
  RenderFrameHostImpl* AsRenderFrameHostIfValid() { return *document; }
};
struct RemoteFrame {
  int calls=0; Callback pending;
  void FlushStateForNativeNavigation(Callback callback) {++calls;pending=std::move(callback);}
};
struct RenderFrameHostImpl {
  bool live=true;
  RenderViewHost rvh;
  PageLifecycleStateManager lifecycle{&rvh};
  RemoteFrame remote;
  std::shared_ptr<RenderFrameHostImpl*> document=std::make_shared<RenderFrameHostImpl*>(this);
  bool IsRenderFrameLive() { return live; }
  WeakDocumentPtr GetWeakDocumentPtr() { return {document}; }
  RenderViewHost* render_view_host() { return &rvh; }
  RemoteFrame* GetMojomFrameInRenderer() { return &remote; }
  void FlushStateForNativeNavigation(Callback callback);
};
'''

FIXTURE = r'''
int main() {
  int checks=0; auto expect=[&](bool yes) {if(!yes)throw std::runtime_error("History barrier invariant");++checks;};
  RenderFrameImpl renderer; WebFrame frame;
  bool answer=true;
  renderer.FlushStateForNativeNavigation([&](bool v){answer=v;});
  expect(!answer&&renderer.events.empty());
  renderer.frame=&frame;frame.item.empty=true;answer=true;
  renderer.FlushStateForNativeNavigation([&](bool v){answer=v;});
  expect(!answer&&renderer.events.empty());
  frame.item.empty=false;
  renderer.FlushStateForNativeNavigation([&](bool v){answer=v;renderer.events.push_back("ack");});
  expect(answer&&renderer.events==std::vector<std::string>{"state","ack"});
  {RenderFrameHostImpl host;host.live=false;answer=true;
   host.FlushStateForNativeNavigation([&](bool v){answer=v;});expect(!answer&&host.remote.calls==0);}
  {RenderFrameHostImpl host;int called=0;host.FlushStateForNativeNavigation([&](bool v){answer=v;++called;});
   expect(called==0&&host.remote.calls==1);host.remote.pending.Run(true);expect(answer&&called==1);}
  {RenderFrameHostImpl host;host.FlushStateForNativeNavigation([&](bool v){answer=v;});
   *host.document=nullptr;host.remote.pending.Run(true);expect(!answer);}
  {RenderFrameHostImpl host;host.FlushStateForNativeNavigation([&](bool v){answer=v;});
   host.live=false;host.remote.pending.Run(true);expect(!answer);}
  {RenderFrameHostImpl host;host.lifecycle.expected.is_frozen=true;host.lifecycle.acknowledged.is_frozen=true;
   host.FlushStateForNativeNavigation([&](bool v){answer=v;});expect(answer&&host.remote.calls==0);}
  {RenderFrameHostImpl host;int called=0;host.lifecycle.expected.is_frozen=true;
   host.FlushStateForNativeNavigation([&](bool v){answer=v;++called;});
   if(called!=0||host.remote.calls!=0)throw std::runtime_error("Premature freeze acknowledgement");
   host.lifecycle.acknowledged.is_frozen=true;host.lifecycle.completion.Run();expect(answer&&called==1);}
  {RenderFrameHostImpl host;host.lifecycle.expected.is_frozen=true;
   host.FlushStateForNativeNavigation([&](bool v){answer=v;});host.lifecycle.expected.is_frozen=false;
   host.lifecycle.acknowledged.is_frozen=true;host.lifecycle.completion.Run();expect(!answer);}
  {RenderFrameHostImpl host;host.lifecycle.expected.is_frozen=true;host.rvh.broadcast=false;
   host.FlushStateForNativeNavigation([&](bool v){answer=v;});expect(!answer&&host.remote.calls==0);}
  std::cout<<checks<<" native history barrier checks passed\n";
}
'''

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--chromium-root", required=True, type=Path)
    parser.add_argument("--source-only", action="store_true")
    args, rest = parser.parse_known_args()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=args.chromium_root, text=True).strip()
    if revision != adapter.PIN:
        raise SystemExit("Pinned Chromium revision required")
    HistoryFlushTests.originals = adapter.source_baselines(args.chromium_root)
    HistoryFlushTests.source_only = args.source_only
    unittest.main(argv=[__file__] + rest)
