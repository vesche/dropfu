import { beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  bindRequest,
  completeRequest,
  deletePane,
  ensurePane,
  resolveRequest,
  setState,
  state,
} from "./session.ts";

describe("session request routing", () => {
  beforeEach(() => {
    setState("outputs", {});
    setState("panes", {});
    setState("requestToPane", {});
    setState("transfers", {});
    setState("selectedAgentId", null);
  });

  it("binds and completes a request in one pane", () => {
    ensurePane("left", "deadbeef");
    bindRequest("request-1", "left");
    assert.equal(resolveRequest("request-1"), "left");
    assert.deepEqual(state.panes.left?.pendingRequestIds, ["request-1"]);

    completeRequest("request-1");
    assert.equal(resolveRequest("request-1"), null);
    assert.deepEqual(state.panes.left?.pendingRequestIds, []);
  });

  it("does not disturb another pane's pending requests", () => {
    bindRequest("request-left", "left");
    bindRequest("request-right", "right");
    completeRequest("request-left");

    assert.deepEqual(state.panes.left?.pendingRequestIds, []);
    assert.deepEqual(state.panes.right?.pendingRequestIds, ["request-right"]);
    assert.equal(resolveRequest("request-right"), "right");
  });

  it("removes request mappings when a pane is deleted", () => {
    bindRequest("request-1", "left");
    deletePane("left");
    assert.equal(resolveRequest("request-1"), null);
    assert.equal(state.panes.left, undefined);
  });
});
