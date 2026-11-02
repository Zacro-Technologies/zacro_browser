#!/usr/bin/env node
/* Opt-in fixture contract check in real Chrome; this is NOT Zacro acceptance. */
const { chromium } = require("playwright");
const fs = require("node:fs/promises");
const path = require("node:path");
const { spawn, execFile } = require("node:child_process");
const { promisify } = require("node:util");
const execute = promisify(execFile);
const readline = require("node:readline");

function options() {
  const result = {};
  for (let i = 2; i < process.argv.length; i += 2) {
    const name = process.argv[i], value = process.argv[i + 1];
    if (!["--chrome", "--output", "--suite"].includes(name) || !value) {
      throw new Error("Usage: node macos/scripts/check-extension-network.cjs --chrome /absolute/path/to/chrome [--suite network|identity|native-messaging] [--output directory]");
    }
    result[name.slice(2)] = value;
  }
  if (!result.chrome || !path.isAbsolute(result.chrome)) throw new Error("Provide an explicit absolute --chrome executable path.");
  result.suite ||= "network";
  if (!["network", "identity", "native-messaging"].includes(result.suite)) throw new Error("Choose the network, identity, or native-messaging fixture suite.");
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

async function until(body, message) {
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    const result = await timeout(Promise.resolve().then(body), 5000, message + " (inspection stalled)");
    if (result) return result;
    await new Promise(resolve => setTimeout(resolve, 30));
  }
  throw new Error(message);
}

async function interactiveIdentityBaseline(context, worker, baseURL, result) {
  // Headless native pages establish fixture lifecycle only. A visible macOS
  // window and exclusion from Zacro's logical catalog are separate app checks.
  for (const kind of ["release", "close"]) {
    const name = kind === "release" ? "identityInteractiveCallbackClosesNativePage" : "identityNativePageCloseRejectsFlow";
    let page, token;
    try {
      console.error(`Identity native-page baseline: ${kind} start`);
      const run = await timeout(worker.evaluate(baseURL => zacroIdentityAcceptance.startInteractive({ baseURL }), baseURL),
        5000, "Starting native authorization stalled");
      token = run.token;
      console.error(`Identity native-page baseline: ${kind} waiting for page`);
      page = await until(async () => {
        for (const candidate of context.pages()) {
          if (candidate.url().includes(token) && await candidate.title() === run.title) return candidate;
        }
      }, "The native authorization page did not open");
      console.error(`Identity native-page baseline: ${kind} page ready`);
      if (kind === "release") await timeout(worker.evaluate(token => zacroIdentityAcceptance.release(token), token), 6000, "Releasing authorization stalled");
      else await timeout(page.close(), 5000, "Closing authorization page stalled");
      const status = await until(async () => {
        const value = await worker.evaluate(token => zacroIdentityAcceptance.status(token), token);
        return value.state !== "pending" ? value : null;
      }, "The native authorization callback did not settle");
      if (kind === "release" && (status.state !== "resolved" || !status.exactCallback)) throw new Error("Released authorization did not return its exact callback");
      if (kind === "close" && (status.state !== "rejected" || !/cancel|closed|approve/i.test(status.error))) throw new Error("Closing authorization did not reject the flow: " + status.error);
      await until(() => page.isClosed(), "The native authorization page survived completion");
      await timeout(worker.evaluate(token => zacroIdentityAcceptance.finish(token), token), 5000, "Finalizing authorization stalled");
      result.checks[name] = true;
    } catch (error) {
      result.checks[name] = false; result.errors[name] = String(error?.message || error);
    } finally {
      if (page && !page.isClosed()) await timeout(page.close(), 5000, "Authorization cleanup stalled").catch(() => {});
    }
  }
  result.passed = Object.values(result.checks).every(Boolean);
  result.headlessNativePageLifecycleOnly = true;
}

async function main() {
  const args = options(), nativeRoot = path.resolve(__dirname, "..");
  const output = path.resolve(args.output || path.join(nativeRoot, `.build/verification/${args.suite}-chrome-baseline`));
  await fs.access(args.chrome); await fs.mkdir(output, { recursive: true });
  const temporary = await fs.mkdtemp(path.join(output, "run-"));
  let context, server, serverLines;
  let report = { browserBaselineOnly: true, zacroRuntimeVerified: false, suite: args.suite, passed: false };
  try {
    const fixture = path.join(temporary, "extension");
    await fs.cp(path.join(__dirname, "fixtures/native-extension"), fixture, { recursive: true });
    // Use the same fixture as the app acceptance runner without adding grants
    // or rewriting its service worker for this baseline.
    const manifest = JSON.parse(await fs.readFile(path.join(fixture, "manifest.json"), "utf8"));
    const permissions = args.suite === "identity" ? ["identity"] : args.suite === "native-messaging" ? ["nativeMessaging"] : ["declarativeNetRequestWithHostAccess", "webRequest"];
    for (const required of permissions) {
      if (!manifest.permissions.includes(required)) throw new Error(`Fixture is missing ${required}`);
    }
    const fixtureScript = path.join(__dirname, "check-app.py");
    const python = `import importlib.util,http.server,sys\nsys.path.insert(0,${JSON.stringify(__dirname)})\ns=importlib.util.spec_from_file_location('fixture',${JSON.stringify(fixtureScript)})\nm=importlib.util.module_from_spec(s);s.loader.exec_module(m)\nh=http.server.ThreadingHTTPServer(('127.0.0.1',0),m.Fixture)\nprint(h.server_port,flush=True)\nh.serve_forever()`;
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
    let nativeHosts;
    if (args.suite === "native-messaging") {
      const executable = path.join(temporary, "fixture-host");
      await execute("python3", ["-B", path.join(__dirname, "native_messaging_fixture.py"), "--output", executable], { timeout: 30000 });
      const register = "import sys,json;sys.path.insert(0,sys.argv[1]);from native_messaging_fixture import register_hosts;print(json.dumps(register_hosts(sys.argv[2],sys.argv[3],sys.argv[4])))";
      const installed = await execute("python3", ["-B", "-c", register, __dirname, path.join(temporary, "profile"), extension.id, executable], { timeout: 10000 });
      nativeHosts = JSON.parse(installed.stdout);
    }
    const result = await timeout(worker.evaluate(async ({ baseURL, suite, hosts }) => {
      if (suite === "identity") return await globalThis.zacroIdentityAcceptance.run({ baseURL });
      if (suite === "native-messaging") return await globalThis.zacroNativeMessagingAcceptance.run({ hosts });
      const windows = await chrome.windows.getAll();
      if (!windows.length) throw new Error("No baseline browser window");
      return await globalThis.zacroNetworkAcceptance.run({ baseURL, sourceWindowID: windows[0].id });
    }, { baseURL: `http://127.0.0.1:${port}/`, suite: args.suite, hosts: nativeHosts?.hosts }), 120000, "Extension fixture baseline timed out");
    if (args.suite === "identity") await interactiveIdentityBaseline(context, worker, `http://127.0.0.1:${port}/`, result);
    if (nativeHosts) {
      try {
        const denied = await fs.access(path.join(nativeHosts.directory, "denied.pid")).then(() => true, () => false);
        if (denied) throw new Error("The forbidden extension origin launched a host");
        const pid = Number((await fs.readFile(path.join(nativeHosts.directory, "hold.pid"), "utf8")).trim());
        if (!Number.isSafeInteger(pid) || pid <= 1) throw new Error("Missing fixture host process identity");
        result.hostProcessID = pid;
        result.hostProcessStateBeforeWait = await execute("ps", ["-p", String(pid), "-o", "stat=,ppid=,comm="])
          .then(value => value.stdout.trim(), () => "already exited");
        await until(() => {
          try { process.kill(pid, 0); return false; }
          catch (error) { if (error.code === "ESRCH") return true; throw error; }
        }, "Disconnected native host process survived");
        result.checks.nativeHostProcessCleanupAndDeniedLaunch = true; result.processCleanupVerified = true;
      } catch (error) {
        result.checks.nativeHostProcessCleanupAndDeniedLaunch = false;
        result.errors.nativeHostProcessCleanupAndDeniedLaunch = String(error?.message || error);
        if (result.hostProcessID) result.hostProcessStateAfterWait = await execute("ps", ["-p", String(result.hostProcessID), "-o", "stat=,ppid=,comm="])
          .then(value => value.stdout.trim(), () => "already exited");
      }
      result.passed = Object.values(result.checks).every(Boolean);
    }
    report = { ...report, ...result };
  } catch (error) {
    report.error = String(error?.stack || error);
  } finally {
    if (context) {
      try { await timeout(context.close(), 10000, "Closing the disposable Chrome profile stalled"); }
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
