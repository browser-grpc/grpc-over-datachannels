// Webhook receiver + serial agent worker for GitHub issues.
// Receives `issues` events, queues member-authored opened/reopened
// issues, and for each: clones the repo, runs `muse exec` to fix it,
// pushes a branch, opens a PR, and comments on the issue.
import http from "node:http";
import crypto from "node:crypto";
import { execFile } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";

const REPO = process.env.IA_REPO || "browser-grpc/grpc-over-datachannels";
const PORT = Number(process.env.IA_PORT || 8787);
const STATE = process.env.IA_STATE_DIR || join(process.env.HOME, ".local/state/issue-agent");
const SECRET = readFileSync(join(STATE, "secret.txt"), "utf8").trim();
const AGENT_TIMEOUT_MS = Number(process.env.IA_AGENT_TIMEOUT_MS || 30 * 60 * 1000);
const MEMBER_ASSOC = new Set(["OWNER", "MEMBER", "COLLABORATOR"]);
const ACTIONS = new Set(["opened", "reopened"]);

mkdirSync(join(STATE, "work"), { recursive: true });

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

function run(cmd, args, opts = {}) {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, { maxBuffer: 64 * 1024 * 1024, ...opts }, (err, stdout, stderr) => {
      if (err) reject(Object.assign(err, { stdout, stderr }));
      else resolve({ stdout, stderr });
    });
  });
}

async function ghComment(issue, body) {
  const f = join(STATE, `comment-${issue}-${Date.now()}.txt`);
  writeFileSync(f, body);
  await run("gh", ["issue", "comment", String(issue), "--repo", REPO, "--body-file", f]);
  rmSync(f, { force: true });
}

function slugify(title) {
  return title.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 30) || "issue";
}

const queue = [];
let working = false;
const seenDeliveries = new Set();

async function processIssue({ issue, sender }) {
  const n = issue.number;
  const labels = (issue.labels || []).map((l) => l.name);
  const dryRun = labels.includes("agent-dry-run");
  const branch = `issue-agent/${n}-${slugify(issue.title)}`;
  log(`issue #${n} "${issue.title}" by ${sender} (dryRun=${dryRun})`);
  if (dryRun) {
    log(`dry-run: would comment, clone, run muse exec, push ${branch}, open PR for #${n}`);
    return;
  }
  const dir = join(STATE, "work", `issue-${n}`);
  rmSync(dir, { recursive: true, force: true });
  try {
    await ghComment(n, "[issue-agent] Working on this now. I will open a PR here if I land a fix, or report what I found.");
    await run("git", ["clone", "--quiet", `https://github.com/${REPO}.git`, dir]);
    await run("git", ["-C", dir, "checkout", "-b", branch]);
    const prompt = [
      `You are fixing GitHub issue #${n} in this repository checkout.`,
      ``,
      `Title: ${issue.title}`,
      ``,
      `Body:`,
      issue.body || "(no body)",
      ``,
      `Make the smallest correct fix: reproduce the problem first when`,
      `practical, fix the root cause, and run the relevant tests.`,
      `Do NOT git commit, push, or open pull requests - leave your`,
      `changes uncommitted in the working tree.`,
      `Your final message must summarize: what you changed, which`,
      `tests you ran and their results, and anything you did not do.`,
    ].join("\n");
    const pf = join(STATE, `prompt-${n}.txt`);
    writeFileSync(pf, prompt);
    let summary = "";
    try {
      const r = await run(
        "muse",
        ["exec", "--yolo", "--workspace", dir, "--prompt-file", pf,
         "--user-input-auto-resolve", "--no-session-log"],
        { timeout: AGENT_TIMEOUT_MS, cwd: dir }
      );
      summary = r.stdout.trim();
    } catch (e) {
      summary = (e.stdout || "").trim();
      log(`issue #${n}: muse exec ended with error: ${e.message}`);
      if (!summary) throw e;
    } finally {
      rmSync(pf, { force: true });
    }
    const tail = summary.split("\n").slice(-40).join("\n").slice(0, 6000);
    const { stdout: status } = await run("git", ["-C", dir, "status", "--porcelain"]);
    if (!status.trim()) {
      await ghComment(n, `[issue-agent] I investigated this but made no code changes.\n\n${tail}`);
      log(`issue #${n}: no changes`);
      return;
    }
    await run("git", ["-C", dir, "add", "-A"]);
    await run("git", ["-C", dir, "commit", "-q", "-m", `fix: ${issue.title} (#${n})`]);
    await run("git", ["-C", dir, "push", "-q", "origin", branch]);
    const prBody = join(STATE, `pr-${n}.txt`);
    writeFileSync(prBody, `Fixes #${n}\n\n${tail}\n`);
    const { stdout: prOut } = await run("gh", [
      "pr", "create", "--repo", REPO, "--head", branch,
      "--title", `fix: ${issue.title}`, "--body-file", prBody,
    ]);
    rmSync(prBody, { force: true });
    const prUrl = prOut.trim().split("\n").pop();
    await ghComment(n, `[issue-agent] Opened a PR for review: ${prUrl}\n\n${tail}`);
    log(`issue #${n}: PR ${prUrl}`);
    rmSync(dir, { recursive: true, force: true });
  } catch (e) {
    log(`issue #${n} FAILED: ${e.message}`);
    try {
      await ghComment(n, `[issue-agent] I hit an error while working on this and stopped. Details are in the operator log (${e.message.slice(0, 200)}).`);
    } catch { /* best effort */ }
  }
}

async function pump() {
  if (working) return;
  working = true;
  while (queue.length) {
    const item = queue.shift();
    try { await processIssue(item); } catch (e) { log("worker error:", e.message); }
  }
  working = false;
}

const server = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/healthz") {
    res.writeHead(200, { "content-type": "text/plain" });
    res.end("ok\n");
    return;
  }
  if (req.method !== "POST" || req.url !== "/webhook") {
    res.writeHead(404); res.end(); return;
  }
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const raw = Buffer.concat(chunks);
    const sig = req.headers["x-hub-signature-256"] || "";
    const expect = "sha256=" + crypto.createHmac("sha256", SECRET).update(raw).digest("hex");
    const ok = sig.length === expect.length && crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(expect));
    if (!ok) { res.writeHead(401); res.end("bad signature"); return; }
    const event = req.headers["x-github-event"];
    const delivery = req.headers["x-github-delivery"] || "";
    if (event === "ping") { res.writeHead(200); res.end("pong"); return; }
    if (event !== "issues") { res.writeHead(202); res.end("ignored event"); return; }
    let payload;
    try { payload = JSON.parse(raw.toString("utf8")); } catch { res.writeHead(400); res.end("bad json"); return; }
    if (payload.repository?.full_name !== REPO) { res.writeHead(202); res.end("ignored repo"); return; }
    if (!ACTIONS.has(payload.action)) { res.writeHead(202); res.end("ignored action"); return; }
    const assoc = payload.issue?.author_association || "";
    if (!MEMBER_ASSOC.has(assoc)) {
      log(`skip #${payload.issue?.number}: author_association=${assoc}`);
      res.writeHead(202); res.end("ignored author"); return;
    }
    if (delivery && seenDeliveries.has(delivery)) { res.writeHead(200); res.end("duplicate"); return; }
    if (delivery) {
      seenDeliveries.add(delivery);
      if (seenDeliveries.size > 500) seenDeliveries.delete(seenDeliveries.values().next().value);
    }
    queue.push({ issue: payload.issue, sender: payload.sender?.login || "?" });
    res.writeHead(202); res.end("queued");
    pump();
  });
});

server.listen(PORT, "127.0.0.1", () => log(`issue-agent listening on 127.0.0.1:${PORT} repo=${REPO}`));
