import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { parseMessage, buildCommand, MSG_COMMAND, PROTOCOL_VERSION } from "./protocol.ts";

describe("protocol", () => {
  it("parses valid messages", () => {
    const msg = parseMessage({
      type: "result",
      id: "abc",
      timestamp: 1,
      payload: { status: "success", data: "ok" },
    });
    assert.ok(msg);
    assert.equal(msg!.type, "result");
  });

  it("rejects invalid messages", () => {
    assert.equal(parseMessage(null), null);
    assert.equal(parseMessage({ type: "nope", id: "a", timestamp: 1 }), null);
    assert.equal(parseMessage({ type: "result", timestamp: 1 }), null);
  });

  it("builds commands with protocol version", () => {
    const cmd = buildCommand("deadbeef", "pwd", []);
    assert.equal(cmd.type, MSG_COMMAND);
    assert.equal(cmd.protocol_version, PROTOCOL_VERSION);
    assert.equal(cmd.agent_id, "deadbeef");
  });
});
