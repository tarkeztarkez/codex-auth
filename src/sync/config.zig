const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const registry = @import("../registry/root.zig");

pub const Config = struct {
    url: []u8,
    api_token: []u8,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.api_token);
    }
};

const ConfigOut = struct { url: []const u8, api_token: []const u8 };

pub fn pathAlloc(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ codex_home, "accounts", "server.json" });
}

pub fn load(allocator: std.mem.Allocator, codex_home: []const u8) !?Config {
    const path = try pathAlloc(allocator, codex_home);
    defer allocator.free(path);
    var file = std.Io.Dir.cwd().openFile(app_runtime.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(app_runtime.io());
    const data = try registry.readFileAlloc(file, allocator, 64 * 1024);
    defer allocator.free(data);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidServerConfig,
    };
    const url = switch (obj.get("url") orelse return error.InvalidServerConfig) {
        .string => |value| value,
        else => return error.InvalidServerConfig,
    };
    const token = switch (obj.get("api_token") orelse return error.InvalidServerConfig) {
        .string => |value| value,
        else => return error.InvalidServerConfig,
    };
    if (url.len == 0 or token.len == 0) return error.InvalidServerConfig;
    return .{ .url = try allocator.dupe(u8, std.mem.trimEnd(u8, url, "/")), .api_token = try allocator.dupe(u8, token) };
}

pub fn save(allocator: std.mem.Allocator, codex_home: []const u8, url: []const u8, api_token: []const u8) !void {
    if ((!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) or api_token.len == 0)
        return error.InvalidServerConfig;
    try registry.ensureAccountsDir(allocator, codex_home);
    const path = try pathAlloc(allocator, codex_home);
    defer allocator.free(path);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.value(ConfigOut{ .url = std.mem.trimEnd(u8, url, "/"), .api_token = api_token }, .{ .whitespace = .indent_2 }, &aw.writer);
    try registry.writeFile(path, aw.written());
}

pub fn remove(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const path = try pathAlloc(allocator, codex_home);
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(app_runtime.io(), path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
