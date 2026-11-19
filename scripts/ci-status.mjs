#!/usr/bin/env node
// CI status across the generated public repos: latest CI
// run per repo, failing job names when red. Detection
// only — publishing gates live in release-push.sh.
//
// Usage: node scripts/ci-status.mjs [--watch]
//   --watch  poll every 60s until no run is in progress.
// Exit code: 1 when any repo's latest CI run failed.

import { execFileSync } from "node:child_process";

const REPOS = [
  "grpc-over-datachannels",
  "kafka-proxy",
  "kafka-native",
  "eventbus",
  "examples",
  "grpc-dc-php",
  "kafka-grpc-php",
  "eventbus-grpc-php",
];
const ORG = "browser-grpc";
const watch = process.argv.includes("--watch");

function gh(args) {
  try {
    return execFileSync("gh", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
  } catch (e) {
    // A repo with no CI workflow is a stable "no runs";
    // anything else (rate limit, network) is a lookup
    // failure and must never read as "settled".
    if (String(e.stderr ?? "").includes("could not find any workflows")) return "";
    throw e;
  }
}

function latestCiRun(repo) {
  try {
    const out = gh([
      "run", "list", "--repo", `${ORG}/${repo}`,
      "--workflow", "CI", "--limit", "1",
      "--json", "databaseId,status,conclusion,displayTitle,createdAt",
    ]);
    const runs = JSON.parse(out || "[]");
    return runs[0] ?? null;
  } catch {
    return { status: "lookup-failed", displayTitle: "gh lookup failed" };
  }
}

function failingJobs(repo, runId) {
  try {
    const out = gh(["run", "view", String(runId), "--repo", `${ORG}/${repo}`, "--json", "jobs"]);
    return JSON.parse(out).jobs
      .filter((j) => j.conclusion === "failure")
      .map((j) => j.name);
  } catch {
    return [];
  }
}

function sweep() {
  let anyFailed = false;
  let anyRunning = false;
  for (const repo of REPOS) {
    const run = latestCiRun(repo);
    if (!run) {
      console.log(`${repo}: no CI runs`);
      continue;
    }
    const state = run.status === "completed" ? run.conclusion : run.status;
    if (run.status === "lookup-failed") {
      console.log(`${repo}: lookup failed (treating as still running)`);
      anyRunning = true;
      continue;
    }
    if (state === "failure") {
      anyFailed = true;
      const jobs = failingJobs(repo, run.databaseId);
      console.log(`${repo}: FAILURE (${run.displayTitle}) — failed jobs: ${jobs.join(", ") || "?"}`);
    } else {
      if (run.status !== "completed") anyRunning = true;
      console.log(`${repo}: ${state} (${run.displayTitle})`);
    }
  }
  return { anyFailed, anyRunning };
}

for (;;) {
  const { anyFailed, anyRunning } = sweep();
  if (!watch || !anyRunning) {
    process.exit(anyFailed ? 1 : 0);
  }
  console.log("... runs in progress; re-checking in 60s");
  await new Promise((r) => setTimeout(r, 60_000));
}
