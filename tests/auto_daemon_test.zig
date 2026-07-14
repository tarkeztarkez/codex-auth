const std = @import("std");
const codex_auth = @import("codex_auth");
const auto = codex_auth.auto;
const registry = codex_auth.registry;
const workflows = codex_auth.workflows;

fn addAccount(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    key: []const u8,
    used_five_hour: f64,
    used_weekly: f64,
) !void {
    try reg.accounts.append(allocator, .{
        .account_key = try allocator.dupe(u8, key),
        .chatgpt_account_id = try allocator.dupe(u8, key),
        .chatgpt_user_id = try allocator.dupe(u8, "user"),
        .email = try std.fmt.allocPrint(allocator, "{s}@example.com", .{key}),
        .alias = try allocator.dupe(u8, key),
        .account_name = null,
        .plan = .plus,
        .auth_mode = .chatgpt,
        .created_at = 1,
        .last_used_at = null,
        .last_usage = .{
            .primary = .{ .used_percent = used_five_hour, .window_minutes = 300, .resets_at = null },
            .secondary = .{ .used_percent = used_weekly, .window_minutes = 10080, .resets_at = null },
            .credits = null,
            .plan_type = .plus,
        },
        .last_usage_at = 1,
        .last_local_rollout = null,
    });
}

test "active account switches at the default two percent threshold" {
    const allocator = std.testing.allocator;
    var reg = registry.Registry{
        .schema_version = registry.current_schema_version,
        .active_account_key = try allocator.dupe(u8, "active"),
        .active_account_activated_at_ms = 0,
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer reg.deinit(allocator);
    try addAccount(allocator, &reg, "active", 98.0, 50.0);

    try std.testing.expect(auto.accountIsAtOrBelowThreshold(&reg.accounts.items[0], .{}, 100));
    reg.accounts.items[0].last_usage.?.primary.?.used_percent = 97.99;
    try std.testing.expect(!auto.accountIsAtOrBelowThreshold(&reg.accounts.items[0], .{}, 100));
}

test "best refreshed account above both thresholds is selected" {
    const allocator = std.testing.allocator;
    var reg = registry.Registry{
        .schema_version = registry.current_schema_version,
        .active_account_key = try allocator.dupe(u8, "active"),
        .active_account_activated_at_ms = 0,
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer reg.deinit(allocator);
    try addAccount(allocator, &reg, "active", 99.0, 40.0);
    try addAccount(allocator, &reg, "low", 99.0, 20.0);
    try addAccount(allocator, &reg, "best", 20.0, 30.0);
    const outcomes = [_]workflows.ForegroundUsageOutcome{
        .{ .attempted = true, .has_usage_windows = true },
        .{ .attempted = true, .has_usage_windows = true },
        .{ .attempted = true, .has_usage_windows = true },
    };

    try std.testing.expectEqual(@as(?usize, 2), auto.selectCandidateIndex(&reg, &outcomes, .{}, 100));
}

test "unrefreshed candidates are never selected" {
    const allocator = std.testing.allocator;
    var reg = registry.Registry{
        .schema_version = registry.current_schema_version,
        .active_account_key = try allocator.dupe(u8, "active"),
        .active_account_activated_at_ms = 0,
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer reg.deinit(allocator);
    try addAccount(allocator, &reg, "active", 99.0, 40.0);
    try addAccount(allocator, &reg, "candidate", 20.0, 20.0);
    const outcomes = [_]workflows.ForegroundUsageOutcome{
        .{ .attempted = true, .has_usage_windows = true },
        .{ .attempted = true, .has_usage_windows = false },
    };

    try std.testing.expectEqual(@as(?usize, null), auto.selectCandidateIndex(&reg, &outcomes, .{}, 100));
}

test "only 401 token_expired outcomes request Codex reauthentication" {
    const body =
        \\{"error":{"code":"token_expired","message":"expired"}}
    ;
    const code = codex_auth.api.usage.parseNonSuccessErrorCode(std.testing.allocator, 401, body) orelse
        return error.TestExpectedEqual;
    try std.testing.expect(auto.isTokenExpired(.{ .attempted = true, .status_code = 401, .error_code = code }));
    try std.testing.expect(!auto.isTokenExpired(.{ .attempted = true, .status_code = 403, .error_code = code }));
    try std.testing.expect(!auto.isTokenExpired(.{ .attempted = true, .status_code = 401 }));
}
