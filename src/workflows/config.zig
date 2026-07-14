const std = @import("std");
const cli = @import("../cli/root.zig");
const io_util = @import("../core/io_util.zig");
const registry = @import("../registry/root.zig");
const auto_service = @import("../auto/service.zig");

pub fn handleConfig(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.ConfigOptions) !void {
    switch (opts) {
        .live => |live_opts| try handleLiveCommand(allocator, codex_home, live_opts),
        .auto => |auto_opts| try handleAutoCommand(allocator, codex_home, auto_opts),
    }
}

fn handleAutoCommand(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.AutoConfigOptions) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    switch (opts.action) {
        .enable => {
            try auto_service.enable(allocator, codex_home, opts.thresholds);
            try out.print(
                "Background auto-switch enabled: 5h <= {d}%, weekly <= {d}%, interval {d}s\n",
                .{ opts.thresholds.five_hour_percent, opts.thresholds.weekly_percent, opts.thresholds.interval_seconds },
            );
        },
        .disable => {
            try auto_service.disable(allocator);
            try out.writeAll("Background auto-switch disabled\n");
        },
    }
    try out.flush();
}

fn handleLiveCommand(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.LiveOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    reg.live.interval_seconds = opts.interval_seconds;
    try registry.saveRegistry(allocator, codex_home, &reg);

    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try out.print("Live refresh interval: {d}s\n", .{opts.interval_seconds});
    try out.flush();
}
