// Native-session intake bookkeeping, not a task queue. User messages remain
// the source; dispositions only link their handling to the existing backlog
// or an actual reply. No task is created, launched, cancelled, or completed here.
import { registerFirstmateTool } from "./fm-native-contract.ts";
import type { ExtensionAPI, ExtensionContext, SessionEntry } from "@earendil-works/pi-coding-agent";
import { classifyFirstmateCurrentOperationalText, encodeFirstmateOperationalInput, firstmateShellInvocation } from "./fm-operational-input.ts";

const START = "fm-request-intake-start";
const DISPOSITION = "fm-request-disposition";
const RECOVERY = "fm-request-recovery";
type Receipt = { id: string; disposition: "recorded" | "reply"; taskIds: string[]; summary: string };
type Request = { id: string; text: string; replyStaged?: boolean };

function visibleText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.map((block) => block?.type === "text" ? block.text : block?.type === "image" ? "[attached image]" : "").join("\n");
}

export function registerRequestContinuity(
  pi: ExtensionAPI,
  ownsHome: () => boolean,
  root: string,
): {
  start(ctx: ExtensionContext): void;
  initialize(ctx: ExtensionContext): boolean;
  status(ctx: ExtensionContext): void;
  settled(ctx: ExtensionContext): Promise<void>;
  shutdown(): void;
} {
  let generation = 0;
  let sessionId = "";
  let stopped = false;
  const human = new Map<string, boolean>();

  function branch(ctx: ExtensionContext): SessionEntry[] {
    return ctx.sessionManager.getBranch();
  }
  function ready(ctx: ExtensionContext): boolean {
    return !stopped && ctx.sessionManager?.getSessionId?.() === sessionId && ownsHome();
  }
  function initialize(ctx: ExtensionContext): boolean {
    if (!ready(ctx)) return false;
    if (!branch(ctx).some((entry) => entry.type === "custom" && entry.customType === START)) {
      // A first installation, or a navigation to a branch without a boundary,
      // does not reinterpret the branch's existing chat as new work. Resume and
      // reload retain this boundary in the native session tree.
      pi.appendEntry(START, { version: 1, after: ctx.sessionManager.getLeafId?.() ?? null });
    }
    return true;
  }
  function pending(ctx: ExtensionContext): { requests: Request[]; attempted: Set<string> } {
    const entries = branch(ctx);
    const start = entries.find((entry) => entry.type === "custom" && entry.customType === START);
    if (!start || start.type !== "custom") return { requests: [], attempted: new Set() };
    const boundary = start.data as { version?: number; after?: string | null };
    const after = boundary?.after;
    if (boundary?.version !== 1 || (after !== null && typeof after !== "string")) throw new Error("invalid native intake boundary; reconcile session history");
    const from = after === null ? 0 : entries.findIndex((entry) => entry.id === after) + 1;
    if (after !== null && from === 0) throw new Error("native intake boundary is missing from this session branch");
    const requests = new Map<string, Request>();
    const replies = new Set<string>();
    const attempted = new Set<string>();
    for (const entry of entries.slice(from)) {
      if (entry.type === "message" && entry.message.role === "user") {
        // An interrupted proposed reply cannot be completed by a later,
        // unrelated answer. It needs a new explicit disposition.
        replies.clear();
        const text = visibleText(entry.message.content);
        if (!human.has(entry.id)) human.set(entry.id, !classifyFirstmateCurrentOperationalText(text));
        if (human.get(entry.id)) requests.set(entry.id, { id: entry.id, text });
      } else if (entry.type === "custom" && entry.customType === DISPOSITION) {
        const receipt = entry.data as Receipt;
        if (!requests.has(receipt?.id) || !receipt.summary?.trim()) continue;
        if (receipt.disposition === "recorded" && receipt.taskIds?.length) requests.delete(receipt.id);
        if (receipt.disposition === "reply") replies.add(receipt.id);
      } else if (entry.type === "message" && entry.message.role === "assistant" &&
                 entry.message.stopReason === "stop" && visibleText(entry.message.content).trim()) {
        // A promise to reply is not a reply. Errors, aborts, tool calls and
        // unrelated replies with no explicit disposition never clear intake.
        for (const id of replies) requests.delete(id);
        replies.clear();
      } else if (entry.type === "message" && entry.message.role === "assistant" &&
                 ["error", "aborted", "length"].includes(entry.message.stopReason)) {
        replies.clear();
      } else if (entry.type === "custom" && entry.customType === RECOVERY) {
        const ids = (entry.data as { ids?: unknown })?.ids;
        if (Array.isArray(ids)) for (const id of ids) if (typeof id === "string") attempted.add(id);
      }
    }
    return { requests: [...requests.values()].map((request) => ({ ...request, replyStaged: replies.has(request.id) })), attempted };
  }
  function describe(requests: Request[]): string {
    return "Unreconciled native user input (not a task list or permission to execute):\n" +
      requests.slice(0, 8).map(({ id, text, replyStaged }) => `[${id}] ${replyStaged ? "REPLY ALREADY STAGED: answer now; do not call the disposition tool again. " : ""}${text.slice(0, 2000)}`).join("\n\n") +
      (requests.length > 8 ? `\n${requests.length - 8} further messages remain; inspect with fm_request_disposition.` : "") +
      "\nReconcile every intent in these messages against later corrections, cancellations, priorities and existing records. " +
      "Use existing task IDs and owners; never replay a request merely because it is listed. " +
      "Record outliving work and its next action in the backlog before acknowledging recorded. " +
      "Questions and work fully handled in this reply need no task. For input without a staged reply, use fm_request_disposition with reply once and then give the substantive answer. " +
      "A disposition does not establish task execution, completion or semantic correctness.";
  }
  function showStatus(ctx: ExtensionContext): void {
    if (!ready(ctx)) return;
    const count = pending(ctx).requests.length;
    if (ctx.hasUI) ctx.ui.setStatus("fm-request-intake", count ? `${count} input(s) need reconciliation` : undefined);
  }

  function start(ctx: ExtensionContext): void {
    generation++;
    sessionId = ctx.sessionManager?.getSessionId?.() ?? "";
    stopped = false;
    human.clear();
    if (sessionId && initialize(ctx)) showStatus(ctx);
  }
  pi.on("context", (event, ctx) => {
    try {
      if (!sessionId || !initialize(ctx)) return;
      const { requests } = pending(ctx);
      if (!requests.length) return;
      return { messages: [...event.messages, {
        role: "custom" as const, customType: "fm-request-intake", content: describe(requests),
        display: false, timestamp: Date.now(),
      }] };
    } catch {
      return;
    }
  });
  async function settled(ctx: ExtensionContext): Promise<void> {
    if (!sessionId || !initialize(ctx)) return;
    showStatus(ctx);
    const { requests, attempted } = pending(ctx);
    const fresh = requests.filter(({ id }) => !attempted.has(id));
    if (!fresh.length) return;
    // At most one automatic reconciliation per source message, persisted
    // before delivery so reload/compaction cannot create an endless nag loop.
    // A lost/failed follow-up leaves input visible on the next natural turn.
    pi.appendEntry(RECOVERY, { ids: fresh.map(({ id }) => id) });
    const content = encodeFirstmateOperationalInput("turn-end-guard", describe(requests));
    await pi.sendUserMessage(content, { deliverAs: "followUp" });
  }

  registerFirstmateTool(pi, {
    name: "fm_request_disposition",
    label: "Reconcile user input",
    description: "Inspect unresolved native user messages or record how one was handled. Omit id to list. Use recorded only after creating/updating every affected existing backlog record, including waits and next action; supply their IDs. Use reply for questions or work fully handled in the substantive reply that follows. Never acknowledge omitted, unfiled or merely planned work as answered. This tool never changes task state and does not prove execution or completion.",
    parameters: {
      type: "object",
      properties: {
        id: { type: "string" },
        disposition: { type: "string", enum: ["recorded", "reply"] },
        taskIds: { type: "array", items: { type: "string" } },
        summary: { type: "string" },
      },
      additionalProperties: false,
    } as const,
    async execute(_callId, params, signal, _update, ctx) {
      if (!ready(ctx)) throw new Error("intake disposition refused: this session does not own the home");
      const toolGeneration = generation;
      const { id, disposition, taskIds = [], summary } = params as Partial<Receipt>;
      const { requests } = pending(ctx);
      if (!id) return { content: [{ type: "text", text: JSON.stringify(requests) }], details: {} };
      if (!requests.some((request) => request.id === id)) throw new Error("id is not unresolved input on this session branch");
      if (!["recorded", "reply"].includes(disposition ?? "") || !summary?.trim()) throw new Error("disposition and a substantive handling summary are required");
      if (disposition === "recorded") {
        if (!taskIds.length || taskIds.some((task) => !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(task))) throw new Error("recorded requires existing backlog task IDs");
        for (const task of new Set(taskIds)) {
          const invocation = firstmateShellInvocation(`${root}/bin/fm-tasks-axi.sh`, ["show", task, "--full"]);
          const result = await pi.exec(invocation.command, invocation.args, { signal });
          if (result.code !== 0) throw new Error(`backlog record ${task} could not be verified; input stays unresolved`);
        }
      }
      if (!ready(ctx) || generation !== toolGeneration || signal?.aborted) throw new Error("intake disposition interrupted; input stays unresolved");
      if (!pending(ctx).requests.some((request) => request.id === id)) throw new Error("input already reconciled");
      if (disposition !== "reply" || !pending(ctx).requests.find((request) => request.id === id)?.replyStaged) {
        pi.appendEntry(DISPOSITION, { id, disposition, taskIds, summary });
      }
      showStatus(ctx);
      return {
        content: [{ type: "text", text: disposition === "reply" ? "Reply disposition staged; give the substantive answer. It remains unresolved until a normal nonempty reply." : "Input linked to existing backlog records. Their execution and completion states are unchanged." }],
        details: {},
      };
    },
  });
  return {
    start: (ctx) => { try { start(ctx); } catch {} },
    initialize: (ctx) => { try { return initialize(ctx); } catch { return false; } },
    status: (ctx) => { try { showStatus(ctx); } catch {} },
    settled: async (ctx) => { try { await settled(ctx); } catch {} },
    shutdown: () => { stopped = true; generation++; },
  };
}
