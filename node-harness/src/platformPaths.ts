import { homedir } from "node:os";
import { join } from "node:path";

/** Keep Windows' existing layout; Finder-launched Mac apps use Application Support. */
export function supportDirectory(
  env: NodeJS.ProcessEnv = process.env,
  platform: NodeJS.Platform = process.platform,
  home = homedir(),
): string {
  if (platform === "darwin") return env.PI_OS_SUPPORT_DIR ?? join(home, "Library", "Application Support", "pi-os");
  return join(env.LOCALAPPDATA ?? join(home, "AppData", "Local"), "pi-os");
}
