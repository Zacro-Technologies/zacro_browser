#!/usr/bin/env python3
"""Apply checked native/Core history journalling to the pinned Chromium checkout."""
from pathlib import Path
import argparse, subprocess, difflib, hashlib, json
import tempfile
PIN = 'd0c02bfad08ec92a6ffcf989e53cd995e6381a4c'
ROOT = Path(__file__).resolve().parent
DB_DECL = '''  // Checked native mirror queries on the History DB sequence. Error is
  // distinct from successful absence; the owning backend checks COMMIT first.
  enum class NativeVisitPresence { kPresent, kAbsent, kError };
  std::optional<std::string> NativeHistoryGeneration(bool create);
  bool BeginNativeHistoryTableReset();
  bool AdvanceNativeHistoryGeneration();
  NativeVisitPresence CompareNativeHistoryGeneration(const std::string& expected);
  NativeVisitPresence CheckNativeHistoryVisit(const std::string& generation,
      VisitID id, int64_t time_microseconds, const std::string& url,
      const std::string& originator, std::string* title = nullptr);

'''
PROVIDER_DECL = '''  using NativeMirrorDocumentProvider = base::RepeatingCallback<
      std::optional<history::NativeHistoryDocument>(content::WebContents*,
                                                   content::NavigationHandle*)>;
  static void SetNativeMirrorDocumentProvider(NativeMirrorDocumentProvider provider);

'''
PROVIDER_STORAGE = '''HistoryTabHelper::NativeMirrorDocumentProvider& NativeMirrorProvider() {
  static base::NoDestructor<HistoryTabHelper::NativeMirrorDocumentProvider> value;
  return *value;
}

'''
PROVIDER_SET = '''void HistoryTabHelper::SetNativeMirrorDocumentProvider(
    NativeMirrorDocumentProvider provider) {
  CHECK_CURRENTLY_ON(content::BrowserThread::UI);
  NativeMirrorProvider() = std::move(provider);
}

'''
PROVIDER_USE = '''  // The native provider returns data only for an explicitly registered public
  // document. No metadata can originate in a renderer or an extension request.
  if (!web_contents()->GetBrowserContext()->IsOffTheRecord() &&
      navigation_handle->IsInPrimaryMainFrame() &&
      !navigation_handle->IsErrorPage() &&
      add_page_args.url.SchemeIsHTTPOrHTTPS() && NativeMirrorProvider()) {
    add_page_args.native_history_document =
        NativeMirrorProvider().Run(web_contents(), navigation_handle);
  }

'''
BEGIN_NATIVE_TX = '''  auto native_document = request.native_history_document;
  // history.addUrl has no WebContents/navigation token. Its existing native
  // extension API already validated the caller and History permission. Journal
  // that actual added visit as well, including calls from startup workers.
  if (!native_document && request.visit_source == SOURCE_EXTENSION &&
      request.url.SchemeIsHTTPOrHTTPS() && !request.url.has_username() &&
      !request.url.has_password() && request.url.spec().size() <= 8192) {
    NativeHistoryDocument document;
    document.document_token = base::Uuid::GenerateRandomV4().AsLowercaseString();
    document.event_id = base::Uuid::GenerateRandomV4().AsLowercaseString();
    document.producer_epoch = base::Uuid::GenerateRandomV4().AsLowercaseString();
    document.logical_id = "history-api:" + document.event_id;
    document.publish = true;
    native_document = std::move(document);
  }
  if (native_document && !singleton_transaction_) {
    BeginSingletonTransaction();
    if (!singleton_transaction_) native_history_mirror_failed_ = true;
  }

'''
RECORD_NATIVE = '''  // This is the final visit after redirects. The native handoff record and
  // the actual visit belong to the SAME existing History transaction.
  if (native_document && current_visit_was_successfully_added &&
      !db_->RecordNativeMirrorVisit(*native_document,
                                    last_visit_id, request.time)) {
    native_history_mirror_failed_ = true;
  }

'''
def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Missing/ambiguous anchor: ' + repr(old))
    return text.replace(old, new)
CEF_PIN = '4fa4ab516dacf6c49fc7e6e70d2b7ebce29fa35f'
DATABASE_PATHS = (
    'components/history/core/browser/history_database.h',
    'components/history/core/browser/history_database.cc',
    'components/history/core/browser/history_backend.h',
    'components/history/core/browser/history_backend.cc',
    'components/history/core/browser/history_types.h',
    'chrome/browser/history/history_tab_helper.h',
    'chrome/browser/history/history_tab_helper.cc',
    'chrome/browser/history/history_tab_helper_unittest.cc',
    'components/history/core/browser/history_database_unittest.cc',
    'components/history/core/browser/expire_history_backend.cc',
)
BUILD = 'chrome/browser/history/BUILD.gn'
OWNER_H = 'chrome/browser/history/native_history_owner.h'
OWNER_CC = 'chrome/browser/history/native_history_owner.cc'
PATHS = DATABASE_PATHS + (BUILD, OWNER_H, OWNER_CC)

def generated(originals):
    out = dict(originals)
    for path in DATABASE_PATHS:
        changed = originals[path]
        if path.endswith('history_database.h'):
            changed = once(changed, '#include <memory>', '#include <memory>\n#include <optional>\n#include <set>\n#include <string>')
            changed = once(changed, '  sql::Database& GetDBForTesting();', DB_DECL +
                (ROOT / 'history_journal_declarations.h.inc').read_text() +
                (ROOT / 'history_legacy_declarations.h.inc').read_text() +
                (ROOT / 'history_legacy_boundary_declarations.h.inc').read_text() +
                (ROOT / 'history_retention_declarations.h.inc').read_text() + '  sql::Database& GetDBForTesting();')
            changed = once(changed, '  sql::Database db_;', '  int64_t native_history_automatic_expiration_reads_ = 0;\n  bool native_history_legacy_deletion_failed_ = false;\n  sql::Database db_;')
        elif path.endswith('history_database.cc'):
            changed = once(changed, '#include <algorithm>', '#include <algorithm>\n#include <limits>\n#include "crypto/hash.h"\n#include "base/strings/string_number_conversions.h"')
            changed = once(changed, '#include "base/time/time.h"', '#include "base/time/time.h"\n#include "base/uuid.h"\n#include "base/strings/string_number_conversions.h"\n#include "base/strings/string_util.h"')
            methods = '\n'.join((ROOT / name).read_text() for name in [
                'history_database_methods.cc.inc', 'history_journal_methods.cc.inc',
                'history_publication_methods.cc.inc', 'history_legacy_database.cc.inc',
                'history_retention_database.cc.inc', 'history_legacy_boundary_database.cc.inc'])
            changed = once(changed, 'sql::Database& HistoryDatabase::GetDB() {', methods + '\nsql::Database& HistoryDatabase::GetDB() {')
            changed = once(changed, 'bool HistoryDatabase::RecreateAllTablesButURL() {\n',
                'bool HistoryDatabase::RecreateAllTablesButURL() {\n'
                '  // Standalone callers own a real transaction; the normal backend\n'
                '  // already supplies its singleton, which must never be nested.\n'
                '  std::unique_ptr<sql::Transaction> native_reset;\n'
                '  if (!HasActiveTransactions()) {\n'
                '    native_reset = CreateTransaction();\n'
                '    if (!native_reset->Begin()) return false;\n'
                '  }\n'
                '  if (!BeginNativeHistoryTableReset() ||\n'
                '      !RecordNativeLegacyDeletions({{std::nullopt, base::Time(), base::Time::Max(), true}}, true))\n'
                '    return false;\n')
            changed = once(changed, '  if (!InitVisitTable())\n    return false;\n',
                '  if (!InitVisitTable())\n    return false;\n\n'
                '  if (!AdvanceNativeHistoryGeneration()) return false;\n')
            changed = once(changed, '  return true;\n}\n\nvoid HistoryDatabase::Vacuum()',
                '  return !native_reset || native_reset->Commit();\n}\n\nvoid HistoryDatabase::Vacuum()')
        elif path.endswith('history_backend.h'):
            changed = once(changed, '  // Testing -------------------------------------------------------------------',
                '  // Checked DB authority for the native Library projection.\n'
                '  bool FlushForNativeMirror();\n'
                '  bool ReplaceNativeHistoryRetention(const std::vector<NativeHistoryRetention>& identities);\n'
                '  std::optional<std::vector<NativeHistoryLegacyResult>> ImportNativeLegacyHistory(\n'
                '      const std::vector<NativeHistoryLegacyInput>& inputs);\n\n'
                '  // Testing -------------------------------------------------------------------')
            changed = once(changed, '  void Commit();', '  bool native_history_mirror_failed_ = false;\n  bool native_history_importing_ = false;\n\n  void Commit();')
        elif path == 'components/history/core/browser/history_backend.cc':
            changed = once(changed, '#include "base/time/time.h"', '#include "base/time/time.h"\n#include "base/uuid.h"\n#include "base/auto_reset.h"')
            changed = once(changed, '  // Will be filled with the visit ID of the last addition.',
                BEGIN_NATIVE_TX + '  // Will be filled with the visit ID of the last addition.')
            changed = once(changed, '  if (current_visit_was_successfully_added && request.context_annotations) {',
                RECORD_NATIVE + '  if (current_visit_was_successfully_added && request.context_annotations) {')
            changed = once(changed, 'void HistoryBackend::Commit() {',
                (ROOT / 'history_backend_flush.cc.inc').read_text() + '\n' +
                (ROOT / 'history_legacy_backend.cc.inc').read_text() + '\n' +
                (ROOT / 'history_retention_backend.cc.inc').read_text() + '\nvoid HistoryBackend::Commit() {')
            changed = once(changed, '  bool success = singleton_transaction_->Commit();',
                '  bool success = singleton_transaction_->Commit();\n'
                '  // Upstream privacy clears do not return this failure to their\n'
                '  // callers. A later empty commit cannot certify that clear.\n'
                '  if (!success) native_history_mirror_failed_ = true;')
            changed = once(changed, '  db_->RecreateAllTablesButURL();',
                '  if (!db_->RecreateAllTablesButURL())\n    native_history_mirror_failed_ = true;')
            changed = once(changed, '''    NotifyURLVisited(VisitedURLInfo(
        url_info, visit_info, response_code_category, local_navigation_id));''', '''    // Historical import matches AddPagesWithDetails: update the native URL
    // cache without pretending the imported visit just happened in a page.
    if (!native_history_importing_) {
      NotifyURLVisited(VisitedURLInfo(
          url_info, visit_info, response_code_category, local_navigation_id));
    }''')
        elif path.endswith('history_types.h'):
            changed = once(changed, 'struct HistoryAddPageArgs {',
                (ROOT / 'history_document_types.h.inc').read_text() +
                (ROOT / 'history_legacy_types.h.inc').read_text() + 'struct HistoryAddPageArgs {')
            changed = once(changed, '  std::optional<int64_t> local_navigation_id;\n  GURL referrer;',
                '  std::optional<int64_t> local_navigation_id;\n'
                '  std::optional<NativeHistoryDocument> native_history_document;\n  GURL referrer;')
        elif path.endswith('history_tab_helper.h'):
            changed = once(changed, '#include "base/callback_list.h"',
                '#include "base/callback_list.h"\n#include "base/functional/callback.h"')
            changed = once(changed, '  HistoryTabHelper(const HistoryTabHelper&) = delete;',
                PROVIDER_DECL + '  HistoryTabHelper(const HistoryTabHelper&) = delete;')
        elif path.endswith('history_tab_helper_unittest.cc'):
            changed = once(changed, '#include "chrome/browser/history/history_tab_helper.h"',
                '#include "chrome/browser/history/history_tab_helper.h"\n#include "chrome/browser/history/native_history_owner.h"\n#include "base/functional/callback_helpers.h"')
            changed += '\n' + (ROOT / 'history_owner_unittest.cc.inc').read_text()
        elif path.endswith('history_database_unittest.cc'):
            changed = once(changed, '#include "sql/init_status.h"', '#include "sql/init_status.h"\n#include "sql/transaction.h"')
            changed = once(changed, '}  // namespace history\n',
                (ROOT / 'history_mirror_unittest.cc.inc').read_text() + '\n' +
                (ROOT / 'history_legacy_unittest.cc.inc').read_text() + '\n' +
                (ROOT / 'history_retention_unittest.cc.inc').read_text() + '\n' +
                (ROOT / 'history_legacy_boundary_unittest.cc.inc').read_text() + '\n' +
                (ROOT / 'history_visit_identity_unittest.cc.inc').read_text() + '\n}  // namespace history\n')
        elif path.endswith('expire_history_backend.cc'):
            changed = once(changed, '''    db->GetAllVisitsInRange(base::Time(), end_time, kNoAppIdFilter, max_visits,
                            visits);''', '''    if (!db->ReadNativeExpiringVisits(base::Time(), end_time, max_visits,
                                     std::nullopt, visits)) return true;''')
            changed = once(changed, '''    db->GetVisitsInRangeForTransition(begin_time, early_end_time,
                                      max_visits,
                                      ui::PAGE_TRANSITION_AUTO_SUBFRAME,
                                      visits);''', '''    if (!db->ReadNativeExpiringVisits(begin_time, early_end_time, max_visits,
                                     ui::PAGE_TRANSITION_AUTO_SUBFRAME, visits)) return true;''')
            changed = once(changed, '  DeleteEffects effects;\n  for (const auto& url : urls) {',
                '  std::vector<NativeHistoryDeletionScope> native_scopes;\n'
                '  for (const auto& url : urls) native_scopes.push_back({url, base::Time(), end_time, true});\n'
                '  if (!main_db_->RecordNativeLegacyDeletions(native_scopes)) return;\n'
                '  DeleteEffects effects;\n  for (const auto& url : urls) {')
            changed = once(changed, '  // Find the affected visits and delete them.\n  VisitVector visits;\n  main_db_->GetAllVisitsInRange(begin_time, end_time, restrict_app_id, 0,',
                '  // Native legacy rows have no app_id; app-only deletion cannot match them.\n'
                '  if (!restrict_app_id) {\n'
                '    std::vector<NativeHistoryDeletionScope> native_scopes;\n'
                '    if (restrict_urls.empty()) native_scopes.push_back({std::nullopt, begin_time, end_time, false});\n'
                '    else for (const auto& url : restrict_urls) native_scopes.push_back({url, begin_time, end_time, false});\n'
                '    if (!main_db_->RecordNativeLegacyDeletions(native_scopes)) return;\n'
                '  }\n'
                '  // Find the affected visits and delete them.\n  VisitVector visits;\n  main_db_->GetAllVisitsInRange(begin_time, end_time, restrict_app_id, 0,')
            changed = once(changed, '  main_db_->GetVisitsForTimes(times, &visits);',
                '  std::vector<NativeHistoryDeletionScope> native_scopes;\n'
                '  for (const auto& time : times)\n'
                '    native_scopes.push_back({std::nullopt, time, time + base::Microseconds(1), false});\n'
                '  if (!main_db_->RecordNativeLegacyDeletions(native_scopes)) return;\n'
                '  main_db_->GetVisitsForTimes(times, &visits);')
        else:
            changed = once(changed, '#include "base/metrics/histogram_macros.h"',
                '#include "base/metrics/histogram_macros.h"\n#include "base/no_destructor.h"')
            changed = once(changed, '#include "content/public/browser/navigation_controller.h"',
                '#include "content/public/browser/browser_context.h"\n#include "content/public/browser/browser_thread.h"\n#include "content/public/browser/navigation_controller.h"')
            changed = once(changed, 'using content::NavigationEntry;', PROVIDER_STORAGE + 'using content::NavigationEntry;')
            changed = once(changed, 'HistoryTabHelper::HistoryTabHelper(WebContents* web_contents)',
                PROVIDER_SET + 'HistoryTabHelper::HistoryTabHelper(WebContents* web_contents)')
            changed = once(changed, '  UpdateHistoryForNavigation(add_page_args);', PROVIDER_USE + '  UpdateHistoryForNavigation(add_page_args);')
        out[path] = changed
    out[BUILD] = once(out[BUILD], '    "history_tab_helper.h",', '    "history_tab_helper.h",\n    "native_history_owner.h",')
    out[BUILD] = once(out[BUILD], '    "history_tab_helper.cc",', '    "history_tab_helper.cc",\n    "native_history_owner.cc",')
    out[OWNER_H] = (ROOT / 'native_history_owner.h.in').read_text()
    out[OWNER_CC] = (ROOT / 'native_history_owner.cc.in').read_text()
    return out

def source_baselines(source):
    return {path: '' if path in (OWNER_H, OWNER_CC) else subprocess.check_output(
        ['git', 'show', PIN + ':' + path], cwd=source, text=True) for path in PATHS}

def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()

def validate_current(originals, output, current, prior=None):
    previous = (prior or {}).get('files', {}) if (prior or {}).get('revision') == PIN else {}
    for path in PATHS:
        if current[path] not in (originals[path], output[path]) and digest(current[path]) != previous.get(path):
            raise ValueError('Refusing unrelated native history edits: ' + path)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--chromium-root', type=Path, required=True)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--emit-patch', action='store_true')
    parser.add_argument('--output-tree', type=Path)
    args = parser.parse_args()
    source = args.chromium_root.resolve()
    for repo, pin in [(source, PIN), (source / 'cef', CEF_PIN)]:
        if subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip() != pin:
            raise ValueError('Wrong pinned history source revision')
    originals = source_baselines(source)
    output = generated(originals)
    receipt = source / 'out/zacro-native-history-mirror.json'
    prior = json.loads(receipt.read_text()) if receipt.exists() else None
    current = {path: (source / path).read_text() if (source / path).exists() else '' for path in PATHS}
    validate_current(originals, output, current, prior)
    if args.emit_patch or not (args.check or args.output_tree):
        (ROOT / 'native-history-mirror.patch').write_text(''.join(''.join(difflib.unified_diff(
            originals[path].splitlines(True), output[path].splitlines(True),
            fromfile='a/' + path if originals[path] else '/dev/null', tofile='b/' + path)) for path in PATHS))
    if args.output_tree:
        for path, content in output.items():
            destination = args.output_tree / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(content)
    if not (args.check or args.emit_patch or args.output_tree):
        for path, content in output.items():
            destination = source / path
            if current[path] != content:
                destination.parent.mkdir(parents=True, exist_ok=True)
                temporary = destination.with_suffix(destination.suffix + '.zacro-tmp')
                temporary.write_text(content); temporary.replace(destination)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps({'revision': PIN, 'cefRevision': CEF_PIN,
            'files': {path: digest(content) for path, content in output.items()}}, indent=2) + '\n')
    print('Validated native history mirror' if args.check or args.emit_patch or args.output_tree else 'Applied native history mirror')

if __name__ == '__main__':
    main()
