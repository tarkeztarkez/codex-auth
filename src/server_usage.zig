const std = @import("std");
const app_runtime = @import("core/runtime.zig");
const auth = @import("auth/auth.zig");
const chatgpt_http = @import("api/http.zig");
const http_child = @import("api/http_child.zig");
const http_executable = @import("api/http_executable.zig");
const usage_api = @import("api/usage.zig");

const poll_interval_seconds: u64 = 3 * 60;
const oauth_client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
const oauth_token_endpoint = "https://auth.openai.com/oauth/token";
const c = @cImport({
    @cInclude("time.h");
});

fn successful(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn envOwned(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    var map = try app_runtime.currentEnviron().createMap(allocator);
    defer map.deinit();
    const value = map.get(name) orelse return null;
    return try allocator.dupe(u8, value);
}

fn psql(allocator: std.mem.Allocator, database_url: []const u8, query: []const u8, output_limit: usize) ![]u8 {
    var result = try http_child.runChildCaptureWithOutputLimit(
        allocator,
        &.{ "psql", "--no-psqlrc", "--set", "ON_ERROR_STOP=1", "--tuples-only", "--no-align", database_url, "--command", query },
        30_000,
        null,
        output_limit,
    );
    defer result.deinit(allocator);
    if (result.timed_out) return error.DatabaseTimedOut;
    if (!successful(result.term)) return error.DatabaseRequestFailed;
    return allocator.dupe(u8, result.stdout);
}

fn hexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const alphabet = "0123456789abcdef";
    const encoded = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        encoded[index * 2] = alphabet[byte >> 4];
        encoded[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return encoded;
}

pub fn ensureSchema(allocator: std.mem.Allocator, database_url: []const u8) !void {
    const output = try psql(
        allocator,
        database_url,
        "ALTER TABLE credentials ADD COLUMN IF NOT EXISTS usage_status integer, ADD COLUMN IF NOT EXISTS usage_body text, ADD COLUMN IF NOT EXISTS usage_fetched_at timestamptz",
        1024 * 1024,
    );
    allocator.free(output);
}

pub fn getUsageJson(allocator: std.mem.Allocator, database_url: []const u8) ![]u8 {
    const rows = try psql(
        allocator,
        database_url,
        "SELECT json_build_object('account_key', account_key, 'status_code', usage_status, 'body', usage_body, 'fetched_at', extract(epoch from usage_fetched_at)::bigint)::text FROM credentials ORDER BY account_key",
        64 * 1024 * 1024,
    );
    defer allocator.free(rows);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.writeByte('[');
    var first = true;
    var lines = std.mem.splitScalar(u8, rows, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len == 0) continue;
        if (!first) try aw.writer.writeByte(',');
        first = false;
        try aw.writer.writeAll(line);
    }
    try aw.writer.writeByte(']');
    return aw.toOwnedSlice();
}

const OAuthResponse = struct {
    body: []u8,
    status_code: ?u16,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

fn refreshRequest(allocator: std.mem.Allocator, refresh_token: []const u8) !OAuthResponse {
    const curl = try http_executable.resolveCurlExecutableForLaunchAlloc(allocator);
    defer allocator.free(curl);
    var body_writer: std.Io.Writer.Allocating = .init(allocator);
    defer body_writer.deinit();
    const client_id_override = try envOwned(allocator, "CODEX_APP_SERVER_LOGIN_CLIENT_ID");
    defer if (client_id_override) |value| allocator.free(value);
    const endpoint_override = try envOwned(allocator, "CODEX_REFRESH_TOKEN_URL_OVERRIDE");
    defer if (endpoint_override) |value| allocator.free(value);
    try std.json.Stringify.value(.{
        .client_id = client_id_override orelse oauth_client_id,
        .grant_type = "refresh_token",
        .refresh_token = refresh_token,
    }, .{}, &body_writer.writer);
    var result = try http_child.runChildCaptureWithInputAndOutputLimit(
        allocator,
        &.{ curl, "--silent", "--show-error", "--max-time", "10", "--header", "Content-Type: application/json", "--data-binary", "@-", "--write-out", "\n%{http_code}", endpoint_override orelse oauth_token_endpoint },
        body_writer.written(),
        12_000,
        null,
        1024 * 1024,
    );
    defer result.deinit(allocator);
    if (result.timed_out or !successful(result.term)) return error.OAuthRefreshRequestFailed;
    const marker = std.mem.lastIndexOfScalar(u8, result.stdout, '\n') orelse return error.InvalidOAuthRefreshResponse;
    const status = std.fmt.parseInt(u16, std.mem.trim(u8, result.stdout[marker + 1 ..], "\r\n"), 10) catch null;
    return .{ .body = try allocator.dupe(u8, result.stdout[0..marker]), .status_code = status };
}

fn nowRfc3339(allocator: std.mem.Allocator) ![]u8 {
    var timestamp: c.time_t = @intCast(std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds());
    var tm: c.struct_tm = undefined;
    if (c.gmtime_r(&timestamp, &tm) == null) return error.TimeConversionFailed;
    var buffer: [32]u8 = undefined;
    const len = c.strftime(&buffer, buffer.len, "%Y-%m-%dT%H:%M:%SZ", &tm);
    if (len == 0) return error.TimeConversionFailed;
    return allocator.dupe(u8, buffer[0..len]);
}

pub fn refreshAuthAlloc(allocator: std.mem.Allocator, auth_data: []const u8) ![]u8 {
    var auth_json = try std.json.parseFromSlice(std.json.Value, allocator, auth_data, .{});
    defer auth_json.deinit();
    const root = switch (auth_json.value) {
        .object => |value| value,
        else => return error.InvalidAuthDocument,
    };
    const tokens = switch (root.get("tokens") orelse return error.RefreshTokenMissing) {
        .object => |value| value,
        else => return error.RefreshTokenMissing,
    };
    const refresh_token = switch (tokens.get("refresh_token") orelse return error.RefreshTokenMissing) {
        .string => |value| value,
        else => return error.RefreshTokenMissing,
    };
    if (refresh_token.len == 0) return error.RefreshTokenMissing;
    var response = try refreshRequest(allocator, refresh_token);
    defer response.deinit(allocator);
    const status = response.status_code orelse return error.InvalidOAuthRefreshResponse;
    if (status < 200 or status > 299) return error.OAuthRefreshRejected;
    return applyRefreshResponseAlloc(allocator, auth_data, response.body);
}

fn applyRefreshResponseAlloc(allocator: std.mem.Allocator, auth_data: []const u8, response_body: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, auth_data, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |*value| value,
        else => return error.InvalidAuthDocument,
    };
    const tokens_value = root.getPtr("tokens") orelse return error.RefreshTokenMissing;
    const tokens = switch (tokens_value.*) {
        .object => |*value| value,
        else => return error.RefreshTokenMissing,
    };
    var response_json = try std.json.parseFromSlice(std.json.Value, allocator, response_body, .{});
    defer response_json.deinit();
    const response_obj = switch (response_json.value) {
        .object => |value| value,
        else => return error.InvalidOAuthRefreshResponse,
    };
    const auth_allocator = parsed.arena.allocator();
    var changed = false;
    inline for (.{ "access_token", "id_token", "refresh_token" }) |field| {
        if (response_obj.get(field)) |value| switch (value) {
            .string => |token| if (token.len != 0) {
                try tokens.put(auth_allocator, field, .{ .string = try auth_allocator.dupe(u8, token) });
                changed = true;
            },
            else => {},
        };
    }
    if (!changed) return error.InvalidOAuthRefreshResponse;
    const refreshed_at = try nowRfc3339(auth_allocator);
    try root.put(auth_allocator, "last_refresh", .{ .string = refreshed_at });
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &output.writer);
    return output.toOwnedSlice();
}

fn isExpired(result: chatgpt_http.HttpResult, allocator: std.mem.Allocator) bool {
    if (result.status_code != 401) return false;
    const code = usage_api.parseNonSuccessErrorCode(allocator, result.status_code, result.body) orelse return false;
    return std.mem.eql(u8, code.text(), "token_expired");
}

fn persistResult(
    allocator: std.mem.Allocator,
    database_url: []const u8,
    account_key: []const u8,
    status_code: ?u16,
    body: []const u8,
    refreshed_auth: ?[]const u8,
) !void {
    const key_hex = try hexAlloc(allocator, account_key);
    defer allocator.free(key_hex);
    const body_hex = try hexAlloc(allocator, body);
    defer allocator.free(body_hex);
    const status_sql = if (status_code) |status| try std.fmt.allocPrint(allocator, "{d}", .{status}) else try allocator.dupe(u8, "NULL");
    defer allocator.free(status_sql);
    const auth_clause = if (refreshed_auth) |auth_data| blk: {
        const auth_hex = try hexAlloc(allocator, auth_data);
        defer allocator.free(auth_hex);
        break :blk try std.fmt.allocPrint(allocator, ", envelope = jsonb_set(envelope, '{{auth}}', convert_from(decode('{s}','hex'),'UTF8')::jsonb)", .{auth_hex});
    } else try allocator.dupe(u8, "");
    defer allocator.free(auth_clause);
    const query = try std.fmt.allocPrint(
        allocator,
        "UPDATE credentials SET usage_status = {s}, usage_body = convert_from(decode('{s}','hex'),'UTF8'), usage_fetched_at = now(){s} WHERE account_key = convert_from(decode('{s}','hex'),'UTF8')",
        .{ status_sql, body_hex, auth_clause, key_hex },
    );
    defer allocator.free(query);
    const output = try psql(allocator, database_url, query, 1024 * 1024);
    allocator.free(output);
}

fn refreshOne(allocator: std.mem.Allocator, database_url: []const u8, account_key: []const u8, auth_data: []const u8) !void {
    var info = try auth.parseAuthInfoData(allocator, auth_data);
    defer info.deinit(allocator);
    if (info.auth_mode != .chatgpt) return;
    const access_token = info.access_token orelse return error.AccessTokenMissing;
    const account_id = info.chatgpt_account_id orelse return error.AccountIdMissing;
    var usage = try chatgpt_http.runGetJsonCommand(allocator, usage_api.default_usage_endpoint, access_token, account_id);
    var usage_body_owned = true;
    defer if (usage_body_owned) allocator.free(usage.body);
    var refreshed_auth: ?[]u8 = null;
    defer if (refreshed_auth) |data| allocator.free(data);
    if (isExpired(usage, allocator)) {
        refreshed_auth = refreshAuthAlloc(allocator, auth_data) catch |err| {
            std.log.warn("server token refresh failed for {s}: {s}", .{ account_key, @errorName(err) });
            try persistResult(allocator, database_url, account_key, usage.status_code, usage.body, null);
            return;
        };
        var refreshed_info = try auth.parseAuthInfoData(allocator, refreshed_auth.?);
        defer refreshed_info.deinit(allocator);
        const refreshed_key = refreshed_info.record_key orelse return error.ReauthenticatedAccountIdentityMissing;
        if (!std.mem.eql(u8, refreshed_key, account_key)) return error.ReauthenticatedAccountIdentityMismatch;
        const refreshed_access = refreshed_info.access_token orelse return error.AccessTokenMissing;
        const refreshed_account = refreshed_info.chatgpt_account_id orelse return error.AccountIdMissing;
        allocator.free(usage.body);
        usage_body_owned = false;
        usage = chatgpt_http.runGetJsonCommand(allocator, usage_api.default_usage_endpoint, refreshed_access, refreshed_account) catch |err| {
            try persistResult(allocator, database_url, account_key, null, "", refreshed_auth);
            return err;
        };
        usage_body_owned = true;
    }
    try persistResult(allocator, database_url, account_key, usage.status_code, usage.body, refreshed_auth);
}

pub fn pollOnce(allocator: std.mem.Allocator, database_url: []const u8) !void {
    const rows = try psql(allocator, database_url, "SELECT json_build_object('account_key', account_key, 'auth', envelope->'auth')::text FROM credentials ORDER BY account_key", 64 * 1024 * 1024);
    defer allocator.free(rows);
    var lines = std.mem.splitScalar(u8, rows, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |value| value,
            else => continue,
        };
        const account_key = switch (obj.get("account_key") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        const auth_value = obj.get("auth") orelse continue;
        var auth_writer: std.Io.Writer.Allocating = .init(allocator);
        defer auth_writer.deinit();
        try std.json.Stringify.value(auth_value, .{}, &auth_writer.writer);
        refreshOne(allocator, database_url, account_key, auth_writer.written()) catch |err|
            std.log.warn("server usage refresh failed for {s}: {s}", .{ account_key, @errorName(err) });
    }
}

fn worker(database_url: []u8) void {
    defer std.heap.smp_allocator.free(database_url);
    while (true) {
        pollOnce(std.heap.smp_allocator, database_url) catch |err|
            std.log.err("server usage polling failed: {s}", .{@errorName(err)});
        std.Io.sleep(app_runtime.io(), .fromSeconds(poll_interval_seconds), .awake) catch {};
    }
}

pub fn start(database_url: []const u8) !void {
    const owned_url = try std.heap.smp_allocator.dupe(u8, database_url);
    errdefer std.heap.smp_allocator.free(owned_url);
    const thread = try std.Thread.spawn(.{}, worker, .{owned_url});
    thread.detach();
}

test "OAuth refresh response rotates stored Codex tokens" {
    const allocator = std.testing.allocator;
    const refreshed = try applyRefreshResponseAlloc(
        allocator,
        "{\"tokens\":{\"access_token\":\"old-access\",\"id_token\":\"old-id\",\"refresh_token\":\"old-refresh\",\"account_id\":\"account\"},\"last_refresh\":\"2020-01-01T00:00:00Z\"}",
        "{\"access_token\":\"new-access\",\"id_token\":\"new-id\",\"refresh_token\":\"new-refresh\"}",
    );
    defer allocator.free(refreshed);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, refreshed, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const tokens = root.get("tokens").?.object;
    try std.testing.expectEqualStrings("new-access", tokens.get("access_token").?.string);
    try std.testing.expectEqualStrings("new-id", tokens.get("id_token").?.string);
    try std.testing.expectEqualStrings("new-refresh", tokens.get("refresh_token").?.string);
    try std.testing.expectEqualStrings("account", tokens.get("account_id").?.string);
    try std.testing.expect(root.get("last_refresh") != null);
}
