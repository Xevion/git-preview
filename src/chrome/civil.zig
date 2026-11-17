//! Proleptic Gregorian dates as days since 1970-01-01, after Howard Hinnant's `chrono` algorithms.

const std = @import("std");

pub const Date = struct {
    year: i32,
    /// 1-12.
    month: u8,
    /// 1-31.
    day: u8,
};

pub fn isLeap(year: i32) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

pub fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        2 => if (isLeap(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

pub fn toDays(year: i32, month: u8, day: u8) i64 {
    const y: i64 = @as(i64, year) - @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = @mod(@as(i64, month) + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn fromDays(days: i64) Date {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const month: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .year = @intCast(yoe + era * 400 + @intFromBool(month <= 2)), .month = month, .day = day };
}

/// `new Date(year, month0, day)` semantics: a zero-based month and day overflowing in either direction.
pub fn normalize(year: i64, month0: i64, day: i64) Date {
    const y = year + @divFloor(month0, 12);
    const m: u8 = @intCast(@mod(month0, 12) + 1);
    return fromDays(toDays(@intCast(y), m, 1) + day - 1);
}

test "round-trips and normalizes like JavaScript dates" {
    try std.testing.expectEqual(@as(i64, 0), toDays(1970, 1, 1));
    try std.testing.expectEqual(Date{ .year = 2026, .month = 11, .day = 15 }, fromDays(20772));
    try std.testing.expectEqual(@as(i64, 20772), toDays(2026, 11, 15));
    // Feb 30 rolls into March; day 0 is the previous month's last day.
    try std.testing.expectEqual(Date{ .year = 2025, .month = 3, .day = 2 }, normalize(2025, 1, 30));
    try std.testing.expectEqual(Date{ .year = 2024, .month = 2, .day = 29 }, normalize(2024, 2, 0));
    try std.testing.expectEqual(Date{ .year = 2025, .month = 12, .day = 1 }, normalize(2026, -1, 1));
}
