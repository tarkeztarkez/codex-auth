const std = @import("std");
const app_runtime = @import("core/runtime.zig");
const registry = @import("registry/root.zig");

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

fn credentialPathAlloc(allocator: std.mem.Allocator, data_dir: []const u8, key: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{hex});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ data_dir, filename });
}

fn respondJson(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    try request.respond(body, .{ .status = status, .extra_headers = &.{json_header} });
}

fn handlePut(allocator: std.mem.Allocator, request: *std.http.Server.Request, data_dir: []const u8) !void {
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
    const path = try credentialPathAlloc(allocator, data_dir, key);
    defer allocator.free(path);
    try registry.writeFile(path, body);
    try respondJson(request, .ok, "{\"ok\":true}");
}

fn handleGet(allocator: std.mem.Allocator, request: *std.http.Server.Request, data_dir: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeByte('[');
    var dir = std.Io.Dir.cwd().openDir(app_runtime.io(), data_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try aw.writer.writeByte(']');
            return respondJson(request, .ok, aw.written());
        },
        else => return err,
    };
    defer dir.close(app_runtime.io());
    var iterator = dir.iterate();
    var first = true;
    while (try iterator.next(app_runtime.io())) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const path = try std.fs.path.join(allocator, &.{ data_dir, entry.name });
        defer allocator.free(path);
        var file = dir.openFile(app_runtime.io(), entry.name, .{}) catch continue;
        defer file.close(app_runtime.io());
        const data = registry.readFileAlloc(file, allocator, 16 * 1024 * 1024) catch continue;
        defer allocator.free(data);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch continue;
        parsed.deinit();
        if (!first) try aw.writer.writeByte(',');
        first = false;
        try aw.writer.writeAll(data);
    }
    try aw.writer.writeByte(']');
    try respondJson(request, .ok, aw.written());
}

fn serveRequest(allocator: std.mem.Allocator, request: *std.http.Server.Request, api_token: []const u8, data_dir: []const u8) !void {
    if (request.head.method == .GET and std.mem.eql(u8, request.head.target, "/health")) return respondJson(request, .ok, "{\"ok\":true}");
    if (!authorized(request, api_token)) return respondJson(request, .unauthorized, "{\"error\":\"unauthorized\"}");
    if (!std.mem.eql(u8, request.head.target, "/v1/credentials")) return respondJson(request, .not_found, "{\"error\":\"not_found\"}");
    switch (request.head.method) {
        .GET => try handleGet(allocator, request, data_dir),
        .PUT => try handlePut(allocator, request, data_dir),
        else => try respondJson(request, .method_not_allowed, "{\"error\":\"method_not_allowed\"}"),
    }
}

fn acceptConnection(allocator: std.mem.Allocator, stream: std.Io.net.Stream, api_token: []const u8, data_dir: []const u8) void {
    defer stream.close(app_runtime.io());
    var recv_buffer: [32 * 1024]u8 = undefined;
    var send_buffer: [32 * 1024]u8 = undefined;
    var conn_reader = stream.reader(app_runtime.io(), &recv_buffer);
    var conn_writer = stream.writer(app_runtime.io(), &send_buffer);
    var server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);
    while (server.reader.state == .ready) {
        var request = server.receiveHead() catch return;
        serveRequest(allocator, &request, api_token, data_dir) catch |err| {
            std.log.err("server request failed: {s}", .{@errorName(err)});
            return;
        };
    }
}

pub fn run(allocator: std.mem.Allocator, port_override: ?u16) !void {
    const api_token = (try envOwned(allocator, "API_TOKEN")) orelse return error.ApiTokenRequired;
    defer allocator.free(api_token);
    if (api_token.len < 16) return error.ApiTokenTooShort;
    const data_dir = (try envOwned(allocator, "DATA_DIR")) orelse try allocator.dupe(u8, "/data");
    defer allocator.free(data_dir);
    try std.Io.Dir.cwd().createDirPath(app_runtime.io(), data_dir);
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
        acceptConnection(allocator, stream, api_token, data_dir);
    }
}
