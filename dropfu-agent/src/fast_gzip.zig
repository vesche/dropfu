//! Gzip inflate built at ReleaseFast and linked into every agent binary.
//!
//! Debug-mode std.compress.flate takes several seconds to inflate the embedded
//! CPython archive. CI runs the debug agent, and that delay exceeds the
//! end-to-end command timeout before the first plugin can answer.

const std = @import("std");

export fn dropfu_gzip_decompress(
    src_ptr: [*]const u8,
    src_len: usize,
    dst_ptr: [*]u8,
    dst_len: usize,
) isize {
    const src = src_ptr[0..src_len];
    const dst = dst_ptr[0..dst_len];
    var input: std.Io.Reader = .fixed(src);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor: std.compress.flate.Decompress = .init(&input, .gzip, &window);
    decompressor.reader.readSliceAll(dst) catch return -1;
    var extra: [1]u8 = undefined;
    const trailing = decompressor.reader.readSliceShort(&extra) catch return -1;
    if (trailing != 0) return -1;
    return @intCast(dst_len);
}
