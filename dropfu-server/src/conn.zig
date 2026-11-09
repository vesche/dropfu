const std = @import("std");

pub const Conn = struct {
    io: std.Io,
    stream: std.Io.net.Stream,

    pub fn read(self: Conn, buf: []u8) !usize {
        var iov: [1][]u8 = .{buf};
        const result = try self.stream.readWithControl(self.io, &iov, &.{});
        return result.data_len;
    }

    pub fn writeAll(self: Conn, data: []const u8) !void {
        var scratch: [4096]u8 = undefined;
        var w = self.stream.writer(self.io, &scratch);
        try w.interface.writeAll(data);
        try w.interface.flush();
    }

    pub fn close(self: Conn) void {
        self.stream.close(self.io);
    }
};
