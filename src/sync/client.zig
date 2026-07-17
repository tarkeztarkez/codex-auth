const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const auth = @import("../auth/auth.zig");
const http_child = @import("../api/http_child.zig");
const http_executable = @import("../api/http_executable.zig");
const registry = @import("../registry/root.zig");
const config_mod = @import("config.zig");

const max_response_bytes = 64 * 1024 * 1024;

fn successful(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn endpointAlloc(allocator: std.mem.Allocator, config: *const config_mod.Config) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/v1/credentials", .{config.url});
}

fn runCurl(allocator: std.mem.Allocator, argv: []const []const u8, input: ?[]const u8) ![]u8 {
    var result = try http_child.runChildCaptureWithInputAndOutputLimit(allocator, argv, input, 30_000, null, max_response_bytes);
    defer result.deinit(allocator);
    if (result.timed_out) return error.ServerSyncTimedOut;
    if (!successful(result.term)) {
        if (result.stderr.len != 0) std.log.warn("credential server request failed: {s}", .{std.mem.trim(u8, result.stderr, "\r\n")});
        return error.ServerSyncRequestFailed;
    }
    return allocator.dupe(u8, result.stdout);
}

fn envelopeAlloc(allocator: std.mem.Allocator, key: []const u8, auth_data: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, auth_data, .{});
    defer parsed.deinit();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.writeAll("{\"account_key\":");
    try std.json.Stringify.value(key, .{}, &aw.writer);
    try aw.writer.writeAll(",\"auth\":");
    try std.json.Stringify.value(parsed.value, .{}, &aw.writer);
    try aw.writer.writeByte('}');
    return aw.toOwnedSlice();
}

pub fn pushAccount(allocator: std.mem.Allocator, codex_home: []const u8, account_key: []const u8) !bool {
    var config = (try config_mod.load(allocator, codex_home)) orelse return false;
    defer config.deinit(allocator);
    const curl = try http_executable.resolveCurlExecutableForLaunchAlloc(allocator);
    defer allocator.free(curl);
    const endpoint = try endpointAlloc(allocator, &config);
    defer allocator.free(endpoint);
    const auth_path = try registry.accountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(auth_path);
    var file = try std.Io.Dir.cwd().openFile(app_runtime.io(), auth_path, .{});
    defer file.close(app_runtime.io());
    const auth_data = try registry.readFileAlloc(file, allocator, 16 * 1024 * 1024);
    defer allocator.free(auth_data);
    const body = try envelopeAlloc(allocator, account_key, auth_data);
    defer allocator.free(body);
    const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{config.api_token});
    defer allocator.free(auth_header);
    const response = try runCurl(allocator, &.{ curl, "--fail-with-body", "--silent", "--show-error", "--request", "PUT", "--header", auth_header, "--header", "Content-Type: application/json", "--data-binary", "@-", endpoint }, body);
    allocator.free(response);
    return true;
}

pub fn pushAll(allocator: std.mem.Allocator, codex_home: []const u8, reg: *const registry.Registry) !usize {
    if ((try config_mod.load(allocator, codex_home))) |loaded| {
        var config = loaded;
        config.deinit(allocator);
    } else return 0;
    var count: usize = 0;
    for (reg.accounts.items) |rec| {
        if (try pushAccount(allocator, codex_home, rec.account_key)) count += 1;
    }
    return count;
}

pub fn pull(allocator: std.mem.Allocator, codex_home: []const u8, reg: *registry.Registry) !usize {
    var config = (try config_mod.load(allocator, codex_home)) orelse return 0;
    defer config.deinit(allocator);
    const curl = try http_executable.resolveCurlExecutableForLaunchAlloc(allocator);
    defer allocator.free(curl);
    const endpoint = try endpointAlloc(allocator, &config);
    defer allocator.free(endpoint);
    const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{config.api_token});
    defer allocator.free(auth_header);
    const response = try runCurl(allocator, &.{ curl, "--fail-with-body", "--silent", "--show-error", "--header", auth_header, endpoint }, null);
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const items = switch (parsed.value) {
        .array => |array| array,
        else => return error.InvalidServerResponse,
    };
    var count: usize = 0;
    for (items.items) |item| {
        const obj = switch (item) {
            .object => |value| value,
            else => continue,
        };
        const key = switch (obj.get("account_key") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        const auth_value = obj.get("auth") orelse continue;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try std.json.Stringify.value(auth_value, .{}, &aw.writer);
        var info = auth.parseAuthInfoData(allocator, aw.written()) catch continue;
        defer info.deinit(allocator);
        const actual_key = info.record_key orelse continue;
        if (!std.mem.eql(u8, key, actual_key)) continue;
        const dest = try registry.accountAuthPath(allocator, codex_home, key);
        defer allocator.free(dest);
        try registry.writeFile(dest, aw.written());
        const alias = if (registry.findAccountIndexByAccountKey(reg, key)) |idx| reg.accounts.items[idx].alias else "";
        const record = try registry.accountFromAuth(allocator, alias, &info);
        try registry.upsertAccount(allocator, reg, record);
        count += 1;
    }
    if (count > 0) try registry.saveRegistry(allocator, codex_home, reg);
    return count;
}

pub fn syncAll(allocator: std.mem.Allocator, codex_home: []const u8, reg: *registry.Registry) !usize {
    const pulled = try pull(allocator, codex_home, reg);
    _ = try pushAll(allocator, codex_home, reg);
    return pulled;
}
