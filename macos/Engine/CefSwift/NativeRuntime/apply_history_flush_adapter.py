#!/usr/bin/env python3
"""Flush renderer history state over the associated channel before native capture."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
PIN = "d0c02bfad08ec92a6ffcf989e53cd995e6381a4c"
CEF_PIN = "4fa4ab516dac"
MOJO = "content/common/frame.mojom"
RENDER_H = "content/renderer/render_frame_impl.h"
RENDER_CC = "content/renderer/render_frame_impl.cc"
HOST_H = "content/browser/renderer_host/render_frame_host_impl.h"
HOST_CC = "content/browser/renderer_host/render_frame_host_impl.cc"
LIFECYCLE_H = "content/browser/renderer_host/page_lifecycle_state_manager.h"
LIFECYCLE_CC = "content/browser/renderer_host/page_lifecycle_state_manager.cc"
PATHS = (MOJO, RENDER_H, RENDER_CC, HOST_H, HOST_CC, LIFECYCLE_H, LIFECYCLE_CC)


def replace(text, old, new):
    if text.count(old) != 1:
        raise SystemExit(f"Pinned History flush source drift: {old[:100]!r}")
    return text.replace(old, new)


def generated(originals):
    output = dict(originals)
    output[MOJO] = replace(output[MOJO], "  // Requests a one-time snapshot of the accessibility tree without enabling", """  // Flush current history/form state using the normal FrameHost.UpdateState
  // security path. The response follows UpdateState on the same associated
  // channel, so browser persistence need not guess the hidden-page timer.
  FlushStateForNativeNavigation() => (bool captured);

  // Requests a one-time snapshot of the accessibility tree without enabling""")
    output[RENDER_H] = replace(output[RENDER_H], "  void SnapshotAccessibilityTree(", """  void FlushStateForNativeNavigation(
      FlushStateForNativeNavigationCallback callback) override;
  void SnapshotAccessibilityTree(""")
    output[RENDER_CC] = replace(output[RENDER_CC], "void RenderFrameImpl::SendUpdateState() {", """void RenderFrameImpl::FlushStateForNativeNavigation(
    FlushStateForNativeNavigationCallback callback) {
  if (!GetWebFrame() || GetWebFrame()->GetCurrentHistoryItem().IsNull()) {
    std::move(callback).Run(false);
    return;
  }
  // This cancels the timer and uses Chromium's existing PageState generation
  // and browser-side file-access/document-sequence validation. Both messages
  // are associated with the same frame IPC channel: the ACK cannot overtake
  // the state update. Frozen documents use the existing lifecycle ACK instead.
  SendUpdateState();
  std::move(callback).Run(true);
}

void RenderFrameImpl::SendUpdateState() {""")
    output[HOST_H] = replace(output[HOST_H], "  // Get HTML data for this RenderFrame by serializing contents on the renderer", """  // Browser-owned session persistence barrier. False means the renderer or
  // document changed; callers must not persist an assumed current snapshot.
  void FlushStateForNativeNavigation(base::OnceCallback<void(bool)> callback);

  // Get HTML data for this RenderFrame by serializing contents on the renderer""")
    output[HOST_CC] = replace(output[HOST_CC], "void RenderFrameHostImpl::RequestAXTreeSnapshot(", """void RenderFrameHostImpl::FlushStateForNativeNavigation(
    base::OnceCallback<void(bool)> callback) {
  if (!IsRenderFrameLive()) {
    std::move(callback).Run(false);
    return;
  }
  auto validated = base::BindOnce(
      [](WeakDocumentPtr document, base::OnceCallback<void(bool)> callback,
         bool captured) {
        auto* frame = document.AsRenderFrameHostIfValid();
        std::move(callback).Run(captured && frame && frame->IsRenderFrameLive());
      }, GetWeakDocumentPtr(), std::move(callback));
  auto* lifecycle = render_view_host()->GetPageLifecycleStateManager();
  if (lifecycle->CalculatePageLifecycleState()->is_frozen) {
    // Frame's queue is frozen too. WillFreezePage sent UpdateState before the
    // lifecycle ACK; await that existing ordered path without thawing the page.
    lifecycle->ConfirmFrozenStateForNativeHistory(std::move(validated));
    return;
  }
  GetMojomFrameInRenderer()->FlushStateForNativeNavigation(std::move(validated));
}

void RenderFrameHostImpl::RequestAXTreeSnapshot(""")
    output[LIFECYCLE_H] = replace(output[LIFECYCLE_H], "  void SetIsFrozen(bool frozen);", """  // Native persistence uses the existing freeze ACK because Frame IPCs cannot
  // run on a frozen document. Never changes the page's desired frozen state.
  void ConfirmFrozenStateForNativeHistory(base::OnceCallback<void(bool)> callback);

  void SetIsFrozen(bool frozen);""")
    output[LIFECYCLE_CC] = replace(output[LIFECYCLE_CC], "void PageLifecycleStateManager::SetIsFrozen(bool frozen) {", """void PageLifecycleStateManager::ConfirmFrozenStateForNativeHistory(
    base::OnceCallback<void(bool)> callback) {
  if (!CalculatePageLifecycleState()->is_frozen ||
      !render_view_host_impl_->GetAssociatedPageBroadcast()) {
    std::move(callback).Run(false);
    return;
  }
  if (last_acknowledged_state_->is_frozen) {
    std::move(callback).Run(true);
    return;
  }
  // This is the same associated PageBroadcast lifecycle message Chromium uses
  // to enter BFCache. Its response is ordered after WillFreezePage/UpdateState.
  SendUpdatesToRendererIfNeeded(nullptr, base::BindOnce(
      [](base::WeakPtr<PageLifecycleStateManager> manager,
         base::OnceCallback<void(bool)> callback) {
        std::move(callback).Run(manager &&
            manager->CalculatePageLifecycleState()->is_frozen &&
            manager->last_acknowledged_state_->is_frozen);
      }, weak_ptr_factory_.GetWeakPtr(), std::move(callback)));
}

void PageLifecycleStateManager::SetIsFrozen(bool frozen) {""")
    return output


def source_baselines(source):
    originals = {p: subprocess.check_output(["git", "show", "HEAD:" + p], cwd=source, text=True) for p in PATHS}
    cef = source / "cef"
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=cef, text=True).strip()
    if not revision.startswith(CEF_PIN):
        raise SystemExit("Unexpected pinned CEF revision: " + revision)
    with tempfile.TemporaryDirectory(prefix="zacro-history-baseline-") as temporary:
        root = Path(temporary)
        for path, contents in originals.items():
            target = root / path; target.parent.mkdir(parents=True, exist_ok=True); target.write_text(contents)
        for patch_name in ["webkit_move_pip", "rfh_navigation_4829483"]:
            patch = subprocess.check_output(["git", "show", "HEAD:patch/patches/" + patch_name + ".patch"], cwd=cef, text=True)
            selected = ["diff --git " + section for section in patch.split("diff --git ")[1:]
                        if section.splitlines()[0].split()[0] in PATHS]
            if not selected:
                raise SystemExit("Pinned CEF history baseline changed: " + patch_name)
            subprocess.run(["git", "apply", "-p0", "--unsafe-paths", "-"], input="".join(selected), cwd=root, text=True, check=True)
        return {p: (root / p).read_text() for p in PATHS}


def digest(contents):
    return hashlib.sha256(contents.encode()).hexdigest()


def validate_current(originals, output, current, prior=None):
    prior = prior or {}
    previous = prior.get("files", {}) if prior.get("revision") == PIN else {}
    for path in PATHS:
        if current[path] not in (originals[path], output[path]) and digest(current[path]) != previous.get(path):
            raise SystemExit("Refusing to overwrite unrelated edits: " + path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chromium-root", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--emit-patch", action="store_true", help="Write the reviewable patch without mutating Chromium.")
    args = parser.parse_args()
    source = args.chromium_root.resolve()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if revision != PIN:
        raise SystemExit(f"Expected pinned Chromium {PIN}, found {revision}")
    originals = source_baselines(source)
    output = generated(originals)
    receipt = source / "out/zacro-history-flush.json"
    prior = json.loads(receipt.read_text()) if receipt.exists() else {}
    validate_current(originals, output, {path: (source / path).read_text() for path in PATHS}, prior)
    patch = "".join("".join(difflib.unified_diff(originals[path].splitlines(True), output[path].splitlines(True),
        fromfile="a/" + path, tofile="b/" + path)) for path in PATHS)
    if args.emit_patch or not args.check:
        (ROOT / "native-history-flush.patch").write_text(patch)
    if not args.check and not args.emit_patch:
        for path, contents in output.items():
            target = source / path
            if target.read_text() != contents:
                temporary = target.with_suffix(target.suffix + ".zacro-tmp")
                temporary.write_text(contents); temporary.replace(target)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps({"revision": PIN, "files": {
            p: digest(c) for p, c in output.items()}}, indent=2) + "\n")
    print(f"{'Emitted' if args.emit_patch else 'Checked' if args.check else 'Applied'} native history state barrier for Chromium {revision[:12]}")


if __name__ == "__main__":
    main()
