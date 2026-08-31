import { getSupportedThinkingLevels, type Model } from "@earendil-works/pi-ai";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";

/**
 * The pi model catalog as seen by the host settings page.
 *
 * Each catalog request creates a fresh ModelRuntime. This reloads the user's
 * models.json and authentication changes without requiring a pi-os restart.
 * Invocation runs also create their own fresh runtime.
 */

/** Wire shape for GET /models entries (protocol.md). */
export interface ModelSummary {
  provider: string;
  id: string;
  name: string;
  /** Whether the provider/model supports reasoning (thinking) at all. */
  reasoning: boolean;
  /** pi thinking levels this model accepts, ascending ("off" ... "max"). */
  thinkingLevels: string[];
}

export function getModelRuntime(): Promise<ModelRuntime> {
  return ModelRuntime.create();
}

/**
 * Models with configured authentication. Sorted provider asc, then id —
 * deterministic UI ordering.
 */
export async function listAvailableModels(): Promise<ModelSummary[]> {
  const runtime = await getModelRuntime();
  return (await runtime.getAvailable())
    .map(summarizeModel)
    .sort((a, b) =>
      a.provider.localeCompare(b.provider) || a.id.localeCompare(b.id));
}

export function summarizeModel(model: Model<any>): ModelSummary {
  return {
    provider: model.provider,
    id: model.id,
    name: model.name,
    reasoning: Boolean(model.reasoning),
    thinkingLevels: [...getSupportedThinkingLevels(model)],
  };
}

export interface ResolvedSelection {
  model?: Model<any>;
  /** Set when the stored selection could not be resolved and pi will fall back. */
  fallbackReason?: string;
}

/**
 * Resolve a stored settings selection against a live runtime. Missing
 * catalogs or lost auth degrade to the session default instead of failing
 * the invocation (runAgent logs whatever happens).
 */
export function resolveModel(
  runtime: ModelRuntime,
  selection: { provider: string; modelId: string } | null | undefined,
): ResolvedSelection {
  if (!selection?.provider || !selection.modelId) {
    return {};
  }
  const model = runtime.getModel(selection.provider, selection.modelId);
  if (!model) {
    return {
      fallbackReason:
        `configured model ${selection.provider}/${selection.modelId} is not registered`,
    };
  }
  return { model };
}
