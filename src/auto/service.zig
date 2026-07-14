const std = @import("std");
const builtin = @import("builtin");
const app_runtime = @import("../core/runtime.zig");
const registry = @import("../registry/root.zig");
const types = @import("../cli/types.zig");
const legacy_background = @import("../workflows/legacy_background.zig");

const service_name = "codex-auth-autoswitch.service";

pub fn enable(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    thresholds: types.AutoThresholds,
) !void {
    if (builtin.os.tag != .linux) return error.AutoSwitchServiceUnsupported;

    const home = try registry.resolveUserHome(allocator);
    defer allocator.free(home);
    const unit_dir = try std.fs.path.join(allocator, &.{ home, ".config", "systemd", "user" });
    defer allocator.free(unit_dir);
    try std.Io.Dir.cwd().createDirPath(app_runtime.io(), unit_dir);
    const unit_path = try std.fs.path.join(allocator, &.{ unit_dir, service_name });
    defer allocator.free(unit_path);

    const executable = try std.process.executablePathAlloc(app_runtime.io(), allocator);
    defer allocator.free(executable);
    const unit = try std.fmt.allocPrint(
        allocator,
        \\[Unit]
        \\Description=codex-auth background account auto-switch watcher
        \\After=network-online.target
        \\Wants=network-online.target
        \\
        \\[Service]
        \\Type=simple
        \\Restart=always
        \\RestartSec=5
        \\Environment="CODEX_HOME={s}"
        \\ExecStart="{s}" daemon --watch --5h {d} --weekly {d} --interval {d}
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    , .{
        codex_home,
        executable,
        thresholds.five_hour_percent,
        thresholds.weekly_percent,
        thresholds.interval_seconds,
    });
    defer allocator.free(unit);
    try registry.writeFile(unit_path, unit);

    try runSystemctl(allocator, &.{ "systemctl", "--user", "daemon-reload" });
    try runSystemctl(allocator, &.{ "systemctl", "--user", "enable", service_name });
    try runSystemctl(allocator, &.{ "systemctl", "--user", "restart", service_name });
}

pub fn disable(allocator: std.mem.Allocator) !void {
    _ = try legacy_background.clean(allocator);
}

fn runSystemctl(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, app_runtime.io(), .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    if (result.stderr.len != 0) std.log.err("systemctl: {s}", .{result.stderr});
    return error.AutoSwitchServiceCommandFailed;
}
