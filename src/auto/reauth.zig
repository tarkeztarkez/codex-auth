const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const http_child = @import("../api/http_child.zig");
const usage_api = @import("../api/usage.zig");
const auth = @import("../auth/auth.zig");
const registry = @import("../registry/root.zig");
const usage_refresh = @import("../workflows/usage.zig");
const sync_client = @import("../sync/client.zig");

const reauth_timeout_ms: u64 = 60_000;

pub fn isTokenExpired(outcome: usage_refresh.ForegroundUsageOutcome) bool {
    if (outcome.status_code != 401) return false;
    const code = outcome.error_code orelse return false;
    return std.mem.eql(u8, code.text(), "token_expired");
}

pub fn repairExpiredAccounts(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    outcomes: []const usage_refresh.ForegroundUsageOutcome,
) !usize {
    var repaired: usize = 0;
    for (reg.accounts.items, 0..) |*rec, idx| {
        if (idx >= outcomes.len or !isTokenExpired(outcomes[idx])) continue;
        repairAccount(allocator, codex_home, reg, rec.account_key) catch |err| {
            std.log.err("token refresh failed for account {d}: {s}", .{ idx + 1, @errorName(err) });
            continue;
        };
        repaired += 1;
        std.log.info("refreshed expired token for account {d}", .{idx + 1});
    }
    return repaired;
}

fn repairAccount(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    account_key: []const u8,
) !void {
    const accounts_dir = try std.fs.path.join(allocator, &.{ codex_home, "accounts" });
    defer allocator.free(accounts_dir);
    const temp_home = try std.fmt.allocPrint(
        allocator,
        "{s}/.reauth-{d}-{d}",
        .{ accounts_dir, std.c.getpid(), @as(i128, std.Io.Timestamp.now(app_runtime.io(), .real).toNanoseconds()) },
    );
    defer allocator.free(temp_home);
    try registry.ensurePrivateDir(temp_home);
    defer std.Io.Dir.cwd().deleteTree(app_runtime.io(), temp_home) catch {};

    const source_auth = try registry.accountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(source_auth);
    const temp_auth = try std.fs.path.join(allocator, &.{ temp_home, "auth.json" });
    defer allocator.free(temp_auth);
    try registry.copyManagedFile(source_auth, temp_auth);

    var env_map = try app_runtime.currentEnviron().createMap(allocator);
    defer env_map.deinit();
    try env_map.put("CODEX_HOME", temp_home);
    var result = try http_child.runChildCapture(
        allocator,
        &.{ "codex", "doctor", "--json" },
        reauth_timeout_ms,
        &env_map,
    );
    defer result.deinit(allocator);
    if (result.timed_out) return error.CodexReauthenticationTimedOut;
    switch (result.term) {
        .exited => |code| if (code != 0) return error.CodexReauthenticationFailed,
        else => return error.CodexReauthenticationFailed,
    }

    var refreshed_info = try auth.parseAuthInfo(allocator, temp_auth);
    defer refreshed_info.deinit(allocator);
    const refreshed_key = refreshed_info.record_key orelse return error.ReauthenticatedAccountIdentityMissing;
    if (!std.mem.eql(u8, refreshed_key, account_key)) return error.ReauthenticatedAccountIdentityMismatch;

    var usage = try usage_api.fetchUsageForAuthPathDetailed(allocator, temp_auth);
    defer if (usage.snapshot) |*snapshot| registry.freeRateLimitSnapshot(allocator, snapshot);
    if (usage.status_code == null or usage.status_code.? < 200 or usage.status_code.? > 299 or usage.snapshot == null) {
        return error.ReauthenticatedTokenValidationFailed;
    }

    try registry.copyManagedFile(temp_auth, source_auth);
    if (reg.active_account_key) |active_key| {
        if (std.mem.eql(u8, active_key, account_key)) {
            try registry.replaceActiveAuthWithAccountByKey(allocator, codex_home, reg, account_key);
        }
    }
    _ = sync_client.pushAccount(allocator, codex_home, account_key) catch |err|
        std.log.warn("refreshed credential upload failed: {s}", .{@errorName(err)});
}
