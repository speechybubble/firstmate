// Real Pi lifecycle, scripted local provider, real outcome and completion owners.
// The scripted review is a fixture action, not a production semantic verifier.
import assert from "node:assert/strict";
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";
const home = process.env.FM_HOME;
const root = process.env.FM_REAL_ROOT;
const agentDir = process.env.PI_CODING_AGENT_DIR;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const run = (script, args) => {
  const result = spawnSync("bash", [`${root}/bin/${script}.sh`, ...args], { encoding: "utf8", env: process.env });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  return result.stdout.trim();
};
mkdirSync(`${home}/data/palette-review`, { recursive: true });
writeFileSync(`${home}/state/palette-review.meta`, "kind=scout\n");
writeFileSync(`${home}/state/palette-review.status`, "blocked: [key=owner-review] report ready; firstmate must perform its review\n");
writeFileSync(`${home}/data/palette-review/report.md`, "Save and Cancel fail contrast; replace their foreground. No unresolved product decision.\n");
run("fm-tasks-axi", ["add", "approval-wait", "Separate deployment"]);
run("fm-captain-hold", ["hold", "approval-wait", "--reason", "Deployment requires explicit approval"]);
const heldBefore = run("fm-tasks-axi", ["show", "approval-wait", "--full"]);
run("fm-branch-outcome", ["processed-init"]);
let count = 0;
let release;
let began;
const first = new Promise((resolve) => { began = resolve; });
const held = new Promise((resolve) => { release = resolve; });
let seq;
let reviewed = false;
const outputs = [
  "A hexagon has six sides.",
  { name: "fm_branch_processed", args: () => ({ through: seq }) },
  "", // Internal acknowledgement with no delivered answer: must recover.
  { name: "fixture_review", args: () => ({}) },
  { name: "fm_branch_processed", args: () => ({ through: seq }) },
  "The palette review found insufficient contrast on Save and Cancel. The report was reviewed; the separate deployment still requires approval.",
];
globalThis.fetch = async (input) => {
  assert.ok(String(input instanceof Request ? input.url : input).startsWith("https://fm-intake.invalid/"));
  const index = count++;
  assert.ok(index < outputs.length, "recovery exceeded the scripted finite budget");
  if (index === 0) { began(); await held; }
  const value = outputs[index];
  const chunk = (delta, finish) => `data: ${JSON.stringify({ id: `fixture-${index}`, object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, delta, finish_reason: finish }], ...(finish ? { usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } } : {}) })}\n\n`;
  const delta = typeof value === "string" ? { role: "assistant", content: value } : { role: "assistant", tool_calls: [{ index: 0, id: `call-${index}`, type: "function", function: { name: value.name, arguments: JSON.stringify(value.args()) } }] };
  return new Response(chunk(delta, null) + chunk({}, typeof value === "string" ? "stop" : "tool_calls") + "data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } });
};
const { DefaultResourceLoader, ModelRegistry, ModelRuntime, SessionManager, SettingsManager, createAgentSession } = await import(pathToFileURL(`${process.env.PI_PACKAGE_DIR}/dist/index.js`).href);
const manager = SessionManager.create(home, `${home}/sessions`);
const settings = SettingsManager.create(home, agentDir);
let stages = 0;
const loader = new DefaultResourceLoader({ cwd: home, agentDir, settingsManager: settings,
  additionalExtensionPaths: [process.env.BRANCH_PLUGIN],
  extensionFactories: [{ name: "fixture-review", factory: (pi) => {
    pi.registerTool({ name: "fixture_review", label: "Fixture review", description: "Review the controlled fixture report", parameters: { type: "object", properties: {} }, execute: async () => {
      assert.ok(run("fm-branch-outcome", ["unprocessed"]).includes(`"seq":${seq}`), "empty answer silently retired review obligation");
      assert.match(readFileSync(`${home}/data/palette-review/report.md`, "utf8"), /Save and Cancel/);
      const premature = spawnSync("bash", [`${root}/bin/fm-captain-hold.sh`, "complete", "palette-review", "--none"], { encoding: "utf8", env: process.env });
      assert.notEqual(premature.status, 0, "nonempty report or unresolved owner blocker must not pass completion");
      appendFileSync(`${home}/state/palette-review.status`, "resolved: [key=owner-review] reviewed report; no unresolved product decision\n");
      run("fm-captain-hold", ["complete", "palette-review", "--none"]);
      reviewed = true;
      return { content: [{ type: "text", text: "Reviewed the report and recorded the existing completion attestation; separate approval preserved." }], details: {} };
    } });
    pi.on("agent_settled", () => { stages++; });
  } }], noSkills: true, noThemes: true, noPromptTemplates: true, noContextFiles: true });
await loader.reload();
const runtime = await ModelRuntime.create({ authPath: `${agentDir}/auth.json`, modelsPath: `${agentDir}/models.json` });
const registry = new ModelRegistry(runtime);
await registry.refresh();
const { session } = await createAgentSession({ cwd: home, sessionManager: manager, resourceLoader: loader, settingsManager: settings, modelRuntime: runtime, model: registry.find("fm-intake", "fixture"), noTools: "builtin" });
await session.bindExtensions({ mode: "rpc", onError: (error) => { throw new Error(JSON.stringify(error)); } });
const prompt = session.prompt("Unrelated: how many sides does a hexagon have?");
await first;
seq = Number(run("fm-branch-outcome", ["append", "--task", "palette-review", "--verdict", "captain", "--summary", `Report ready at ${home}/data/palette-review/report.md; firstmate must review and attest before advancing.`]));
release();
await prompt;
const until = Date.now() + 30000;
while (Date.now() < until && (session.isStreaming || count < outputs.length || run("fm-branch-outcome", ["unprocessed"]) !== "")) await new Promise((resolve) => setTimeout(resolve, 50));
assert.equal(count, outputs.length);
assert.ok(reviewed);
assert.equal(run("fm-branch-outcome", ["unprocessed"]), "");
assert.equal(run("fm-tasks-axi", ["show", "approval-wait", "--full"]), heldBefore);
assert.ok(manager.getBranch().some((entry) => entry.type === "message" && entry.message.role === "assistant" && entry.message.stopReason === "stop" && JSON.stringify(entry.message.content).includes("insufficient contrast")));
assert.equal(manager.getBranch().filter((entry) => entry.type === "custom" && entry.customType === "fm-branch-visible-outcome").length, 1);
assert.ok(stages >= 2, "missing automatic retry after empty acknowledgement");
await session.dispose();
const reopened = SessionManager.open(manager.getSessionFile());
assert.equal(reopened.getBranch().filter((entry) => entry.type === "custom" && entry.customType === "fm-branch-processing-receipt").length, 2);
console.log("ok - real Pi recovers an internally acknowledged but undelivered owner-review outcome after a busy topic switch, delivers findings without a user prompt, and preserves independent approval");
