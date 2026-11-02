#!/usr/bin/env python3
"""Run pinned-source adapter tests and isolated real resolver-body fixtures.

This executes the generated production FindManifest body with a tiny filesystem/
PathService adapter. It does not launch hosts, parse user manifests, or claim a
Chromium runtime test. Native GTest cases are also included in the source patch.
"""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("adapter", ROOT / "apply_native_messaging_adapter.py")
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


class AdapterTests(unittest.TestCase):
    def test_pinned_generation_is_repeatable(self):
        self.assertEqual(adapter.generated(self.originals), adapter.generated(self.originals))

    def test_source_drift_is_rejected(self):
        inputs = dict(self.originals)
        inputs[adapter.SOURCE] = inputs[adapter.SOURCE].replace('}  // namespace\n', '}  // modified namespace\n')
        with self.assertRaisesRegex(SystemExit, 'source drift'):
            adapter.generated(inputs)

    def test_original_launcher_validation_is_untouched(self):
        output = adapter.generated(self.originals)
        marker = '// static\nstd::optional<LaunchContext::ProcessState>'
        self.assertEqual(self.originals[adapter.SOURCE].split(marker)[1], output[adapter.SOURCE].split(marker)[1])
        self.assertIn('friend class NativeMessagingManifestPathsTest;', output[adapter.HEADER])
        self.assertEqual(output[adapter.TEST].count('TEST_F(NativeMessagingManifestPathsTest,'), 5)

    def test_actual_resolver_body_in_isolated_filesystem(self):
        source = adapter.generated(self.originals)[adapter.SOURCE]
        body = source[source.index('namespace extensions {'):source.index('// static\nstd::optional<LaunchContext::ProcessState>')]
        with tempfile.TemporaryDirectory(prefix='zacro-messaging-resolver-') as directory:
            root = Path(directory)
            cpp = root / 'resolver.cc'
            cpp.write_text(PRELUDE + body + '\n} // namespace extensions\n' + FIXTURES)
            binary = root / 'resolver'
            subprocess.run(['xcrun', 'clang++', '-std=c++20', '-O0', str(cpp), '-o', str(binary)], check=True)
            output = subprocess.check_output([str(binary), str(root / 'isolated-files')], text=True)
            self.assertEqual(output.strip(), '12 isolated production resolver checks passed')


PRELUDE = r'''
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#define IS_MAC 1
#define BUILDFLAG(name) name
namespace fs = std::filesystem;
fs::path sandbox;
namespace base {
enum { DIR_HOME = 1 };
struct FilePath {
  fs::path path;
  FilePath() = default;
  FilePath(const char* value): path(value) {}
  FilePath(fs::path value): path(std::move(value)) {}
  FilePath Append(const std::string& value) const { return FilePath(path / value); }
  bool empty() const { return path.empty(); }
};
fs::path Physical(const fs::path& path) {
  const fs::path system("/Library/Google/Chrome/NativeMessagingHosts");
  if (path.parent_path() == system) return sandbox / "system-chrome" / path.filename();
  if (path.string().starts_with(sandbox.string() + "/")) return path;
  throw std::runtime_error("Fixture tried to inspect a real path: " + path.string());
}
bool PathExists(const FilePath& path) { return fs::exists(Physical(path.path)); }
struct PathService {
  static inline std::map<int, FilePath> paths;
  static bool Get(int key, FilePath* out) {
    auto entry = paths.find(key);
    if (entry == paths.end()) return false;
    *out = entry->second; return true;
  }
};
}
namespace chrome { enum { DIR_USER_NATIVE_MESSAGING = 2, DIR_NATIVE_MESSAGING = 3 }; }
namespace extensions {
class LaunchContext {
 public:
  static base::FilePath FindManifest(const std::string&, bool, std::string&);
};
}
'''

FIXTURES = r'''
int main(int argc, char** argv) {
  if (argc != 2) return 2;
  sandbox = argv[1]; fs::create_directories(sandbox);
  const std::string name = "com.zacro.isolated_fixture";
  const auto home = sandbox / "home";
  const auto own = sandbox / "configured-user" / (name + ".json");
  const auto chromium = home / "Library/Application Support/Chromium/NativeMessagingHosts" / (name + ".json");
  const auto chrome_user = home / "Library/Application Support/Google/Chrome/NativeMessagingHosts" / (name + ".json");
  const auto system = sandbox / "configured-system" / (name + ".json");
  const auto chrome_system = fs::path("/Library/Google/Chrome/NativeMessagingHosts") / (name + ".json");
  base::PathService::paths = {{base::DIR_HOME, home},
      {chrome::DIR_USER_NATIVE_MESSAGING, own.parent_path()},
      {chrome::DIR_NATIVE_MESSAGING, system.parent_path()}};
  int checks = 0;
  auto expect = [&](bool allowed, const fs::path& path) {
    std::string error;
    auto result = extensions::LaunchContext::FindManifest(name, allowed, error);
    if (result.path != path || (path.empty() && error.empty())) {
      throw std::runtime_error("Wrong selected registration: " + result.path.string());
    }
    ++checks;
  };
  auto write = [&](const fs::path& path) {
    auto physical = base::Physical(path); fs::create_directories(physical.parent_path());
    std::ofstream file(physical); file << "invalid manifest intentionally stops fallback";
  };
  expect(true, {}); expect(false, {});
  write(chrome_system); expect(true, chrome_system);
  write(system); expect(true, system);
  write(chrome_user); expect(true, chrome_user);
  write(chromium); expect(true, chromium);
  write(own); expect(true, own);
  expect(false, system);
  fs::remove(system); expect(false, chrome_system);
  fs::remove(base::Physical(chrome_system)); expect(false, {});
  base::PathService::paths.erase(base::DIR_HOME);
  expect(true, own);
  fs::remove(own); expect(true, {});
  std::cout << checks << " isolated production resolver checks passed\n";
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--chromium-root', required=True, type=Path)
    args = parser.parse_args()
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=args.chromium_root, text=True).strip()
    if revision != adapter.PIN:
        raise SystemExit('This fixture requires the pinned Chromium source.')
    AdapterTests.originals = {path: subprocess.check_output(['git', 'show', 'HEAD:' + path], cwd=args.chromium_root, text=True)
                              for path in adapter.PATHS}
    unittest.main(argv=['native-messaging-adapter'], verbosity=2)


if __name__ == '__main__':
    main()
