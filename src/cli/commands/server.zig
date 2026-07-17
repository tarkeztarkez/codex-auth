const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) return .{ .command = .{ .help = .server } };
    var opts: types.ServerOptions = .{};
    if (args.len == 0) return .{ .command = .{ .server = opts } };
    if (args.len != 2 or !std.mem.eql(u8, std.mem.sliceTo(args[0], 0), "--port"))
        return common.usageErrorResult(allocator, .server, "`server` accepts only `--port <port>`.", .{});
    opts.port = std.fmt.parseInt(u16, std.mem.sliceTo(args[1], 0), 10) catch
        return common.usageErrorResult(allocator, .server, "`--port` must be a valid TCP port.", .{});
    return .{ .command = .{ .server = opts } };
}
