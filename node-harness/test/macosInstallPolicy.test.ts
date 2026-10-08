import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";

test("Mac installer blocks implicit ad-hoc refresh before touching an existing app", { skip: process.platform !== "darwin" }, async () => {
  const root = await mkdtemp(join(tmpdir(), "pi-os-install-policy-"));
  const destination = join(root, "pi-os.app");
  const executable = join(destination, "Contents", "MacOS", "pi-os");
  await mkdir(join(destination, "Contents", "MacOS"), { recursive: true });
  await writeFile(executable, "existing authorized app must remain unchanged");
  const script = resolve("../host-macos/scripts/refresh-install.sh");
  const baseEnv: NodeJS.ProcessEnv = { ...process.env, PATH: "/usr/bin:/bin", PI_OS_INSTALL_PATH: destination };
  delete baseEnv.PI_OS_SIGN_IDENTITY;
  delete baseEnv.PI_OS_ALLOW_ADHOC_INSTALL;
  try {
    for (const configured of [undefined, "", "-"]) {
      const env: NodeJS.ProcessEnv = { ...baseEnv };
      if (configured !== undefined) env.PI_OS_SIGN_IDENTITY = configured;
      const run = spawnSync("/bin/bash", [script], { env, encoding: "utf8", timeout: 5000 });
      assert.equal(run.status, 78, run.stderr);
      assert.match(run.stderr, /Install blocked/);
      assert.match(run.stderr, /installed app was not changed/);
      assert.equal(await readFile(executable, "utf8"), "existing authorized app must remain unchanged");
    }
    // Prove the explicit choices pass only this policy gate, without actually building/installing.
    // The deliberately invalid destination is rejected by the next validation step.
    for (const choice of [{ PI_OS_SIGN_IDENTITY: "Chosen Certificate" }, { PI_OS_ALLOW_ADHOC_INSTALL: "1" }]) {
      const run = spawnSync("/bin/bash", [script], {
        env: { ...baseEnv, ...choice, PI_OS_INSTALL_PATH: "invalid" }, encoding: "utf8", timeout: 5000,
      });
      assert.equal(run.status, 1, run.stderr);
      assert.doesNotMatch(run.stderr, /Install blocked/);
      assert.match(run.stderr, /Install path must be/);
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});
