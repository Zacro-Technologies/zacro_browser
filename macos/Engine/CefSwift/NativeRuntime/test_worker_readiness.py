#!/usr/bin/env python3
"""Execute the production native discovery loop against lifecycle stand-ins.

Actual service-worker initialization/rejection is covered by the packaged app
fixture. This test checks that the native gate rejects starting/stale workers
before looking up their DevTools target and preserves exact instance identity.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parent

def production_loop():
    source = (ROOT / 'devtools_native_adapter.inc').read_text()
    begin = source.index('    std::string target, worker_token;')
    end = source.index('    auto result = base::DictValue()', begin)
    return source[begin:end]

class WorkerReadinessTests(unittest.TestCase):
    def test_native_readiness_and_unique_context_are_both_required(self):
        source = production_loop()
        self.assertIn('IsLiveRunningServiceWorker(version)', source)
        self.assertIn('IsLiveServiceWorkerWithToken(version, info.token)', source)
        self.assertLess(source.index('IsLiveRunningServiceWorker'), source.index('GetForServiceWorker'))
        self.assertNotIn('GetOrCreateAll', source)
        session = (ROOT.parents[2] / 'Sources/ZacroChromium/ChromeExtensionWorkerSession.swift').read_text()
        self.assertIn('current["workerToken"] as? String == workerToken', session)
        self.assertIn('uniqueContextID: uniqueContextID', session)
        self.assertIn('source == sessionID, method == "Runtime.executionContextCreated"', session)
        # None of the preparation expressions execute JavaScript.
        preparation = session[session.index('func prepareExecutionContext'):session.index('public func evaluate')]
        self.assertNotIn('.evaluate(', preparation)

    def test_exact_native_loop(self):
        if self.source_only: self.skipTest('Native fixture compilation explicitly omitted')
        with tempfile.TemporaryDirectory(prefix='zacro-worker-ready-') as folder:
            root = Path(folder); source = root / 'fixture.cc'; binary = root / 'fixture'
            source.write_text(PRELUDE + '\nbool Select() {\n' + production_loop() + '\nselected = target; selected_token = worker_token; return true;\n}\n' + FIXTURE)
            subprocess.run(['xcrun','clang++','-std=c++20',str(source),'-o',str(binary)],check=True)
            self.assertEqual(subprocess.check_output([str(binary)],text=True).strip(),'9 exact worker lifecycle checks passed')

PRELUDE = r'''
#include <iostream>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
struct Context {} owner, foreign;
struct Token { std::string value; std::string ToString() const { return value; } };
struct Info { std::string script_url; Token token; };
struct Workers;
namespace content {
struct DevToolsAgentHost {
  static constexpr const char* kTypeServiceWorker = "service_worker";
  Context* context = &owner; std::string type = kTypeServiceWorker, url = "extension/worker.js", id = "target";
  Context* GetBrowserContext() { return context; }
  std::string GetType() { return type; } std::string GetURL() { return url; } std::string GetId() { return id; }
  static std::shared_ptr<DevToolsAgentHost> GetForServiceWorker(Workers*, int version);
};
}
struct Workers {
  std::map<int, Info> infos; std::map<int,bool> running; std::map<int,std::string> tokens;
  std::map<int,std::shared_ptr<content::DevToolsAgentHost>> hosts; int lookups = 0;
  const auto& GetRunningServiceWorkerInfos() { return infos; }
  bool IsLiveRunningServiceWorker(int version) { return running[version]; }
  bool IsLiveServiceWorkerWithToken(int version, const Token& token) { return tokens[version] == token.value; }
} workers;
std::shared_ptr<content::DevToolsAgentHost> content::DevToolsAgentHost::GetForServiceWorker(Workers* value, int version) {
  ++value->lookups; return value->hosts[version];
}
struct Extension { std::string id() { return "extension"; } } installed;
namespace extensions::util { Workers* GetServiceWorkerContextForExtensionId(const std::string&,Context*) { return &workers; } }
Context* context = &owner; Extension* extension = &installed;
const std::string script = "extension/worker.js";
int request_id = 3; int* id = &request_id;
std::string selected, selected_token, error;
void ReplyZacro(int, std::initializer_list<int>, const std::string& value) { error = value; }
void require(bool value) { if (!value) throw std::runtime_error("worker readiness assertion"); }
void reset() { workers = {}; selected.clear(); selected_token.clear(); error.clear(); }
void live(int version, const std::string& token) {
  workers.infos[version] = {script,{token}}; workers.running[version] = true; workers.tokens[version] = token;
  workers.hosts[version] = std::make_shared<content::DevToolsAgentHost>();
}
'''
FIXTURE = r'''
int main() {
  reset(); workers.hosts[1] = std::make_shared<content::DevToolsAgentHost>(); Select();
  require(selected.empty() && workers.lookups == 0); // target exists while global URL is uninitialized
  reset(); live(1,"old"); workers.running[1] = false; Select(); require(selected.empty() && workers.lookups == 0);
  reset(); live(1,"old"); workers.tokens[1] = "new"; Select(); require(selected.empty() && workers.lookups == 0);
  reset(); live(1,"old"); workers.infos[1].script_url = "other/worker.js"; Select(); require(selected.empty() && workers.lookups == 0);
  reset(); live(1,"ready"); workers.hosts[1]->context = &foreign; Select(); require(selected.empty());
  reset(); live(1,"ready"); workers.hosts[1]->type = "page"; Select(); require(selected.empty());
  reset(); live(1,"ready"); Select(); require(selected == "target" && selected_token == "ready");
  live(1,"restarted"); Select(); require(selected == "target" && selected_token == "restarted");
  reset(); live(1,"a"); live(2,"b"); Select(); require(!error.empty() && selected.empty());
  std::cout << "9 exact worker lifecycle checks passed\n";
}
'''
if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--source-only',action='store_true'); args,remaining=parser.parse_known_args()
    WorkerReadinessTests.source_only=args.source_only
    unittest.main(argv=[__file__,*remaining])
