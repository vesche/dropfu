import { beforeEach, after, describe, it } from "node:test";
import assert from "node:assert/strict";
import { connect, disconnect, send, status } from "./ws.ts";
import { buildCommand } from "./protocol.ts";

type Handler = ((event?: unknown) => void) | null;

class FakeWebSocket {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSING = 2;
  static readonly CLOSED = 3;
  static instances: FakeWebSocket[] = [];

  readyState = FakeWebSocket.CONNECTING;
  onopen: Handler = null;
  onclose: Handler = null;
  onerror: Handler = null;
  onmessage: Handler = null;
  sent: string[] = [];

  constructor(readonly url: string) {
    FakeWebSocket.instances.push(this);
  }

  open() {
    this.readyState = FakeWebSocket.OPEN;
    this.onopen?.();
  }

  send(data: string) {
    this.sent.push(data);
  }

  close() {
    this.readyState = FakeWebSocket.CLOSED;
  }

  emitClose() {
    this.readyState = FakeWebSocket.CLOSED;
    this.onclose?.();
  }
}

const originalWebSocket = globalThis.WebSocket;

describe("websocket lifecycle", () => {
  beforeEach(() => {
    disconnect();
    FakeWebSocket.instances = [];
    globalThis.WebSocket = FakeWebSocket as unknown as typeof WebSocket;
  });

  after(() => {
    disconnect();
    globalThis.WebSocket = originalWebSocket;
  });

  it("ignores close events from a replaced socket", () => {
    connect();
    const first = FakeWebSocket.instances[0]!;
    first.open();
    assert.equal(status(), "connected");

    disconnect();
    connect();
    const second = FakeWebSocket.instances[1]!;
    assert.equal(status(), "connecting");

    first.emitClose();
    assert.equal(status(), "connecting");

    second.open();
    assert.equal(status(), "connected");
    assert.equal(send(buildCommand("deadbeef", "pwd", [])), true);
    assert.equal(second.sent.length, 1);
  });

  it("returns false while disconnected", () => {
    disconnect();
    assert.equal(send(buildCommand("deadbeef", "pwd", [])), false);
  });
});
