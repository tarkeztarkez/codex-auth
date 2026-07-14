const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .config } };
    }
    if (args.len < 1) return common.usageErrorResult(allocator, .config, "`config` requires a section.", .{});
    const scope = std.mem.sliceTo(args[0], 0);

    if (std.mem.eql(u8, scope, "live")) {
        return parseLive(allocator, args[1..]);
    }
    if (std.mem.eql(u8, scope, "auto")) {
        return parseAuto(allocator, args[1..]);
    }
    return common.usageErrorResult(allocator, .config, "unknown config section `{s}`.", .{scope});
}

fn parseAuto(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len < 1) return common.usageErrorResult(allocator, .config, "`config auto` requires `enable` or `disable`.", .{});
    const action_text = std.mem.sliceTo(args[0], 0);
    if (std.mem.eql(u8, action_text, "disable")) {
        if (args.len != 1) return common.usageErrorResult(allocator, .config, "`config auto disable` accepts no additional arguments.", .{});
        return .{ .command = .{ .config = .{ .auto = .{ .action = .disable } } } };
    }
    if (!std.mem.eql(u8, action_text, "enable")) {
        return common.usageErrorResult(allocator, .config, "unknown auto action `{s}`.", .{action_text});
    }

    var thresholds: types.AutoThresholds = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const flag = std.mem.sliceTo(args[i], 0);
        if (i + 1 >= args.len) return common.usageErrorResult(allocator, .config, "`{s}` requires a value.", .{flag});
        const raw = std.mem.sliceTo(args[i + 1], 0);
        i += 1;
        if (std.mem.eql(u8, flag, "--5h") or std.mem.eql(u8, flag, "--weekly")) {
            const value = std.fmt.parseInt(u8, raw, 10) catch
                return common.usageErrorResult(allocator, .config, "`{s}` must be an integer from 1 to 100.", .{flag});
            if (value < 1 or value > 100) return common.usageErrorResult(allocator, .config, "`{s}` must be an integer from 1 to 100.", .{flag});
            if (std.mem.eql(u8, flag, "--5h")) thresholds.five_hour_percent = value else thresholds.weekly_percent = value;
            continue;
        }
        if (std.mem.eql(u8, flag, "--interval")) {
            const value = std.fmt.parseInt(u16, raw, 10) catch
                return common.usageErrorResult(allocator, .config, "`--interval` must be an integer from 5 to 3600 seconds.", .{});
            if (value < 5 or value > 3600) return common.usageErrorResult(allocator, .config, "`--interval` must be an integer from 5 to 3600 seconds.", .{});
            thresholds.interval_seconds = value;
            continue;
        }
        return common.usageErrorResult(allocator, .config, "unknown flag `{s}` for `config auto enable`.", .{flag});
    }
    return .{ .command = .{ .config = .{ .auto = .{ .action = .enable, .thresholds = thresholds } } } };
}

fn parseLive(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .config } };
    }
    if (args.len != 2) return common.usageErrorResult(allocator, .config, "`config live` requires `--interval <seconds>`.", .{});
    const flag = std.mem.sliceTo(args[0], 0);
    if (!std.mem.eql(u8, flag, "--interval")) {
        if (std.mem.startsWith(u8, flag, "-")) {
            return common.usageErrorResult(allocator, .config, "unknown flag `{s}` for `config live`.", .{flag});
        }
        return common.usageErrorResult(allocator, .config, "unknown argument `{s}` for `config live`.", .{flag});
    }
    const raw = std.mem.sliceTo(args[1], 0);
    const interval = std.fmt.parseInt(u16, raw, 10) catch
        return common.usageErrorResult(allocator, .config, "`--interval` must be an integer from 5 to 3600 seconds.", .{});
    if (interval < 5 or interval > 3600) {
        return common.usageErrorResult(allocator, .config, "`--interval` must be an integer from 5 to 3600 seconds.", .{});
    }
    return .{ .command = .{ .config = .{ .live = .{ .interval_seconds = interval } } } };
}
