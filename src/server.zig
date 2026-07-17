const std = @import("std");
const app_runtime = @import("core/runtime.zig");
const http_child = @import("api/http_child.zig");
const server_usage = @import("server_usage.zig");

const json_header = std.http.Header{ .name = "content-type", .value = "application/json" };

fn envOwned(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    var map = try app_runtime.currentEnviron().createMap(allocator);
    defer map.deinit();
    const value = map.get(name) orelse return null;
    return @as(?[]u8, try allocator.dupe(u8, value));
}

fn authorized(request: *const std.http.Server.Request, api_token: []const u8) bool {
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "authorization")) continue;
        const prefix = "Bearer ";
        if (!std.mem.startsWith(u8, header.value, prefix)) return false;
        const supplied = header.value[prefix.len..];
        if (supplied.len != api_token.len) return false;
        var supplied_digest: [32]u8 = undefined;
        var expected_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(supplied, &supplied_digest, .{});
        std.crypto.hash.sha2.Sha256.hash(api_token, &expected_digest, .{});
        return std.crypto.timing_safe.eql([32]u8, supplied_digest, expected_digest);
    }
    return false;
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
    const successful = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!successful) {
        if (result.stderr.len != 0) std.log.err("database request failed: {s}", .{std.mem.trim(u8, result.stderr, "\r\n")});
        return error.DatabaseRequestFailed;
    }
    return allocator.dupe(u8, result.stdout);
}

fn ensureSchema(allocator: std.mem.Allocator, database_url: []const u8) !void {
    const output = try psql(
        allocator,
        database_url,
        "CREATE TABLE IF NOT EXISTS credentials (account_key text PRIMARY KEY, envelope jsonb NOT NULL, updated_at timestamptz NOT NULL DEFAULT now())",
        1024 * 1024,
    );
    allocator.free(output);
}

fn validateDatabaseName(name: []const u8) !void {
    if (name.len == 0 or name.len > 63) return error.InvalidDatabaseName;
    for (name) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
        else => return error.InvalidDatabaseName,
    };
}

fn databaseUrlAlloc(allocator: std.mem.Allocator, admin_url: []const u8, database_name: []const u8) ![]u8 {
    const query_start = std.mem.indexOfScalar(u8, admin_url, '?') orelse admin_url.len;
    const path_end = std.mem.lastIndexOfScalar(u8, admin_url[0..query_start], '/') orelse return error.InvalidDatabaseUrl;
    if (path_end < (std.mem.indexOf(u8, admin_url, "://") orelse return error.InvalidDatabaseUrl) + 3)
        return error.InvalidDatabaseUrl;
    return std.mem.concat(allocator, u8, &.{ admin_url[0 .. path_end + 1], database_name, admin_url[query_start..] });
}

fn ensureDatabase(allocator: std.mem.Allocator, admin_url: []const u8, database_name: []const u8) !void {
    try validateDatabaseName(database_name);
    const check_query = try std.fmt.allocPrint(allocator, "SELECT 1 FROM pg_database WHERE datname = '{s}'", .{database_name});
    defer allocator.free(check_query);
    const existing = try psql(allocator, admin_url, check_query, 1024 * 1024);
    defer allocator.free(existing);
    if (std.mem.eql(u8, std.mem.trim(u8, existing, " \r\n\t"), "1")) return;
    const create_query = try std.fmt.allocPrint(allocator, "CREATE DATABASE {s}", .{database_name});
    defer allocator.free(create_query);
    const output = try psql(allocator, admin_url, create_query, 1024 * 1024);
    allocator.free(output);
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

fn respondJson(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    try request.respond(body, .{ .status = status, .extra_headers = &.{json_header} });
}

fn handlePut(allocator: std.mem.Allocator, request: *std.http.Server.Request, database_url: []const u8) !void {
    if ((request.head.content_length orelse 0) > 16 * 1024 * 1024) return respondJson(request, .payload_too_large, "{\"error\":\"payload_too_large\"}");
    var transfer_buffer: [8192]u8 = undefined;
    const reader = request.server.reader.bodyReader(&transfer_buffer, request.head.transfer_encoding, request.head.content_length);
    const body = reader.allocRemaining(allocator, .limited(16 * 1024 * 1024)) catch return respondJson(request, .bad_request, "{\"error\":\"invalid_body\"}");
    defer allocator.free(body);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return respondJson(request, .bad_request, "{\"error\":\"invalid_json\"}");
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return respondJson(request, .bad_request, "{\"error\":\"invalid_envelope\"}"),
    };
    const key = switch (obj.get("account_key") orelse return respondJson(request, .bad_request, "{\"error\":\"missing_account_key\"}")) {
        .string => |value| value,
        else => return respondJson(request, .bad_request, "{\"error\":\"invalid_account_key\"}"),
    };
    if (key.len == 0 or key.len > 1024 or obj.get("auth") == null) return respondJson(request, .bad_request, "{\"error\":\"invalid_envelope\"}");
    const key_hex = try hexAlloc(allocator, key);
    defer allocator.free(key_hex);
    const body_hex = try hexAlloc(allocator, body);
    defer allocator.free(body_hex);
    const query = try std.fmt.allocPrint(
        allocator,
        "INSERT INTO credentials (account_key, envelope, updated_at) VALUES (convert_from(decode('{s}','hex'),'UTF8'), convert_from(decode('{s}','hex'),'UTF8')::jsonb, now()) ON CONFLICT (account_key) DO UPDATE SET envelope = EXCLUDED.envelope, updated_at = now()",
        .{ key_hex, body_hex },
    );
    defer allocator.free(query);
    const output = try psql(allocator, database_url, query, 1024 * 1024);
    allocator.free(output);
    try respondJson(request, .ok, "{\"ok\":true}");
}

fn handleGet(allocator: std.mem.Allocator, request: *std.http.Server.Request, database_url: []const u8) !void {
    const rows = try psql(allocator, database_url, "SELECT envelope::text FROM credentials ORDER BY account_key", 64 * 1024 * 1024);
    defer allocator.free(rows);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeByte('[');
    var first = true;
    var lines = std.mem.splitScalar(u8, rows, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        parsed.deinit();
        if (!first) try aw.writer.writeByte(',');
        first = false;
        try aw.writer.writeAll(line);
    }
    try aw.writer.writeByte(']');
    try respondJson(request, .ok, aw.written());
}

fn serveRequest(allocator: std.mem.Allocator, request: *std.http.Server.Request, api_token: []const u8, database_url: []const u8) !void {
    if (request.head.method == .GET and std.mem.eql(u8, request.head.target, "/health")) return respondJson(request, .ok, "{\"ok\":true}");
    if (!authorized(request, api_token)) return respondJson(request, .unauthorized, "{\"error\":\"unauthorized\"}");
    if (request.head.method == .GET and std.mem.eql(u8, request.head.target, "/v1/usage")) {
        const body = try server_usage.getUsageJson(allocator, database_url);
        defer allocator.free(body);
        return respondJson(request, .ok, body);
    }
    if (!std.mem.eql(u8, request.head.target, "/v1/credentials")) return respondJson(request, .not_found, "{\"error\":\"not_found\"}");
    switch (request.head.method) {
        .GET => try handleGet(allocator, request, database_url),
        .PUT => try handlePut(allocator, request, database_url),
        else => try respondJson(request, .method_not_allowed, "{\"error\":\"method_not_allowed\"}"),
    }
}

fn acceptConnection(allocator: std.mem.Allocator, stream: std.Io.net.Stream, api_token: []const u8, database_url: []const u8) void {
    defer stream.close(app_runtime.io());
    var recv_buffer: [32 * 1024]u8 = undefined;
    var send_buffer: [32 * 1024]u8 = undefined;
    var conn_reader = stream.reader(app_runtime.io(), &recv_buffer);
    var conn_writer = stream.writer(app_runtime.io(), &send_buffer);
    var server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);
    while (server.reader.state == .ready) {
        var request = server.receiveHead() catch return;
        serveRequest(allocator, &request, api_token, database_url) catch |err| {
            std.log.err("server request failed: {s}", .{@errorName(err)});
            return;
        };
    }
}

pub fn run(allocator: std.mem.Allocator, port_override: ?u16) !void {
    const api_token = (try envOwned(allocator, "API_TOKEN")) orelse return error.ApiTokenRequired;
    defer allocator.free(api_token);
    if (api_token.len < 16) return error.ApiTokenTooShort;
    const admin_database_url = (try envOwned(allocator, "DATABASE_URL")) orelse return error.DatabaseUrlRequired;
    defer allocator.free(admin_database_url);
    const database_name = (try envOwned(allocator, "DATABASE_NAME")) orelse try allocator.dupe(u8, "codex_auth");
    defer allocator.free(database_name);
    try ensureDatabase(allocator, admin_database_url, database_name);
    const database_url = try databaseUrlAlloc(allocator, admin_database_url, database_name);
    defer allocator.free(database_url);
    try ensureSchema(allocator, database_url);
    try server_usage.ensureSchema(allocator, database_url);
    try server_usage.start(database_url);
    const port = port_override orelse blk: {
        const raw = (try envOwned(allocator, "PORT")) orelse break :blk @as(u16, 8080);
        defer allocator.free(raw);
        break :blk try std.fmt.parseInt(u16, raw, 10);
    };
    const address = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    var listener = try address.listen(app_runtime.io(), .{ .reuse_address = true });
    defer listener.deinit(app_runtime.io());
    std.log.info("credential server listening on 0.0.0.0:{d}", .{port});
    while (true) {
        const stream = try listener.accept(app_runtime.io());
        acceptConnection(allocator, stream, api_token, database_url);
    }
}
