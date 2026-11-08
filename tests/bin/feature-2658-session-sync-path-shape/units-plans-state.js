"use strict";
// In-process plans and state parts of tests/bin/feature-2658-session-sync-path-shape.js (#2658).
// Holds no case markers.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");

function plansRoots(F) {
  const root = fs.mkdtempSync(path.join(F.TMP, "plans-"));
  const plansDir = path.join(root, "plans-dir");
  const projects = path.join(root, "projects");
  fs.mkdirSync(plansDir);
  fs.mkdirSync(projects);
  return { plansDir, projects };
}

function plansGuards(F) {
  const plans = F.lib("plans");
  const read = (file) => fs.readFileSync(file, "utf8");
  test("toProjects: plans in projects being a file blocks every plan, without a throw", () => {
    const { plansDir, projects } = plansRoots(F);
    F.write(path.join(plansDir, "a-plan.md"), "plan a\n");
    F.write(path.join(plansDir, "z-plan.md"), "plan z\n");
    F.write(path.join(projects, "plans"), "a file\n");
    assert.strictEqual(plans.toProjects(plansDir, projects), 0);
    assert.strictEqual(read(path.join(projects, "plans")), "a file\n");
  });
  test("toProjects: a directory at the target is skipped, and the other plan still copies", () => {
    const { plansDir, projects } = plansRoots(F);
    F.write(path.join(plansDir, "a-blocked.md"), "plan a\n");
    F.write(path.join(plansDir, "z-normal.md"), "plan z\n");
    fs.mkdirSync(path.join(projects, "plans", "a-blocked.md"), { recursive: true });
    assert.strictEqual(plans.toProjects(plansDir, projects), 1);
    assert.strictEqual(read(path.join(projects, "plans", "z-normal.md")), "plan z\n");
    assert.ok(fs.statSync(path.join(projects, "plans", "a-blocked.md")).isDirectory());
  });
  test("fromProjects: a directory at the destination is skipped, and the other plan still copies", () => {
    const { plansDir, projects } = plansRoots(F);
    F.write(path.join(projects, "plans", "a-blocked.md"), "plan a\n");
    F.write(path.join(projects, "plans", "z-normal.md"), "plan z\n");
    fs.mkdirSync(path.join(plansDir, "a-blocked.md"));
    assert.strictEqual(plans.fromProjects(plansDir, projects, new Map()), 1);
    assert.strictEqual(read(path.join(plansDir, "z-normal.md")), "plan z\n");
    assert.ok(fs.statSync(path.join(plansDir, "a-blocked.md")).isDirectory());
  });
  test("fromProjects: plans in projects being a file copies nothing, without a throw", () => {
    const { plansDir, projects } = plansRoots(F);
    F.write(path.join(projects, "plans"), "a file\n");
    assert.strictEqual(plans.fromProjects(plansDir, projects, new Map()), 0);
    assert.deepStrictEqual(fs.readdirSync(plansDir), []);
  });
  test("both directions copy every plan when nothing blocks them", () => {
    const { plansDir, projects } = plansRoots(F);
    F.write(path.join(plansDir, "a.md"), "plan a\n");
    F.write(path.join(plansDir, "z.md"), "plan z\n");
    assert.strictEqual(plans.toProjects(plansDir, projects), 2);
    const back = plansRoots(F);
    fs.cpSync(path.join(projects, "plans"), path.join(back.projects, "plans"), { recursive: true });
    assert.strictEqual(plans.fromProjects(back.plansDir, back.projects, new Map()), 2);
    assert.strictEqual(read(path.join(back.plansDir, "z.md")), "plan z\n");
  });
}

function writeBlockedState(F) {
  const state = F.lib("state");
  const gitDir = () => fs.mkdtempSync(path.join(F.TMP, "state-"));
  const run = (stats) => ({ action: "pull", result: "ok", startedAt: "2026-01-02T03:04:05.000Z", stats });
  test("state: writeBlocked adds up across runs and a run without one keeps the last path", () => {
    const dir = gitDir();
    state.record(dir, run({ writeBlocked: { count: 2, path: "a/b" } }));
    state.record(dir, run({ writeBlocked: { count: 1, path: "c/d" } }));
    assert.deepStrictEqual(state.load(dir).writeBlocked, { count: 3, path: "c/d" });
    state.record(dir, run(state.newStats()));
    assert.deepStrictEqual(state.load(dir).writeBlocked, { count: 3, path: "c/d" });
  });
  test("state: a state file written before writeBlocked existed loads with a zero count", () => {
    const dir = gitDir();
    fs.writeFileSync(path.join(dir, state.STATE_NAME), `${JSON.stringify({ schema: 1, consecutiveFailures: 2 })}\n`);
    const st = state.load(dir);
    assert.deepStrictEqual(st.writeBlocked, { count: 0, path: null });
    assert.strictEqual(st.consecutiveFailures, 2);
  });
}

module.exports = { plansGuards, writeBlockedState };
