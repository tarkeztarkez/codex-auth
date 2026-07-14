const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .daemon } };
    }
    if (args.len == 0) return common.usageErrorResult(allocator, .top_level, "`daemon` requires `--watch` or `--once`.", .{});

    var opts: types.DaemonOptions = .{ .watch = false };
    var mode_set = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.sliceTo(args[i], 0);
        if (std.mem.eql(u8, arg, "--watch") or std.mem.eql(u8, arg, "--once")) {
            if (mode_set) return common.usageErrorResult(allocator, .top_level, "choose exactly one of `--watch` or `--once`.", .{});
            opts.watch = std.mem.eql(u8, arg, "--watch");
            mode_set = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--5h")) {
            opts.thresholds.five_hour_percent = parsePercent(args, &i) orelse
                return common.usageErrorResult(allocator, .top_level, "`{s}` requires a percentage from 1 to 100.", .{arg});
            continue;
        }
        if (std.mem.eql(u8, arg, "--weekly")) {
            opts.thresholds.weekly_percent = parsePercent(args, &i) orelse
                return common.usageErrorResult(allocator, .top_level, "`{s}` requires a percentage from 1 to 100.", .{arg});
            continue;
        }
        if (std.mem.eql(u8, arg, "--interval")) {
            opts.thresholds.interval_seconds = parseInterval(args, &i) orelse
                return common.usageErrorResult(allocator, .top_level, "`--interval` requires seconds from 5 to 3600.", .{});
            continue;
        }
        return common.usageErrorResult(allocator, .top_level, "unknown flag `{s}` for `daemon`.", .{arg});
    }
    if (!mode_set) return common.usageErrorResult(allocator, .top_level, "`daemon` requires `--watch` or `--once`.", .{});
    return .{ .command = .{ .daemon = opts } };
}

fn parsePercent(args: []const [:0]const u8, i: *usize) ?u8 {
    if (i.* + 1 >= args.len) return null;
    i.* += 1;
    const value = std.fmt.parseInt(u8, std.mem.sliceTo(args[i.*], 0), 10) catch return null;
    if (value < 1 or value > 100) return null;
    return value;
}

fn parseInterval(args: []const [:0]const u8, i: *usize) ?u16 {
    if (i.* + 1 >= args.len) return null;
    i.* += 1;
    const value = std.fmt.parseInt(u16, std.mem.sliceTo(args[i.*], 0), 10) catch return null;
    if (value < 5 or value > 3600) return null;
    return value;
}
