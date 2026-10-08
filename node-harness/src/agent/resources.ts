import { join, resolve } from "node:path";
import { createAgentSession, DefaultResourceLoader, getAgentDir, SessionManager, SettingsManager,
  type InlineExtension, type ModelRuntime } from "@earendil-works/pi-coding-agent";

export async function loadAgentResources(
  extension: InlineExtension,
  cwd = process.cwd(),
  agentDir = getAgentDir(),
  isolated = false,
): Promise<DefaultResourceLoader> {
  const loader = new DefaultResourceLoader({
    cwd, agentDir, extensionFactories: [extension],
    // Project resources are never trusted on Mac, even with explicit GLOBAL compatibility.
    settingsManager: SettingsManager.create(cwd, agentDir, { projectTrusted: process.platform === "darwin" ? false : !isolated }),
    ...(isolated ? { noExtensions: true, noSkills: true, noPromptTemplates: true, noContextFiles: true } : {}),
    ...(process.platform === "darwin" && !isolated ? {
      agentsFilesOverride: (base: { agentsFiles: { path: string; content: string }[] }) => ({
        agentsFiles: base.agentsFiles.filter(file => ["AGENTS.md", "CLAUDE.md"].some(name => resolve(file.path) === resolve(join(agentDir, name)))),
      }),
    } : {}),
  });
  await loader.reload();
  if (loader.getExtensions().errors.length) throw new Error("resource_load_failed: A configured pi extension could not load; check your extension configuration");
  return loader;
}

/** Public SDK bootstrap flushes factory-registered providers before model selection.
 * No prompt, inference, session_start hook or settings write. Factory code itself is
 * trusted executable code, which is why this path is explicit opt-in on Mac. */
export async function registerResourceProviders(loader: DefaultResourceLoader, runtime: ModelRuntime): Promise<() => void> {
  const { session } = await createAgentSession({
    modelRuntime: runtime, resourceLoader: loader, tools: [],
    sessionManager: SessionManager.inMemory(), settingsManager: SettingsManager.inMemory(),
  });
  // Keep the bootstrap alive while its loader/runtime is reused. Disposing here would
  // permanently invalidate the ExtensionAPI captured by every loaded extension.
  return () => session.dispose();
}
