#!/usr/bin/env python3
"""Pinned native hooks for a host-owned tab/window model.

All existing extension factories, feature permissions, quotas and validation
remain in Chromium. The native hook can defer selected functions only after
PreRunValidation. It is never reachable from page JavaScript or a network port.
"""
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
PATHS = ("extensions/browser/extension_function.h", "extensions/browser/extension_function.cc",
         "extensions/browser/event_router.h", "extensions/browser/event_router.cc",
         "chrome/browser/extensions/extension_tab_util.h", "chrome/browser/extensions/extension_tab_util.cc",
         "chrome/browser/extensions/api/messaging/chrome_messaging_delegate.cc",
         "chrome/browser/extensions/api/debugger/debugger_api.cc",
         "components/download/internal/common/download_utils.cc",
         "extensions/browser/api/runtime/runtime_api.h", "extensions/browser/api/runtime/runtime_api.cc")

def replace(text, old, new):
    if text.count(old) != 1:
        raise SystemExit(f"Pinned topology source drift: {old[:100]!r}")
    return text.replace(old, new)

def generated(originals):
    h, c, eh, ec = (originals[p] for p in PATHS[:4])
    h = replace(h, "  void SetArgs(base::ListValue args);", """  void SetArgs(base::ListValue args);

  using NativeResponse = base::OnceCallback<void(base::ListValue, std::string)>;
  using NativeDispatcher = base::RepeatingCallback<bool(
      ExtensionFunction*, const base::ListValue&, NativeResponse)>;
  static void SetNativeDispatcher(NativeDispatcher dispatcher);""")
    h = replace(h, "  static void SetNativeDispatcher(NativeDispatcher dispatcher);", """  static void SetNativeDispatcher(NativeDispatcher dispatcher);
  // Trusted native dispatcher only. The original function parses and validates
  // these arguments again when it resumes its unchanged Chromium Run().
  void ReplaceNativeArguments(base::ListValue args);""")
    c = replace(c, "ExtensionFunction::ResponseAction ExtensionFunction::RunWithValidation() {", """namespace {
ExtensionFunction::NativeDispatcher& NativeFunctionDispatcher() {
  static base::NoDestructor<ExtensionFunction::NativeDispatcher> callback;
  return *callback;
}
}  // namespace

void ExtensionFunction::SetNativeDispatcher(NativeDispatcher dispatcher) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  NativeFunctionDispatcher() = std::move(dispatcher);
}

void ExtensionFunction::ReplaceNativeArguments(base::ListValue args) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  args_ = std::move(args);
}

ExtensionFunction::ResponseAction ExtensionFunction::RunWithValidation() {""")
    c = replace(c, "  return Run();\n}", """  auto& native = NativeFunctionDispatcher();
  if (native && native.Run(this, args(), base::BindOnce(
      [](scoped_refptr<ExtensionFunction> function, base::ListValue results,
         std::string error) {
        if (function->did_respond()) return;
        function->Respond(error.empty() ? function->ArgumentList(std::move(results))
                                       : function->Error(std::move(error)));
      }, base::WrapRefCounted(this)))) {
    return did_respond() ? AlreadyResponded() : RespondLater();
  }
  return Run();
}""")
    eh = replace(eh, '#include "base/compiler_specific.h"', '#include "base/compiler_specific.h"\n#include "base/callback_list.h"')
    eh = replace(eh, "  // Gets the EventRouter for `browser_context`.", """  // Browser-process topology ownership. Returning false suppresses physical
  // implementation-window events; native host events retain normal routing.
  using NativeEventFilter = base::RepeatingCallback<bool(
      content::BrowserContext*, Event&, const std::string&)>;
  static void SetNativeEventFilter(NativeEventFilter filter);
  base::CallbackListSubscription ObserveNativeListeners(
      base::RepeatingCallback<void(const std::string&)> observer) {
    return native_listener_changes_.Add(std::move(observer));
  }

  // Gets the EventRouter for `browser_context`.""")
    eh = replace(eh, "  base::WeakPtrFactory<EventRouter> weak_factory_{this};", "  base::RepeatingCallbackList<void(const std::string&)> native_listener_changes_;\n  base::WeakPtrFactory<EventRouter> weak_factory_{this};")
    for name in ("Added", "Removed", "Updated"):
        old = "void EventRouter::OnListener" + name + "(const EventListener* listener) {"
        ec = replace(ec, old, old + '\n  native_listener_changes_.Notify(listener->event_name());')
    eh = replace(eh, "  // The event to dispatch.\n  const std::string event_name;", "  // The event to dispatch.\n  const std::string event_name;\n\n  bool native_host_topology = false;")
    eh = replace(eh, "  const base::ListValue& args() const { return event_args_->data; }", """  const base::ListValue& args() const { return event_args_->data; }
  void ReplaceNativeArguments(base::ListValue args) {
    event_args_ = base::MakeRefCounted<EventArgs>(std::move(args));
  }""")
    ec = replace(ec, '#include "base/notreached.h"', '#include "base/notreached.h"\n#include "base/no_destructor.h"')
    ec = replace(ec, "void EventRouter::DispatchEventImpl(const std::string& restrict_to_extension_id,", """namespace {
EventRouter::NativeEventFilter& NativeTopologyEventFilter() {
  static base::NoDestructor<EventRouter::NativeEventFilter> callback;
  return *callback;
}
}  // namespace

void EventRouter::SetNativeEventFilter(NativeEventFilter filter) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  NativeTopologyEventFilter() = std::move(filter);
}

void EventRouter::DispatchEventImpl(const std::string& restrict_to_extension_id,""")
    ec = replace(ec, "  event->dispatch_start_time = base::TimeTicks::Now();\n  DCHECK(event);", """  DCHECK(event);
  auto& native = NativeTopologyEventFilter();
  if (native && !native.Run(browser_context_, *event, restrict_to_extension_id)) return;
  event->dispatch_start_time = base::TimeTicks::Now();""")
    ec = replace(ec, "  copy->exclude_process_id = exclude_process_id;", "  copy->native_host_topology = native_host_topology;\n  copy->exclude_process_id = exclude_process_id;")
    th, tc, messaging = (originals[p] for p in PATHS[4:7])
    th = replace(th, '  static constexpr char kTabsKey[] = "tabs";', '''  static constexpr char kTabsKey[] = "tabs";
  using NativeTabDecorator = base::RepeatingCallback<bool(
      content::WebContents*, api::tabs::Tab*)>;
  static void SetNativeTabDecorator(NativeTabDecorator decorator);
  static bool IsVisibleToNativeBrowserModel(content::WebContents* contents);''')
    tc = replace(tc, '#include "chrome/browser/extensions/extension_tab_util.h"',
        '#include "chrome/browser/extensions/extension_tab_util.h"\n#include "base/no_destructor.h"')
    tc = replace(tc, "int ExtensionTabUtil::GetWindowId(BrowserWindowInterface* browser) {", '''namespace {
ExtensionTabUtil::NativeTabDecorator& NativeBrowserTabDecorator() {
  static base::NoDestructor<ExtensionTabUtil::NativeTabDecorator> callback;
  return *callback;
}
}  // namespace

void ExtensionTabUtil::SetNativeTabDecorator(NativeTabDecorator decorator) {
  NativeBrowserTabDecorator() = std::move(decorator);
}

bool ExtensionTabUtil::IsVisibleToNativeBrowserModel(content::WebContents* contents) {
  auto& decorator = NativeBrowserTabDecorator();
  return !decorator || decorator.Run(contents, nullptr);
}

int ExtensionTabUtil::GetWindowId(BrowserWindowInterface* browser) {''')
    tc = replace(tc, "  ScrubTabForExtension(extension, contents, &tab_object, scrub_tab_behavior);", '''  auto& decorator = NativeBrowserTabDecorator();
  if (decorator && !decorator.Run(contents, &tab_object)) {
    tab_object.id = api::tabs::TAB_ID_NONE;
    tab_object.window_id = -1;
    tab_object.index = -1;
    tab_object.active = false;
    tab_object.selected = false;
    tab_object.highlighted = false;
  }
  ScrubTabForExtension(extension, contents, &tab_object, scrub_tab_behavior);''')
    messaging = replace(messaging, "  if (web_contents && ExtensionTabUtil::GetTabId(web_contents) >= 0) {", '''  if (web_contents && ExtensionTabUtil::GetTabId(web_contents) >= 0 &&
      ExtensionTabUtil::IsVisibleToNativeBrowserModel(web_contents)) {''')
    debugger = originals[PATHS[7]]
    debugger = replace(debugger, """bool ExtensionMayAttachToWebContents(const Extension& extension,
                                     Profile* extension_profile,
                                     WebContents& web_contents,
                                     std::string* error) {
""", """bool ExtensionMayAttachToWebContents(const Extension& extension,
                                     Profile* extension_profile,
                                     WebContents& web_contents,
                                     std::string* error) {
  if (ExtensionTabUtil::GetTabId(&web_contents) >= 0 &&
      !ExtensionTabUtil::IsVisibleToNativeBrowserModel(&web_contents)) {
    *error = manifest_errors::kCannotAccessPage;
    return false;
  }
""")
    debugger = replace(debugger, """    result.Append(SerializeTarget(host));""", """    // Native host management/maintenance documents are implementation details,
    // not extension-visible tabs. Real offscreen and extension popup contexts
    // without a SessionTabID retain Chromium's original visibility checks.
    if (auto* contents = host->GetWebContents(); contents &&
        ExtensionTabUtil::GetTabId(contents) >= 0 &&
        !ExtensionTabUtil::IsVisibleToNativeBrowserModel(contents)) {
      continue;
    }
    result.Append(SerializeTarget(host));""")
    downloads = originals[PATHS[8]]
    downloads = replace(downloads, '#include "build/build_config.h"', '#include "build/build_config.h"\n#if BUILDFLAG(IS_MAC)\n#include <errno.h>\n#include <stdio.h>\n#endif')
    downloads = replace(downloads, "static_cast<int>(to_path.value().length()) >=", "static_cast<int>(display_name.value().length()) >")
    downloads = replace(downloads, """  return base::Move(from_path, to_path)
             ? DownloadItem::DownloadRenameResult::SUCCESS
             : DownloadItem::DownloadRenameResult::FAILURE_NAME_INVALID;""", """#if BUILDFLAG(IS_MAC)
  // PathExists is advisory. A different process can create the destination
  // between that check and rename; never overwrite it during native rename.
  if (renamex_np(from_path.value().c_str(), to_path.value().c_str(), RENAME_EXCL) == 0)
    return DownloadItem::DownloadRenameResult::SUCCESS;
  return errno == EEXIST ? DownloadItem::DownloadRenameResult::FAILURE_NAME_CONFLICT
                        : DownloadItem::DownloadRenameResult::FAILURE_NAME_INVALID;
#else
  return base::Move(from_path, to_path)
             ? DownloadItem::DownloadRenameResult::SUCCESS
             : DownloadItem::DownloadRenameResult::FAILURE_NAME_INVALID;
#endif""")
    runtime_h, runtime_c = (originals[p] for p in PATHS[9:11])
    runtime_h = replace(runtime_h, "  RuntimeGetContextsFunction();", """  using NativeContextDecorator = base::RepeatingCallback<bool(
      content::WebContents*, api::runtime::ExtensionContext*)>;
  static void SetNativeContextDecorator(NativeContextDecorator decorator);
  RuntimeGetContextsFunction();""")
    runtime_c = replace(runtime_c, '#include "base/notreached.h"', '#include "base/notreached.h"\n#include "base/no_destructor.h"')
    runtime_c = replace(runtime_c, "RuntimeGetContextsFunction::RuntimeGetContextsFunction() = default;", """namespace {
RuntimeGetContextsFunction::NativeContextDecorator& NativeRuntimeContextDecorator() {
  static base::NoDestructor<RuntimeGetContextsFunction::NativeContextDecorator> callback;
  return *callback;
}
}  // namespace

void RuntimeGetContextsFunction::SetNativeContextDecorator(NativeContextDecorator decorator) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  NativeRuntimeContextDecorator() = std::move(decorator);
}

RuntimeGetContextsFunction::RuntimeGetContextsFunction() = default;""")
    runtime_c = replace(runtime_c, "    results.push_back(std::move(context));", """    auto& native = NativeRuntimeContextDecorator();
    if (native && !native.Run(web_contents, &context)) continue;
    results.push_back(std::move(context));""")
    return dict(zip(PATHS, (h, c, eh, ec, th, tc, messaging, debugger, downloads, runtime_h, runtime_c)))

def digest(s):
    return hashlib.sha256(s.encode()).hexdigest()

def source_baselines(source):
    """Reconstruct Chromium plus CEF's pinned upstream changes, never local edits."""
    originals = {p: subprocess.check_output(["git", "show", f"HEAD:{p}"], cwd=source, text=True) for p in PATHS}
    cef = source / "cef"
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=cef, text=True).strip()
    if not revision.startswith(CEF_PIN):
        raise SystemExit(f"Expected CEF {CEF_PIN}, got {revision}")
    upstream = subprocess.check_output(["git", "show", "HEAD:patch/patches/chrome_browser_extensions.patch"], cwd=cef, text=True)
    selected = []
    for section in upstream.split("diff --git ")[1:]:
        target = section.splitlines()[0].split()[0]
        if target in PATHS:
            selected.append("diff --git " + section)
    with tempfile.TemporaryDirectory(prefix="zacro-topology-baseline-") as temp:
        tree = Path(temp)
        for p, text in originals.items():
            destination = tree / p
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(text)
        if selected:
            subprocess.run(["git", "apply", "-p0", "--unsafe-paths", "-"], cwd=tree,
                           input="".join(selected), text=True, check=True)
        return {p: (tree / p).read_text() for p in PATHS}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--chromium-root", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    source = args.chromium_root.resolve()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if revision != PIN:
        raise SystemExit(f"Expected Chromium {PIN}, got {revision}")
    originals = source_baselines(source)
    output = generated(originals)
    receipt = source / "out/zacro-native-topology-adapter.json"
    prior = json.loads(receipt.read_text()) if receipt.exists() else {}
    if prior.get("revision") != PIN:
        prior = {}
    for p, contents in output.items():
        current = (source / p).read_text()
        if current not in (contents, originals[p]) and digest(current) != prior.get("files", {}).get(p):
            raise SystemExit(f"Refusing to overwrite unrelated edits: {p}")
    patch = "".join("".join(difflib.unified_diff(originals[p].splitlines(True), contents.splitlines(True),
        fromfile="a/" + p, tofile="b/" + p)) for p, contents in output.items())
    (ROOT / "native-topology.patch").write_text(patch)
    if not args.check:
        for p, contents in output.items():
            target = source / p
            if target.read_text() != contents:
                tmp = target.with_suffix(target.suffix + ".zacro-tmp")
                tmp.write_text(contents); tmp.replace(target)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps({"revision": PIN, "files": {p: digest(c) for p, c in output.items()}}, indent=2) + "\n")
    print(f"{'Checked' if args.check else 'Applied'} native topology hooks for Chromium {revision[:12]}")

if __name__ == "__main__":
    main()
