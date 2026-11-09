import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { parseCommand } from "./commandLine.ts";

describe("parseCommand", () => {
  it("parses whitespace and quoted arguments", () => {
    assert.deepEqual(parseCommand("find '/var/log files' \"*.log\""), [
      "find",
      "/var/log files",
      "*.log",
    ]);
  });

  it("supports escaped spaces and quotes", () => {
    assert.deepEqual(parseCommand("cat path\\ with\\ spaces"), ["cat", "path with spaces"]);
    assert.deepEqual(parseCommand("find . \"a\\\"b\""), ["find", ".", 'a"b']);
  });

  it("rejects unterminated quotes", () => {
    assert.throws(() => parseCommand("cat 'unfinished"), /unterminated quote/);
  });
});
