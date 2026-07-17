const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const usage_api = @import("../api/usage.zig");
const auth = @import("../auth/auth.zig");
const registry = @import("../registry/root.zig");
const usage_refresh = @import("../workflows/usage.zig");
const sync_client = @import("../sync/client.zig");
const token_refresh = @import("../server_usage.zig");

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
    var source_file = try std.Io.Dir.cwd().openFile(app_runtime.io(), source_auth, .{});
    defer source_file.close(app_runtime.io());
    const source_data = try registry.readFileAlloc(source_file, allocator, 16 * 1024 * 1024);
    defer allocator.free(source_data);
    const refreshed_data = try token_refresh.refreshAuthAlloc(allocator, source_data);
    defer allocator.free(refreshed_data);
    try registry.writeFile(temp_auth, refreshed_data);

    var refreshed_info = try auth.parseAuthInfo(allocator, temp_auth);
    defer refreshed_info.deinit(allocator);
    const refreshed_key = refreshed_info.record_key orelse return error.ReauthenticatedAccountIdentityMissing;
    if (!std.mem.eql(u8, refreshed_key, account_key)) return error.ReauthenticatedAccountIdentityMismatch;

    // OAuth refresh tokens rotate. Persist the identity-checked document before
    // validation so a transient usage failure cannot discard the new token.
    try registry.copyManagedFile(temp_auth, source_auth);
    if (reg.active_account_key) |active_key| {
        if (std.mem.eql(u8, active_key, account_key)) {
            try registry.replaceActiveAuthWithAccountByKey(allocator, codex_home, reg, account_key);
        }
    }

    var usage = try usage_api.fetchUsageForAuthPathDetailed(allocator, temp_auth);
    defer if (usage.snapshot) |*snapshot| registry.freeRateLimitSnapshot(allocator, snapshot);
    if (usage.status_code == null or usage.status_code.? < 200 or usage.status_code.? > 299 or usage.snapshot == null) {
        return error.ReauthenticatedTokenValidationFailed;
    }

    _ = sync_client.pushAccount(allocator, codex_home, account_key) catch |err|
        std.log.warn("refreshed credential upload failed: {s}", .{@errorName(err)});
}
