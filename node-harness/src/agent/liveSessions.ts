import type { LiveAgentSession } from "./agentRunner.js";

/**
 * Live pi sessions kept for sequential follow-ups.
 *
 * KISS: one entry per invocation id. The entry lives from the first answer
 * until the reader window closes (POST /invocations/{id}/close). No history
 * UI, no cross-invocation sharing.
 */

const MAX_LIVE_SESSIONS = 20;

export class LiveSessionStore {
  private readonly sessions = new Map<string, LiveAgentSession>();

  get(id: string): LiveAgentSession | undefined {
    return this.sessions.get(id);
  }

  set(id: string, live: LiveAgentSession): void {
    if (!this.sessions.has(id) && this.sessions.size >= MAX_LIVE_SESSIONS) {
      const oldest = this.sessions.keys().next().value;
      if (oldest !== undefined) {
        this.dispose(oldest);
      }
    }
    this.sessions.set(id, live);
  }

  dispose(id: string): void {
    const live = this.sessions.get(id);
    if (!live) {
      return;
    }
    this.sessions.delete(id);
    try {
      live.session.dispose();
    } catch {
      // Dispose is best-effort; the map entry is already gone.
    }
  }
}
