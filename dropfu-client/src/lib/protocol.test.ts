import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { parseMessage, buildCommand, MSG_COMMAND, PROTOCOL_VERSION } from "./protocol.ts";

describe("protocol", () => {
  it("parses valid messages", () => {
    const msg = parseMessage({
      type: "result",
      id: "abc",
      timestamp: 1,
      payload: { status: "success", data: "ok", content_type: "application/json" },
    });
    assert.ok(msg);
    assert.equal(msg!.type, "result");
    assert.equal(msg!.type === "result" ? msg!.payload.content_type : null, "application/json");
  });

  it("rejects invalid messages", () => {
    assert.equal(parseMessage(null), null);
    assert.equal(parseMessage({ type: "nope", id: "a", timestamp: 1 }), null);
    assert.equal(parseMessage({ type: "result", timestamp: 1 }), null);
    assert.equal(parseMessage({ type: "result", id: "a", timestamp: 1, payload: {} }), null);
    assert.equal(parseMessage({
      type: "result",
      id: "a",
      timestamp: 1,
      payload: { status: "success", data: "ok", content_type: 42 },
    }), null);
    assert.equal(parseMessage({
      type: "agent_list",
      id: "a",
      timestamp: 1,
      payload: { agents: "not-an-array" },
    }), null);
    assert.equal(parseMessage({
      type: "heartbeat",
      id: "a",
      timestamp: 1,
      protocol_version: 999,
      payload: {},
    }), null);
  });

  it("validates agent list entries", () => {
    const msg = parseMessage({
      type: "agent_list",
      id: "abc",
      timestamp: 1,
      protocol_version: PROTOCOL_VERSION,
      payload: {
        agents: [{
          agent_id: "deadbeef",
          hostname: "host",
          os: "linux",
          arch: "x86_64",
          privilege: "user",
          connected_at: 1,
          last_seen: 2,
        }],
      },
    });
    assert.ok(msg);
    assert.equal(msg.type, "agent_list");
  });

  it("builds commands with protocol version", () => {
    const cmd = buildCommand("deadbeef", "pwd", []);
    assert.equal(cmd.type, MSG_COMMAND);
    assert.equal(cmd.protocol_version, PROTOCOL_VERSION);
    assert.equal(cmd.agent_id, "deadbeef");
  });
});
