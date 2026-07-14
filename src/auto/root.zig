const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const registry = @import("../registry/root.zig");
const usage_refresh = @import("../workflows/usage.zig");
const types = @import("../cli/types.zig");

pub const CycleResult = enum {
    no_accounts,
    no_active_account,
    refresh_failed,
    above_threshold,
    no_candidate,
    switched,
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
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (reg.accounts.items.len == 0) return .no_accounts;

    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }
    const active_key = reg.active_account_key orelse return .no_active_account;
    const active_idx = registry.findAccountIndexByAccountKey(&reg, active_key) orelse return .no_active_account;

    var refresh = try usage_refresh.refreshForegroundUsageForDisplay(allocator, codex_home, &reg);
    defer refresh.deinit(allocator);
    if (active_idx >= refresh.outcomes.len or !refresh.outcomes[active_idx].has_usage_windows) return .refresh_failed;

    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    if (!accountIsAtOrBelowThreshold(&reg.accounts.items[active_idx], thresholds, now)) return .above_threshold;

    const candidate_idx = selectCandidateIndex(&reg, refresh.outcomes, thresholds, now) orelse return .no_candidate;
    const candidate_key = try allocator.dupe(u8, reg.accounts.items[candidate_idx].account_key);
    defer allocator.free(candidate_key);
    try registry.activateAccountByKey(allocator, codex_home, &reg, candidate_key);
    try registry.saveRegistry(allocator, codex_home, &reg);
    return .switched;
}

pub fn runDaemon(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    opts: types.DaemonOptions,
) !void {
    if (!opts.watch) {
        const result = try runCycle(allocator, codex_home, opts.thresholds);
        std.log.info("auto-switch cycle: {s}", .{@tagName(result)});
        return;
    }

    std.log.info(
        "auto-switch watcher started (5h <= {d}%, weekly <= {d}%, interval {d}s)",
        .{ opts.thresholds.five_hour_percent, opts.thresholds.weekly_percent, opts.thresholds.interval_seconds },
    );
    while (true) {
        const result = runCycle(allocator, codex_home, opts.thresholds) catch |err| {
            std.log.err("auto-switch cycle failed: {s}", .{@errorName(err)});
            std.Io.sleep(app_runtime.io(), .fromSeconds(opts.thresholds.interval_seconds), .awake) catch {};
            continue;
        };
        if (result == .switched) {
            std.log.info("auto-switch completed", .{});
        } else if (result == .refresh_failed) {
            std.log.warn("auto-switch skipped because active-account usage refresh failed", .{});
        }
        std.Io.sleep(app_runtime.io(), .fromSeconds(opts.thresholds.interval_seconds), .awake) catch {};
    }
}
