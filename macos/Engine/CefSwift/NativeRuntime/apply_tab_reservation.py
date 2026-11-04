#!/usr/bin/env python3
"""Bind dormant native tab IDs before Chromium attaches SessionTabHelper.

Only the native broker can issue a token. Chromium's normal ID allocator stays
authoritative, and callers cannot supply an arbitrary numeric session ID.
"""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
PIN = "d0c02bfad08ec92a6ffcf989e53cd995e6381a4c"
CEF_PIN = "4fa4ab516dac"
HELPER_H = "components/sessions/content/session_tab_helper.h"
HELPER_CC = "components/sessions/content/session_tab_helper.cc"
DELEGATE = "cef/libcef/browser/chrome/chrome_browser_delegate.cc"
HOST = "cef/libcef/browser/chrome/chrome_browser_host_impl.cc"
HEADER = "cef/libcef/browser/devtools/zacro_tab_reservation.h"
BUILD = "components/sessions/BUILD.gn"
TEST = "components/sessions/content/native_session_tab_helper_unittest.cc"
PATHS = (HELPER_H, HELPER_CC, DELEGATE, HOST, BUILD, HEADER, TEST)


def replace(text, old, new):
    if text.count(old) != 1:
        raise SystemExit(f"Pinned tab reservation source drift: {old[:100]!r}")
    return text.replace(old, new)


def generated(originals):
    result = dict(originals)
    result[HELPER_H] = replace(result[HELPER_H], '#include "base/callback_list.h"',
                             '#include <optional>\n\n#include "base/callback_list.h"')
    result[HELPER_H] = replace(result[HELPER_H], "  using DelegateLookup =", """  // Browser-process integration only. The provider may consume an ID already
  // allocated by SessionID::NewUnique for these exact WebContents. Returning
  // nullopt preserves normal Chromium allocation. IDs never change afterward.
  using NativeInitialIDProvider =
      base::RepeatingCallback<std::optional<SessionID>(content::WebContents*)>;
  static void SetNativeInitialIDProvider(NativeInitialIDProvider provider);

  using DelegateLookup =""")
    result[HELPER_CC] = replace(result[HELPER_CC], '#include "base/memory/ptr_util.h"',
                               '#include "base/check.h"\n#include "base/memory/ptr_util.h"\n#include "base/no_destructor.h"')
    result[HELPER_CC] = replace(result[HELPER_CC], '#include "content/public/browser/navigation_controller.h"',
                               '#include "content/public/browser/browser_thread.h"\n#include "content/public/browser/navigation_controller.h"')
    result[HELPER_CC] = replace(result[HELPER_CC], "namespace sessions {", """namespace sessions {
namespace {
SessionTabHelper::NativeInitialIDProvider& NativeInitialIDCallback() {
  static base::NoDestructor<SessionTabHelper::NativeInitialIDProvider> callback;
  return *callback;
}

SessionID InitialSessionID(content::WebContents* contents) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto& provider = NativeInitialIDCallback();
  if (provider) {
    if (auto reserved = provider.Run(contents)) {
      CHECK(reserved->is_valid());
      return *reserved;
    }
  }
  return SessionID::NewUnique();
}
}  // namespace

void SessionTabHelper::SetNativeInitialIDProvider(
    NativeInitialIDProvider provider) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  NativeInitialIDCallback() = std::move(provider);
}
""")
    result[HELPER_CC] = replace(result[HELPER_CC], "session_id_(SessionID::NewUnique()),",
                               "session_id_(InitialSessionID(contents)),")
    result[DELEGATE] = replace(result[DELEGATE], '#include "cef/libcef/browser/devtools/devtools_window_runner.h"',
                              '#include "cef/libcef/browser/devtools/devtools_window_runner.h"\n#include "cef/libcef/browser/devtools/zacro_tab_reservation.h"\n#include "chrome/browser/history/native_history_owner.h"')
    result[DELEGATE] = replace(result[DELEGATE], """void ChromeBrowserDelegate::OnWebContentsCreated(
    content::WebContents* new_contents) {
""", """void ChromeBrowserDelegate::OnWebContentsCreated(
    content::WebContents* new_contents) {
  if (create_params_.extra_info &&
      create_params_.extra_info->HasKey("_zacroTabReservation")) {
    const auto token = create_params_.extra_info
                           ->GetString("_zacroTabReservation").ToString();
    // Initial Create owns this writable copy. Remove in place so every retained
    // create-params copy (and future popup BrowserInfo) loses the one-use token.
    CHECK(create_params_.extra_info->Remove("_zacroTabReservation"));
    // Create preclaims the token on this UI thread before allocating a Browser.
    // The broker cannot revoke a claim before this synchronous consumption.
    CHECK(ZacroConsumeTabReservation(new_contents, token));
  }
""")
    result[DELEGATE] = replace(result[DELEGATE], """  CreateBrowserHostForPopup(new_contents, settings, client, extra_info,
                            std::move(platform_delegate),
                            /*is_devtools_popup=*/false, opener);""", """  // Attach the exact public opener's provisional history token before CEF
  // publishes this child or its first navigation. This grants no logical tab
  // identity or Library publication; durable Core adoption is still required.
  NativeHistoryOwner::RegisterProvisionalPopup(source_contents, opener_id, new_contents);
  CreateBrowserHostForPopup(new_contents, settings, client, extra_info,
                            std::move(platform_delegate),
                            /*is_devtools_popup=*/false, opener);""")
    result[HOST] = replace(result[HOST], '#include "base/logging.h"',
                          '#include "base/functional/bind.h"\n#include "base/functional/callback_helpers.h"\n#include "base/logging.h"')
    result[HOST] = replace(result[HOST], '#include "cef/libcef/browser/thread_util.h"',
                          '#include "cef/libcef/browser/devtools/zacro_tab_reservation.h"\n#include "cef/libcef/browser/thread_util.h"')
    result[HOST] = replace(result[HOST], '#include "chrome/common/pref_names.h"',
                          '#include "chrome/common/pref_names.h"\n#include "content/public/browser/render_frame_host.h"')
    result[HOST] = replace(result[HOST], """CefRefPtr<ChromeBrowserHostImpl> ChromeBrowserHostImpl::Create(
    const CefBrowserCreateParams& params) {
  auto browser = CreateBrowser(params, std::nullopt);
""", """CefRefPtr<ChromeBrowserHostImpl> ChromeBrowserHostImpl::Create(
    const CefBrowserCreateParams& params) {
  CefBrowserCreateParams create_params = params;
  base::ScopedClosureRunner abort_reservation;
  content::BrowserContext* reservation_context = nullptr;
  std::string reservation_token;
  content::WeakDocumentPtr reserved_opener;
  std::optional<url::Origin> reserved_initiator;
  if (params.extra_info && params.extra_info->HasKey("_zacroTabReservation")) {
    if (params.extra_info->GetType("_zacroTabReservation") != VTYPE_STRING) {
      return nullptr;
    }
    const auto token = params.extra_info
                           ->GetString("_zacroTabReservation").ToString();
    auto* context = CefRequestContextImpl::GetProfile(params.request_context);
    if (!context || !ZacroClaimTabReservation(context, token)) {
      return nullptr;
    }
    abort_reservation.ReplaceClosure(base::BindOnce(
        &ZacroAbortTabReservation, base::Unretained(context), token));
    reservation_context = context;
    reservation_token = token;
    if (!ZacroResolveTabReservationOpener(context, token, &reserved_opener,
                                          &reserved_initiator)) {
      return nullptr;
    }
    // Preserve the caller's dictionary, including a read-only input. Every
    // internal copy shares this writable dictionary until the token is removed
    // by OnWebContentsCreated, before BrowserInfo exposes extra_info.
    create_params.extra_info = params.extra_info->Copy(false);
    if (!create_params.extra_info) {
      return nullptr;
    }
  }
  auto browser = CreateBrowser(create_params, std::nullopt);
  if (!browser) {
    return nullptr;
  }
""")
    result[HOST] = replace(result[HOST], """  chrome::AddTabAt(browser, url, /*index=*/TabStripModel::kNoTab,
                   /*foreground=*/true);
""", """  // Creating the native Browser can invoke host callbacks. Revalidate the
  // pending request, installation and original document before navigation.
  if (reservation_context &&
      !ZacroResolveTabReservationOpener(reservation_context, reservation_token,
                                        &reserved_opener, &reserved_initiator)) {
    browser->GetWindow()->Close();
    return nullptr;
  }
  if (reserved_initiator) {
    auto* opener = reserved_opener.AsRenderFrameHostIfValid();
    if (!opener) {
      browser->GetWindow()->Close();
      return nullptr;
    }
    // Match WindowsCreateFunction: establish the original caller's browsing
    // instance and opener when WebContents is created, never after navigation.
    NavigateParams navigate_params(browser, url, ui::PAGE_TRANSITION_LINK);
    navigate_params.disposition = WindowOpenDisposition::NEW_FOREGROUND_TAB;
    navigate_params.tabstrip_index = TabStripModel::kNoTab;
    navigate_params.initiator_origin = reserved_initiator;
    navigate_params.opener = opener;
    navigate_params.source_site_instance = opener->GetSiteInstance();
    navigate_params.web_app_navigation_data.emplace();
    navigate_params.web_app_navigation_data->SetNavigationCapturingForceOff(true);
    ::Navigate(&navigate_params);
  } else {
    chrome::AddTabAt(browser, url, /*index=*/TabStripModel::kNoTab,
                     /*foreground=*/true);
  }
""")
    result[HOST] = replace(result[HOST], """  CHECK(web_contents);

  // The associated ChromeBrowserHostImpl.""", """  if (!web_contents) {
    browser->GetWindow()->Close();
    return nullptr;
  }

  // The associated ChromeBrowserHostImpl.""")
    result[BUILD] = replace(result[BUILD], '      "content/navigation_task_id_unittest.cc",',
                           '      "content/navigation_task_id_unittest.cc",\n      "content/native_session_tab_helper_unittest.cc",')
    result[HEADER] = """// Native-only, profile-scoped dormant tab materialization.
#ifndef CEF_LIBCEF_BROWSER_DEVTOOLS_ZACRO_TAB_RESERVATION_H_
#define CEF_LIBCEF_BROWSER_DEVTOOLS_ZACRO_TAB_RESERVATION_H_

#include <optional>
#include <string>

#include "content/public/browser/weak_document_ptr.h"
#include "url/origin.h"

namespace content {
class BrowserContext;
class WebContents;
}

// UI thread only. A claim rejects reused, expired and cross-profile tokens.
// Once claimed it cannot be canceled/replaced before synchronous consumption.
bool ZacroClaimTabReservation(content::BrowserContext* context,
                             const std::string& token);
// Resolve only native-authorized windows.create opener requests. Normal tokens
// return true with empty outputs. Recheck after any reentrant host callback;
// false means creation must stop because authorization or document was lost.
bool ZacroResolveTabReservationOpener(
    content::BrowserContext* context, const std::string& token,
    content::WeakDocumentPtr* opener, std::optional<url::Origin>* initiator);
// Consume binds the broker-allocated SessionID to these exact WebContents.
// SessionTabHelper reads that native-owned metadata once during construction.
bool ZacroConsumeTabReservation(content::WebContents* contents,
                               const std::string& token);
// Abort an unconsumed claim after a creation failure; no-op once consumed.
// The logical dormant tab remains and may obtain a fresh one-use token.
void ZacroAbortTabReservation(content::BrowserContext* context,
                             const std::string& token);

#endif  // CEF_LIBCEF_BROWSER_DEVTOOLS_ZACRO_TAB_RESERVATION_H_
"""
    result[TEST] = (ROOT / "tab_reservation_tests.inc").read_text()
    return result


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chromium-root", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    source = args.chromium_root.resolve()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    cef_revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source / "cef", text=True).strip()
    if revision != PIN or not cef_revision.startswith(CEF_PIN):
        raise SystemExit(f"Unexpected source revisions: Chromium {revision}, CEF {cef_revision}")
    originals = {}
    for path in PATHS:
        if path in (HEADER, TEST):
            originals[path] = ""
        else:
            repository = source / "cef" if path.startswith("cef/") else source
            git_path = path.removeprefix("cef/") if path.startswith("cef/") else path
            originals[path] = subprocess.check_output(["git", "show", "HEAD:" + git_path], cwd=repository, text=True)
    output = generated(originals)
    receipt = source / "out/zacro-tab-reservation.json"
    prior = json.loads(receipt.read_text()) if receipt.exists() else {}
    if prior.get("revision") != PIN or prior.get("cef_revision") != cef_revision:
        prior = {}
    for path, generated_text in output.items():
        target = source / path
        current = target.read_text() if target.exists() else ""
        if current not in (originals[path], generated_text) and digest(current) != prior.get("files", {}).get(path):
            raise SystemExit("Refusing to overwrite unrelated edits: " + path)
    patch = "".join("".join(difflib.unified_diff(originals[path].splitlines(True), contents.splitlines(True),
        fromfile="a/" + path if originals[path] else "/dev/null", tofile="b/" + path)) for path, contents in output.items())
    if not args.check:
        (ROOT / "native-tab-reservation.patch").write_text(patch)
        for path, contents in output.items():
            target = source / path
            target.parent.mkdir(parents=True, exist_ok=True)
            if not target.exists() or target.read_text() != contents:
                temporary = target.with_suffix(target.suffix + ".zacro-tmp")
                temporary.write_text(contents)
                temporary.replace(target)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps({"revision": PIN, "cef_revision": cef_revision,
            "files": {p: digest(c) for p, c in output.items()}}, indent=2) + "\n")
    print(f"{'Checked' if args.check else 'Applied'} native tab reservations for Chromium {revision[:12]}")


if __name__ == "__main__":
    main()
