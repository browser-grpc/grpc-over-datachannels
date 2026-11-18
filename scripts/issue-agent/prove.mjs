// Signed smoke test: dry-run issue event + bad-signature rejection.
import crypto from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const STATE = process.env.IA_STATE_DIR || join(process.env.HOME, ".local/state/issue-agent");
const { url, repo } = JSON.parse(readFileSync(join(STATE, "state.json"), "utf8"));
const secret = readFileSync(join(STATE, "secret.txt"), "utf8").trim();

function sign(body) {
  return "sha256=" + crypto.createHmac("sha256", secret).update(body).digest("hex");
}

async function post(body, sig, what) {
  const r = await fetch(`${url}/webhook`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-github-event": "issues",
      "x-github-delivery": crypto.randomUUID(),
      "x-hub-signature-256": sig,
    },
    body,
  });
  console.log(`${what}: HTTP ${r.status} ${await r.text()}`);
  return r.status;
}

const payload = JSON.stringify({
  action: "opened",
  repository: { full_name: repo },
  sender: { login: "unicomp21" },
  issue: {
    number: 9999,
    title: "[prove] dry-run pipeline check",
    body: "Signed smoke test. Must produce a dry-run log line and no side effects.",
    author_association: "OWNER",
    labels: [{ name: "agent-dry-run" }],
  },
});

const good = await post(payload, sign(payload), "dry-run event");
const bad = await post(payload, "sha256=deadbeef", "bad signature");
if (good === 202 && bad === 401) {
  console.log("PROOF OK - check server.log for the dry-run line");
} else {
  console.log("PROOF FAILED");
  process.exit(1);
}
