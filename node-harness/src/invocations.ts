import { randomUUID } from "node:crypto";

/**
 * In-memory invocation registry backing GET /invocations/{id}
 * (protocol.md: state machine queued -> running -> completed | failed,
 * plus the A.3 terminal states aborted | timed_out).
 */

export type InvocationState =
  | "queued"
  | "running"
  | "completed"
  | "failed"
  | "aborted"
  | "timed_out";

export interface InvocationStep {
  tool: string;
  at: string;
  ok: boolean;
  detail?: string;
}

export interface InvocationRecord {
  invocationId: string;
  contextId: string;
  prompt: string;
  invokedAt: string;
  state: InvocationState;
  startedAt?: string;
  finishedAt?: string | null;
  steps: InvocationStep[];
  /** Live activity line for the host pill ("thinking", tool name); absent when idle. */
  activity?: string;
  /** Final agent answer, capped; present once completed. */
  responseText?: string;
  /** Why the invocation failed/aborted/timed out; terminal failure states only. */
  failureMessage?: string;
}

const MAX_RECORDS = 200;
const MAX_RESPONSE_CHARS = 8_000;

export class InvocationStore {
  private readonly records = new Map<string, InvocationRecord>();

  create(contextId: string, prompt: string, invokedAt: string, invocationId = `inv-${randomUUID().replaceAll("-", "")}`): InvocationRecord {
    const record: InvocationRecord = {
      invocationId,
      contextId,
      prompt,
      invokedAt,
      state: "queued",
      steps: [],
    };
    this.records.set(record.invocationId, record);
    if (this.records.size > MAX_RECORDS) {
      const oldest = this.records.keys().next().value;
      if (oldest !== undefined) {
        this.records.delete(oldest);
      }
    }

    return record;
  }

  get(id: string): InvocationRecord | undefined {
    return this.records.get(id);
  }

  start(id: string): void {
    this.mutate(id, (r) => {
      r.state = "running";
      r.startedAt = new Date().toISOString();
    });
  }

  addStep(id: string, tool: string, ok: boolean, detail?: string): void {
    this.mutate(id, (r) => {
      r.steps.push({ tool, at: new Date().toISOString(), ok, ...(detail !== undefined ? { detail } : {}) });
    });
  }

  /** Publish/clear the live activity line (result-surfacing pill). */
  setActivity(id: string, activity: string | undefined): void {
    this.mutate(id, (r) => {
      if (activity === undefined) {
        delete r.activity;
      } else {
        r.activity = activity.slice(0, 80);
      }
    });
  }

  /** Requeue a terminal record for a sequential follow-up on the same session.
   *  Returns false when unknown or still running. Keeps steps history. */
  requeueForFollowup(id: string, prompt: string): boolean {
    const record = this.records.get(id);
    if (!record) {
      return false;
    }
    if (record.state === "queued" || record.state === "running") {
      return false;
    }
    record.prompt = prompt;
    record.state = "running";
    record.startedAt = new Date().toISOString();
    record.finishedAt = null;
    delete record.activity;
    delete record.responseText;
    delete record.failureMessage;
    return true;
  }

  /** Persist the final answer, capped so records stay small. */
  setResponse(id: string, text: string): void {
    this.mutate(id, (r) => {
      const trimmed = text.trim();
      r.responseText = trimmed.length > MAX_RESPONSE_CHARS
        ? `${trimmed.slice(0, MAX_RESPONSE_CHARS)}… [truncated]`
        : trimmed;
    });
  }

  finish(
    id: string,
    state: Extract<InvocationState, "completed" | "failed" | "aborted" | "timed_out">,
    failureMessage?: string,
  ): void {
    this.mutate(id, (r) => {
      r.state = state;
      r.finishedAt = new Date().toISOString();
      delete r.activity;
      if (failureMessage !== undefined && state !== "completed") {
        r.failureMessage = failureMessage.slice(0, 2_000);
      }
    });
  }

  private mutate(id: string, mutate: (record: InvocationRecord) => void): void {
    const record = this.records.get(id);
    if (record) {
      mutate(record);
    }
  }
}
