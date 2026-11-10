import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  formatFileSize,
  parseDirectoryListing,
  parseFilePreview,
  remoteBasename,
} from "./fileManager.ts";

describe("file manager data", () => {
  it("validates and sorts directory listings", () => {
    const listing = parseDirectoryListing(JSON.stringify({
      path: "/tmp",
      parent: "/",
      truncated: false,
      entries: [
        { name: "z.txt", path: "/tmp/z.txt", kind: "file", size: 12, modified: 1 },
        { name: "folder", path: "/tmp/folder", kind: "directory", size: 0, modified: 2 },
        { name: "a.txt", path: "/tmp/a.txt", kind: "file", size: 4, modified: 3 },
      ],
    }));

    assert.deepEqual(listing.entries.map((entry) => entry.name), ["folder", "a.txt", "z.txt"]);
  });

  it("rejects malformed listings and previews", () => {
    assert.throws(() => parseDirectoryListing('{"path":"/","entries":[]}'));
    assert.throws(() => parseFilePreview(JSON.stringify({
      path: "/tmp/a",
      name: "a",
      kind: "file",
      size: -1,
      modified: 1,
      text: null,
      binary: true,
      truncated: false,
    })));
  });

  it("parses text previews", () => {
    const preview = parseFilePreview(JSON.stringify({
      path: "/tmp/a.txt",
      name: "a.txt",
      kind: "file",
      size: 5,
      modified: 1,
      text: "hello",
      binary: false,
      truncated: false,
    }));
    assert.equal(preview.text, "hello");
  });

  it("formats remote names and sizes", () => {
    assert.equal(remoteBasename("/var/log/"), "log");
    assert.equal(remoteBasename("C:\\Windows\\Temp"), "Temp");
    assert.equal(formatFileSize(1024), "1.0 KiB");
  });
});
