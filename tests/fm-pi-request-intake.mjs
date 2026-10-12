import assert from "node:assert/strict";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";
const home = process.env.FM_HOME;
const repo = process.env.FM_INTAKE_REPO;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const sdk = await import(pathToFileURL(`${process.env.PI_PACKAGE_DIR}/dist/index.js`).href);
const { DefaultResourceLoader, ModelRegistry, ModelRuntime, SessionManager, SettingsManager, createAgentSession } = sdk;
const agentDir = process.env.PI_CODING_AGENT_DIR;
let requests = [];
let capturedContext = [];
let stagedContextSeen = false;
let discovery;
let completions = 0;
let releaseFirst;
let firstSeen;
const first = new Promise((resolve) => { firstSeen = resolve; });
const held = new Promise((resolve) => { releaseFirst = resolve; });
let nextTool;
let compacting = false;
let usage = { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 };
const chunk = (delta, finish) => `data: ${JSON.stringify({ id: "intake-fixture", object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, delta, finish_reason: finish }], ...(finish ? { usage } : {}) })}\n\n`;
globalThis.fetch = async (input, options) => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  assert.ok(url.startsWith("https://fm-intake.invalid/"), `unexpected network ${url}`);
  const outputText = compacting ? "We answered side questions." : "The side answer is six. " + "This is representative unrelated conversational context for the synthetic session. ".repeat(30);
  const inputTokens = Math.ceil(String(options?.body ?? "").length / 4);
  const outputTokens = Math.ceil(outputText.length / 4);
  usage = { prompt_tokens: inputTokens, completion_tokens: outputTokens, total_tokens: inputTokens + outputTokens };
  completions++;
  const index = completions;
  const tool = nextTool;
  nextTool = undefined;
  const encoder = new TextEncoder();
  const body = new ReadableStream({ async start(controller) {
    if (index === 1) { firstSeen(); await held; }
    if (tool) {
      controller.enqueue(encoder.encode(chunk({ role: "assistant", tool_calls: [{ index: 0, id: `call-${index}`, type: "function", function: { name: "fm_request_disposition", arguments: JSON.stringify(tool) } }] }, null)));
    } else {
      controller.enqueue(encoder.encode(chunk({ role: "assistant", content: outputText }, null)));
    }
    controller.enqueue(encoder.encode(chunk({}, tool ? "tool_calls" : "stop")));
    controller.enqueue(encoder.encode("data: [DONE]\n\n"));
    controller.close();
  } });
  return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
};
const settings = SettingsManager.create(repo, agentDir);
const events = [];
let ctx;
const loader = new DefaultResourceLoader({
  cwd: repo, agentDir, settingsManager: settings,
  additionalExtensionPaths: [`${repo}/.pi/extensions/fm-primary-turnend-guard.ts`],
  extensionFactories: [{ name: "intake-observer", factory: (pi) => {
    discovery = pi.events;
    pi.on("context", (event) => { capturedContext = event.messages; stagedContextSeen ||= event.messages.some((message) => message.customType === "fm-request-intake" && message.content.includes("REPLY ALREADY STAGED")); });
    pi.on("agent_settled", (_event, context) => { ctx = context; events.push("settled"); });
    pi.on("input", (event) => { events.push({ source: event.source, text: event.text }); });

  } }],
  noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
});
await loader.reload();
const runtime = await ModelRuntime.create({ authPath: `${agentDir}/auth.json`, modelsPath: `${agentDir}/models.json` });
const registry = new ModelRegistry(runtime);
await registry.refresh();
const model = registry.find("fm-intake", "fixture");
assert.ok(model);
const manager = SessionManager.create(repo, `${home}/sessions`);
const { session } = await createAgentSession({ cwd: repo, sessionManager: manager, resourceLoader: loader, settingsManager: settings, modelRuntime: runtime, model, noTools: "builtin" });
await session.bindExtensions({ mode: "rpc", onError: (error) => { throw new Error(JSON.stringify(error)); } });
const waitFor = async (test, label) => {
  const until = Date.now() + 20000;
  while (!test()) {
    if (Date.now() > until) throw new Error(`timeout: ${label}; events=${JSON.stringify(events)}`);
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
};
const a = "Prepare a keyboard audit once the sample arrives; do not launch before it arrives.";
const b = "Unrelated: how many sides does a hexagon have?";
const turn = session.prompt(a);
await first;
await session.steer(b);
releaseFirst();
await turn;
const tool = session.getToolDefinition("fm_request_disposition");
await waitFor(() => events.filter((event) => event === "settled").length >= (tool ? 2 : 1) && !session.isStreaming, "bounded automatic recovery");
assert.equal(readFileSync(`${home}/data/backlog.md`, "utf8"), "## In flight\n\n## Queued\n\n## Done\n");
const recovery = events.filter((event) => event?.source === "extension" && event.text.includes("Unreconciled native user input"));
assert.equal(recovery.length, 1, "omitted intake must create one recoverable obligation, not disappear after the unrelated reply");
console.log("ok - deliberate unfiled acceptance survives unrelated steering and opens one recovery without a status request");
async function inspect() {
  const result = await tool.execute("inspect", {}, undefined, undefined, ctx);
  return JSON.parse(result.content[0].text);
}
requests = await inspect();
assert.deepEqual(requests.map((request) => request.text), [a, b]);
const [aId, bId] = requests.map((request) => request.id);
assert.equal(manager.getBranch().filter((entry) => entry.type === "custom" && entry.customType === "fm-request-recovery").length, 1);
for (let i = 0; i < 3; i++) {
  const previous = events.filter((event) => event === "settled").length;
  await session.prompt(`Unrelated conversational topic ${i}. ` + "Please retain this ordinary background context. ".repeat(30));
  await waitFor(() => !session.isStreaming && events.filter((event) => event === "settled").length >= previous + 2, "representative later history");
}
assert.equal(settings.getCompactionSettings().keepRecentTokens, 100, "resource loading must retain fixture compaction settings");
compacting = true;
await session.compact();
compacting = false;
assert.ok(manager.getBranch().some((entry) => entry.type === "compaction"));
await session.prompt("Please keep the answer brief.");
await waitFor(() => !session.isStreaming && events.filter((event) => event === "settled").length >= 4, "post-compaction recovery");
assert.ok((await inspect()).some((request) => request.id === aId));
assert.ok(capturedContext.some((message) => message.customType === "fm-request-intake" && message.content.includes(a)));
console.log("ok - actual compaction with an omitting summary still restores original unresolved user input");

await assert.rejects(tool.execute("missing", { id: aId, disposition: "recorded", taskIds: ["not-filed"], summary: "Planned only" }, undefined, undefined, ctx), /could not be verified/);
assert.ok((await inspect()).some((request) => request.id === aId));
const task = spawnSync("bash", [`${process.env.FM_REAL_ROOT}/bin/fm-tasks-axi.sh`, "add", "keyboard-audit", "Keyboard audit"], { env: process.env, encoding: "utf8" });
assert.equal(task.status, 0, task.stdout + task.stderr);
const sourceBefore = readFileSync(`${home}/data/backlog.md`, "utf8");
await tool.execute("filed", { id: aId, disposition: "recorded", taskIds: ["keyboard-audit"], summary: "Queued; fixture pending; firstmate owns the next action." }, undefined, undefined, ctx);
assert.equal(readFileSync(`${home}/data/backlog.md`, "utf8"), sourceBefore);
assert.ok(!(await inspect()).some((request) => request.id === aId));
await assert.rejects(tool.execute("duplicate", { id: aId, disposition: "recorded", taskIds: ["keyboard-audit"], summary: "Again" }, undefined, undefined, ctx), /not unresolved/);
console.log("ok - invented task links refuse; verified links clear intake without launching or completing the task");

// A real provider tool call verifies the public tool schema and SDK execution
// path. The receipt cannot itself manufacture an assistant answer.
await tool.execute("staged", { id: bId, disposition: "reply", summary: "A hexagon has six sides." }, undefined, undefined, ctx);
assert.ok((await inspect()).some((request) => request.id === bId));
const receiptCount = manager.getBranch().filter((entry) => entry.type === "custom" && entry.customType === "fm-request-disposition").length;
await tool.execute("repeat-stage", { id: bId, disposition: "reply", summary: "Already ready to answer" }, undefined, undefined, ctx);
assert.equal(manager.getBranch().filter((entry) => entry.type === "custom" && entry.customType === "fm-request-disposition").length, receiptCount);
assert.equal((await inspect()).find((request) => request.id === bId).replyStaged, true);
nextTool = { id: bId, disposition: "reply", summary: "Answer the hexagon question; no task needed." };
await session.prompt("Answer the pending geometry question.");
await waitFor(() => !session.isStreaming && !(manager.getBranch().at(-1)?.message?.role === "user"), "normal reply");
assert.ok(!(await inspect()).some((request) => request.id === bId));
assert.equal(readFileSync(`${home}/data/backlog.md`, "utf8"), sourceBefore);
const errors = manager.getBranch().filter((entry) => entry.type === "message" && entry.message.role === "toolResult" && entry.message.isError);
assert.deepEqual(errors, []);
assert.ok(stagedContextSeen, "context must ask for the answer instead of repeatedly asking for a staged disposition");
const native = new Map();
discovery.emit("firstmate:native-tools", { register: (definition) => native.set(definition.name, definition) });
assert.equal(native.get("fm_request_disposition")?.execute, tool.execute);
console.log("ok - question dispositions require a normal substantive reply and never create backlog work");

// A staged reply interrupted by an error or new input cannot be cleared by
// an unrelated normal response. These use Pi's real persistence interface.
const assistant = manager.getBranch().filter((entry) => entry.type === "message" && entry.message.role === "assistant").at(-1).message;
const interrupted = manager.appendMessage({ role: "user", content: "Explain the contrast result.", timestamp: Date.now() });
await tool.execute("interrupted-reply", { id: interrupted, disposition: "reply", summary: "Explain contrast." }, undefined, undefined, ctx);
manager.appendMessage({ ...assistant, stopReason: "aborted", content: [], timestamp: Date.now() });
manager.appendMessage({ ...assistant, stopReason: "stop", content: [{ type: "text", text: "Unrelated answer." }], timestamp: Date.now() });
assert.ok((await inspect()).some((request) => request.id === interrupted));
const changed = manager.appendMessage({ role: "user", content: "Change the requested explanation to a short note.", timestamp: Date.now() });
await tool.execute("changed-reply", { id: changed, disposition: "reply", summary: "A short note." }, undefined, undefined, ctx);
manager.appendMessage({ role: "user", content: "Unrelated new question.", timestamp: Date.now() });
manager.appendMessage({ ...assistant, stopReason: "stop", content: [{ type: "text", text: "Side question answered." }], timestamp: Date.now() });
assert.ok((await inspect()).some((request) => request.id === changed));
console.log("ok - aborted and interrupted reply intentions stay unresolved after unrelated normal answers");

const close = spawnSync("bash", [`${process.env.FM_REAL_ROOT}/bin/fm-tasks-axi.sh`, "done", "keyboard-audit"], { env: process.env, encoding: "utf8" });
assert.equal(close.status, 0, close.stdout + close.stderr);
const cancelledSource = readFileSync(`${home}/data/backlog.md`, "utf8");
for (const text of ["Cancel the keyboard audit.", "Cancel the keyboard audit.", "Keep that cancellation; do not restart the audit."]) {
  const id = manager.appendMessage({ role: "user", content: text, timestamp: Date.now() });
  await tool.execute("existing-identity", { id, disposition: "recorded", taskIds: ["keyboard-audit"], summary: "Cancellation already recorded under the original identity; no launch." }, undefined, undefined, ctx);
  assert.equal(readFileSync(`${home}/data/backlog.md`, "utf8"), cancelledSource);
}
console.log("ok - repeated and modified input can link a closed identity without resurrecting or duplicating work");
process.env.FM_TASK_ID = "isolated-worker";
await assert.rejects(inspect(), /does not own the home/);
delete process.env.FM_TASK_ID;
console.log("ok - dispatched workers cannot mutate native primary intake receipts");

// Reopen the same persisted session through Pi's own manager. Dispositions
// and one-attempt receipts survive; no hidden reasoning is read or exported.
const reopened = SessionManager.open(manager.getSessionFile());
assert.deepEqual(reopened.getBranch().filter((entry) => entry.type === "custom").map((entry) => [entry.customType, entry.data]), manager.getBranch().filter((entry) => entry.type === "custom").map((entry) => [entry.customType, entry.data]));
console.log("ok - durable native receipts survive reopening the same session");

// A reload starts from a non-empty leaf. Navigating to a branch without the
// intake boundary must keep intake working for input on that branch.
await session.reload();
manager.resetLeaf();
const navigated = "After navigating, summarise the audit plan.";
const settledBeforeNavigation = events.filter((event) => event === "settled").length;
await session.prompt(navigated);
await waitFor(() => !session.isStreaming && events.filter((event) => event === "settled").length >= settledBeforeNavigation + 2, "navigated branch recovery");
const reloadedTool = session.getToolDefinition("fm_request_disposition");
const navigatedRequests = JSON.parse((await reloadedTool.execute("navigated", {}, undefined, undefined, ctx)).content[0].text);
assert.deepEqual(navigatedRequests.map((request) => request.text), [navigated]);
assert.ok(capturedContext.some((message) => message.customType === "fm-request-intake" && message.content.includes(navigated)));
console.log("ok - a navigated branch without the intake boundary keeps reconciling its own input");
session.dispose();
process.exit(0);
