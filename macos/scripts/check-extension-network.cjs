#!/usr/bin/env node
/* Opt-in fixture contract check in real Chrome; this is NOT Zacro acceptance. */
const { chromium } = require("playwright");
const fs = require("node:fs/promises");
const path = require("node:path");
const { spawn } = require("node:child_process");
const readline = require("node:readline");

function options() {
  const result = {};
  for (let i = 2; i < process.argv.length; i += 2) {
    const name = process.argv[i], value = process.argv[i + 1];
    if (!["--chrome", "--output"].includes(name) || !value) {
      throw new Error("Usage: node macos/scripts/check-extension-network.cjs --chrome /absolute/path/to/chrome [--output directory]");
    }
    result[name.slice(2)] = value;
  }
  if (!result.chrome || !path.isAbsolute(result.chrome)) throw new Error("Provide an explicit absolute --chrome executable path.");
  return result;
}

async function timeout(promise, milliseconds, message) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(message)), milliseconds);
    })]);
  } finally { clearTimeout(timer); }
}

async function main() {
  const args = options(), nativeRoot = path.resolve(__dirname, "..");
  const output = path.resolve(args.output || path.join(nativeRoot, ".build/verification/network-chrome-baseline"));
  await fs.access(args.chrome); await fs.mkdir(output, { recursive: true });
  const temporary = await fs.mkdtemp(path.join(output, "run-"));
  let context, server, serverLines;
  let report = { browserBaselineOnly: true, zacroRuntimeVerified: false, passed: false };
  try {
    const fixture = path.join(temporary, "extension");
    await fs.cp(path.join(__dirname, "fixtures/native-extension"), fixture, { recursive: true });
    // Use the same fixture as the app acceptance runner without adding grants
    // or rewriting its service worker for this baseline.
    const manifest = JSON.parse(await fs.readFile(path.join(fixture, "manifest.json"), "utf8"));
    for (const required of ["declarativeNetRequestWithHostAccess", "webRequest"]) {
      if (!manifest.permissions.includes(required)) throw new Error(`Fixture is missing ${required}`);
    }
    const fixtureScript = path.join(__dirname, "check-app.py");
    const python = `import importlib.util,http.server\ns=importlib.util.spec_from_file_location('fixture',${JSON.stringify(fixtureScript)})\nm=importlib.util.module_from_spec(s);s.loader.exec_module(m)\nh=http.server.ThreadingHTTPServer(('127.0.0.1',0),m.Fixture)\nprint(h.server_port,flush=True)\nh.serve_forever()`;
    server = spawn("python3", ["-B", "-u", "-c", python], { stdio: ["ignore", "pipe", "pipe"] });
    server.stderr.on("data", chunk => process.stderr.write(chunk));
    const port = await timeout(new Promise((resolve, reject) => {
      serverLines = readline.createInterface({ input: server.stdout });
      serverLines.once("line", resolve);
      server.once("error", reject);
      server.once("exit", code => reject(new Error("Loopback server exited: " + code)));
    }), 10000, "Loopback server did not start");
    if (!/^\d+$/.test(port)) throw new Error("Invalid loopback server port");
    context = await chromium.launchPersistentContext(path.join(temporary, "profile"), {
      executablePath: args.chrome, headless: true,
      args: ["--enable-unsafe-extension-debugging", "--disable-background-networking", "--no-first-run"],
      ignoreDefaultArgs: ["--disable-extensions", "--disable-component-extensions-with-background-pages"]
    });
    const session = await context.browser().newBrowserCDPSession();
    const version = await session.send("Browser.getVersion");
    report.browser = version.product;
    const extension = await session.send("Extensions.loadUnpacked", { path: fixture });
    let worker = context.serviceWorkers().find(value => value.url().startsWith(`chrome-extension://${extension.id}/`));
    if (!worker) worker = await context.waitForEvent("serviceworker", {
      predicate: value => value.url().startsWith(`chrome-extension://${extension.id}/`), timeout: 15000
    });
    const result = await timeout(worker.evaluate(async baseURL => {
      const windows = await chrome.windows.getAll();
      if (!windows.length) throw new Error("No baseline browser window");
      return await globalThis.zacroNetworkAcceptance.run({ baseURL, sourceWindowID: windows[0].id });
    }, `http://127.0.0.1:${port}/`), 120000, "Extension network baseline timed out");
    report = { ...report, ...result };
  } catch (error) {
    report.error = String(error?.stack || error);
  } finally {
    if (context) {
      try { await context.close(); }
      catch (error) { report.passed = false; report.cleanupError = String(error); }
    }
    serverLines?.close();
    if (server && server.exitCode === null) server.kill("SIGTERM");
    await fs.rm(temporary, { recursive: true, force: true });
    await fs.writeFile(path.join(output, "result.json"), JSON.stringify(report, null, 2) + "\n");
  }
  console.log(JSON.stringify(report, null, 2));
  if (!report.passed) process.exitCode = 1;
}

main().catch(error => { console.error(error); process.exitCode = 1; });
