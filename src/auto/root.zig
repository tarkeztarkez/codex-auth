const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const registry = @import("../registry/root.zig");
const usage_refresh = @import("../workflows/usage.zig");
const types = @import("../cli/types.zig");
const reauth = @import("reauth.zig");
const sync_client = @import("../sync/client.zig");

pub const isTokenExpired = reauth.isTokenExpired;
const reauth_retry_cooldown_seconds: i64 = 15 * 60;

pub const CycleResult = enum {
    no_accounts,
    no_active_account,
    refresh_failed,
    above_threshold,
    no_candidate,
    switched,
};

const CycleOutcome = struct {
    result: CycleResult,
    reauth_attempted: bool = false,
};

fn remainingPercent(window: ?registry.RateLimitWindow, now: i64) ?f64 {
    const value = window orelse return null;
    if (value.resets_at) |resets_at| {
        if (resets_at <= now) return 100.0;
    }
    return std.math.clamp(100.0 - value.used_percent, 0.0, 100.0);
}

pub fn accountIsAtOrBelowThreshold(
    rec: *const registry.AccountRecord,
    thresholds: types.AutoThresholds,
    now: i64,
) bool {
    const five_hour = remainingPercent(registry.resolveRateWindow(rec.last_usage, 300, true), now);
    const weekly = remainingPercent(registry.resolveRateWindow(rec.last_usage, 10080, false), now);
    return (five_hour != null and five_hour.? <= @as(f64, @floatFromInt(thresholds.five_hour_percent))) or
        (weekly != null and weekly.? <= @as(f64, @floatFromInt(thresholds.weekly_percent)));
}

fn candidateScore(
    rec: *const registry.AccountRecord,
    thresholds: types.AutoThresholds,
    now: i64,
) ?f64 {
    const five_hour = remainingPercent(registry.resolveRateWindow(rec.last_usage, 300, true), now);
    const weekly = remainingPercent(registry.resolveRateWindow(rec.last_usage, 10080, false), now);
    if (five_hour == null and weekly == null) return null;
    if (five_hour) |remaining| {
        if (remaining <= @as(f64, @floatFromInt(thresholds.five_hour_percent))) return null;
    }
    if (weekly) |remaining| {
        if (remaining <= @as(f64, @floatFromInt(thresholds.weekly_percent))) return null;
    }
    if (five_hour != null and weekly != null) return @min(five_hour.?, weekly.?);
    return five_hour orelse weekly.?;
}

pub fn selectCandidateIndex(
    reg: *const registry.Registry,
    refreshed: []const usage_refresh.ForegroundUsageOutcome,
    thresholds: types.AutoThresholds,
    now: i64,
) ?usize {
    const active_key = reg.active_account_key orelse return null;
    var best_idx: ?usize = null;
    var best_score: f64 = -1.0;
    var best_seen: i64 = -1;
    for (reg.accounts.items, 0..) |*rec, idx| {
        if (std.mem.eql(u8, rec.account_key, active_key)) continue;
        if (idx >= refreshed.len or !refreshed[idx].has_usage_windows) continue;
        const score = candidateScore(rec, thresholds, now) orelse continue;
        const seen = rec.last_usage_at orelse -1;
        if (score > best_score or (score == best_score and seen > best_seen)) {
            best_idx = idx;
            best_score = score;
            best_seen = seen;
        }
    }
    return best_idx;
}

pub fn runCycle(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    thresholds: types.AutoThresholds,
) !CycleResult {
    return (try runCycleWithReauth(allocator, codex_home, thresholds, true)).result;
}

fn runCycleWithReauth(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    thresholds: types.AutoThresholds,
    allow_reauth: bool,
) !CycleOutcome {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    _ = sync_client.syncAll(allocator, codex_home, &reg) catch |err|
        std.log.warn("credential server sync failed: {s}", .{@errorName(err)});
    if (reg.accounts.items.len == 0) return .{ .result = .no_accounts };

    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
        _ = sync_client.pushAll(allocator, codex_home, &reg) catch |err|
            std.log.warn("credential upload failed: {s}", .{@errorName(err)});
    }
    const active_key = reg.active_account_key orelse return .{ .result = .no_active_account };
    const active_idx = registry.findAccountIndexByAccountKey(&reg, active_key) orelse return .{ .result = .no_active_account };

    var refresh = try usage_refresh.refreshForegroundUsageForDisplay(allocator, codex_home, &reg);
    defer refresh.deinit(allocator);
    var reauth_attempted = false;
    if (allow_reauth) {
        for (refresh.outcomes) |outcome| {
            if (reauth.isTokenExpired(outcome)) {
                reauth_attempted = true;
                break;
            }
        }
        if (reauth_attempted) {
            const repaired = try reauth.repairExpiredAccounts(allocator, codex_home, &reg, refresh.outcomes);
            if (repaired > 0) {
                refresh.deinit(allocator);
                refresh = try usage_refresh.refreshForegroundUsageForDisplay(allocator, codex_home, &reg);
            }
        }
    }
    if (active_idx >= refresh.outcomes.len or !refresh.outcomes[active_idx].has_usage_windows) {
        return .{ .result = .refresh_failed, .reauth_attempted = reauth_attempted };
    }

    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    if (!accountIsAtOrBelowThreshold(&reg.accounts.items[active_idx], thresholds, now)) return .{ .result = .above_threshold, .reauth_attempted = reauth_attempted };

    const candidate_idx = selectCandidateIndex(&reg, refresh.outcomes, thresholds, now) orelse return .{ .result = .no_candidate, .reauth_attempted = reauth_attempted };
    const candidate_key = try allocator.dupe(u8, reg.accounts.items[candidate_idx].account_key);
    defer allocator.free(candidate_key);
    try registry.activateAccountByKey(allocator, codex_home, &reg, candidate_key);
    try registry.saveRegistry(allocator, codex_home, &reg);
    return .{ .result = .switched, .reauth_attempted = reauth_attempted };
}

pub fn runDaemon(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    opts: types.DaemonOptions,
) !void {
    if (!opts.watch) {
        const outcome = try runCycleWithReauth(allocator, codex_home, opts.thresholds, true);
        std.log.info("auto-switch cycle: {s}", .{@tagName(outcome.result)});
        return;
    }

    std.log.info(
        "auto-switch watcher started (5h <= {d}%, weekly <= {d}%, interval {d}s)",
        .{ opts.thresholds.five_hour_percent, opts.thresholds.weekly_percent, opts.thresholds.interval_seconds },
    );
    var next_reauth_at: i64 = 0;
    while (true) {
        const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
        const outcome = runCycleWithReauth(allocator, codex_home, opts.thresholds, now >= next_reauth_at) catch |err| {
            std.log.err("auto-switch cycle failed: {s}", .{@errorName(err)});
            std.Io.sleep(app_runtime.io(), .fromSeconds(opts.thresholds.interval_seconds), .awake) catch {};
            continue;
        };
        if (outcome.reauth_attempted) next_reauth_at = now + reauth_retry_cooldown_seconds;
        if (outcome.result == .switched) {
            std.log.info("auto-switch completed", .{});
        } else if (outcome.result == .refresh_failed) {
            std.log.warn("auto-switch skipped because active-account usage refresh failed", .{});
        }
        std.Io.sleep(app_runtime.io(), .fromSeconds(opts.thresholds.interval_seconds), .awake) catch {};
    }
}
