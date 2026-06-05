const builtin = @import("builtin");
const std = @import("std");
const http_env = @import("../api/http_env.zig");
const http_executable = @import("../api/http_executable.zig");
const app_runtime = @import("../core/runtime.zig");
const io_util = @import("../core/io_util.zig");
const types = @import("types.zig");
const output = @import("output.zig");

pub const WindowsCodexPathKind = enum {
    exe,
    cmd,
    ps1,
};

pub const WindowsCodexPath = struct {
    path: []u8,
    kind: WindowsCodexPathKind,

    pub fn deinit(self: *WindowsCodexPath, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

const CodexLaunch = struct {
    owned_paths: [2]?[]u8 = .{ null, null },
    argv_storage: [9][]const u8 = undefined,
    argv_len: usize = 0,

    fn argv(self: *const CodexLaunch) []const []const u8 {
        return self.argv_storage[0..self.argv_len];
    }

    fn deinit(self: *CodexLaunch, allocator: std.mem.Allocator) void {
        for (self.owned_paths) |maybe_path| {
            if (maybe_path) |path| allocator.free(path);
        }
    }
};

pub fn codexLoginArgs(opts: types.LoginOptions) []const []const u8 {
    return if (opts.device_auth)
        &[_][]const u8{ "codex", "login", "--device-auth" }
    else
        &[_][]const u8{ "codex", "login" };
}

pub fn resolveWindowsCodexPathEntryAlloc(
    allocator: std.mem.Allocator,
    entry: []const u8,
) !?WindowsCodexPath {
    const candidates = [_]struct {
        name: []const u8,
        kind: WindowsCodexPathKind,
    }{
        .{ .name = "codex.exe", .kind = .exe },
        .{ .name = "codex.cmd", .kind = .cmd },
        .{ .name = "codex.ps1", .kind = .ps1 },
    };

    for (candidates) |candidate| {
        if (try resolvePathEntryCandidateAlloc(allocator, entry, candidate.name)) |path| {
            return .{ .path = path, .kind = candidate.kind };
        }
    }

    return null;
}

pub fn resolveWindowsCodexPathEntriesAlloc(
    allocator: std.mem.Allocator,
    entries: []const []const u8,
) !?WindowsCodexPath {
    for (entries) |entry| {
        if (entry.len == 0) continue;
        if (try resolveWindowsCodexPathEntryAlloc(allocator, entry)) |resolved| return resolved;
    }
    return null;
}

fn resolvePathEntryCandidateAlloc(
    allocator: std.mem.Allocator,
    entry: []const u8,
    candidate_name: []const u8,
) !?[]u8 {
    const candidate = try std.fs.path.join(allocator, &[_][]const u8{ entry, candidate_name });
    errdefer allocator.free(candidate);

    if (!accessPath(candidate)) {
        allocator.free(candidate);
        return null;
    }

    return candidate;
}

fn accessPath(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(app_runtime.io(), path, .{}) catch return false;
        return true;
    }

    std.Io.Dir.cwd().access(app_runtime.io(), path, .{}) catch return false;
    return true;
}

fn resolveWindowsCodexPathAlloc(allocator: std.mem.Allocator) !?WindowsCodexPath {
    const path_value = http_env.getEnvVarOwned(allocator, "PATH") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    defer allocator.free(path_value);

    var path_it = std.mem.splitScalar(u8, path_value, std.fs.path.delimiter);
    while (path_it.next()) |entry| {
        if (entry.len == 0) continue;
        if (try resolveWindowsCodexPathEntryAlloc(allocator, entry)) |resolved| return resolved;
    }

    return null;
}

fn resolveOptionalExecutableAlloc(
    allocator: std.mem.Allocator,
    executable: []const u8,
) !?[]u8 {
    return http_executable.ensureExecutableAvailableAlloc(allocator, executable) catch |err| switch (err) {
        error.ExecutableRequired => null,
        else => return err,
    };
}

fn resolveWindowsPowerShellExecutableAlloc(allocator: std.mem.Allocator) ![]u8 {
    if (try resolveOptionalExecutableAlloc(allocator, "powershell.exe")) |path| return path;
    if (try resolveOptionalExecutableAlloc(allocator, "pwsh.exe")) |path| return path;
    return error.FileNotFound;
}

fn buildCodexLaunchAlloc(allocator: std.mem.Allocator, opts: types.LoginOptions) !CodexLaunch {
    if (builtin.os.tag != .windows) {
        var launch = CodexLaunch{};
        const args = codexLoginArgs(opts);
        @memcpy(launch.argv_storage[0..args.len], args);
        launch.argv_len = args.len;
        return launch;
    }

    var resolved = (try resolveWindowsCodexPathAlloc(allocator)) orelse return error.FileNotFound;
    errdefer resolved.deinit(allocator);

    switch (resolved.kind) {
        .exe, .cmd => {
            var launch = CodexLaunch{ .owned_paths = .{ resolved.path, null } };
            launch.argv_storage[0] = resolved.path;
            launch.argv_storage[1] = "login";
            launch.argv_len = 2;
            if (opts.device_auth) {
                launch.argv_storage[2] = "--device-auth";
                launch.argv_len = 3;
            }
            return launch;
        },
        .ps1 => {
            const powershell = try resolveWindowsPowerShellExecutableAlloc(allocator);
            errdefer allocator.free(powershell);

            var launch = CodexLaunch{ .owned_paths = .{ powershell, resolved.path } };
            launch.argv_storage[0] = powershell;
            launch.argv_storage[1] = "-NoLogo";
            launch.argv_storage[2] = "-NoProfile";
            launch.argv_storage[3] = "-ExecutionPolicy";
            launch.argv_storage[4] = "Bypass";
            launch.argv_storage[5] = "-File";
            launch.argv_storage[6] = resolved.path;
            launch.argv_storage[7] = "login";
            launch.argv_len = 8;
            if (opts.device_auth) {
                launch.argv_storage[8] = "--device-auth";
                launch.argv_len = 9;
            }
            return launch;
        },
    }
}

fn ensureCodexLoginSucceeded(term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| {
            if (code == 0) return;
            return error.CodexLoginFailed;
        },
        else => return error.CodexLoginFailed,
    }
}

fn writeCodexLoginLaunchFailureHint(err_name: []const u8) !void {
    var stderr: io_util.Stderr = undefined;
    stderr.init();
    const out = stderr.out();
    try output.writeCodexLoginLaunchFailureHintTo(out, err_name, stderr.color_enabled);
    try out.flush();
}

pub fn runCodexLogin(opts: types.LoginOptions, codex_home: []const u8) !void {
    var env_map = try app_runtime.currentEnviron().createMap(std.heap.page_allocator);
    defer env_map.deinit();
    try env_map.put("CODEX_HOME", codex_home);

    var launch = buildCodexLaunchAlloc(std.heap.page_allocator, opts) catch |err| {
        writeCodexLoginLaunchFailureHint(@errorName(err)) catch {};
        return err;
    };
    defer launch.deinit(std.heap.page_allocator);

    var child = std.process.spawn(app_runtime.io(), .{
        .argv = launch.argv(),
        .environ_map = &env_map,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        writeCodexLoginLaunchFailureHint(@errorName(err)) catch {};
        return err;
    };
    const term = child.wait(app_runtime.io()) catch |err| {
        writeCodexLoginLaunchFailureHint(@errorName(err)) catch {};
        return err;
    };
    try ensureCodexLoginSucceeded(term);
}
