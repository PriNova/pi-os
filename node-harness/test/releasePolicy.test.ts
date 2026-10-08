import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { resolve } from "node:path";
import { test } from "node:test";

test("release uploads are gated before any notarization or provider call", { skip: process.platform !== "darwin" }, () => {
  const env: NodeJS.ProcessEnv = { ...process.env, PI_OS_RELEASE_APP: "/not-a-release/pi-os.app" };
  delete env.PI_OS_NOTARY_PROFILE;
  const script = resolve("../host-macos/scripts/notarize-app.sh");
  let result = spawnSync("/bin/bash", [script], { env, encoding: "utf8", timeout: 5000 });
  assert.equal(result.status, 78);
  assert.match(result.stderr, /PI_OS_NOTARY_PROFILE/);
  result = spawnSync("/bin/bash", [script], { env: { ...env, PI_OS_NOTARY_PROFILE: "not-used" }, encoding: "utf8", timeout: 5000 });
  assert.equal(result.status, 78);
  assert.match(result.stderr, /self-contained/);
});

test("runtime bundling rejects ad-hoc identity before copying anything", { skip: process.platform !== "darwin" }, () => {
  const result = spawnSync("/bin/bash", [resolve("../host-macos/scripts/bundle-runtime.sh"), "/not-created/pi-os.app"], {
    env: { ...process.env, PI_OS_SIGN_IDENTITY: "-", PI_OS_BUNDLED_NODE_PATH: process.execPath }, encoding: "utf8", timeout: 5000,
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /requires a certificate/);
});
