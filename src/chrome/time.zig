//! Static stand-ins for GitHub's `<relative-time>` element, which a script-free page cannot run.

const std = @import("std");
const epoch = std.time.epoch;

const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

const Parts = struct { year: u16, month: u4, day: u5, hour: u5, minute: u6, second: u6 };

fn parts(t: i64) Parts {
    const es: epoch.EpochSeconds = .{ .secs = @intCast(@max(t, 0)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return .{
        .year = yd.year,
        .month = md.month.numeric(),
        .day = @as(u5, md.day_index) + 1,
        .hour = ds.getHoursIntoDay(),
        .minute = ds.getMinutesIntoHour(),
        .second = ds.getSecondsIntoMinute(),
    };
}

/// `2026-11-15T07:27:02.000Z`, the element's `datetime` attribute.
pub fn iso(buf: []u8, t: i64) []const u8 {
    const p = parts(t);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{ p.year, p.month, p.day, p.hour, p.minute, p.second }) catch unreachable;
}

/// `Nov 15, 2026, 7:27 AM UTC`, the hover title.
pub fn title(buf: []u8, t: i64) []const u8 {
    const p = parts(t);
    const h12: u5 = if (p.hour % 12 == 0) 12 else p.hour % 12;
    return std.fmt.bufPrint(buf, "{s} {d}, {d}, {d}:{d:0>2} {s} UTC", .{
        month_names[p.month - 1], p.day, p.year, h12, p.minute, if (p.hour < 12) "AM" else "PM",
    }) catch unreachable;
}

/// GitHub's past-tense phrasing: "now", "5 minutes ago", "yesterday", "last week", "3 months ago".
pub fn relative(buf: []u8, t: i64, now: i64) []const u8 {
    const s = @max(now - t, 0);
    const minute = 60;
    const hour = 60 * minute;
    const day = 24 * hour;
    const units = [_]struct { secs: i64, name: []const u8, last: ?[]const u8 }{
        .{ .secs = 365 * day, .name = "year", .last = "last year" },
        .{ .secs = 30 * day, .name = "month", .last = "last month" },
        .{ .secs = 7 * day, .name = "week", .last = "last week" },
        .{ .secs = day, .name = "day", .last = "yesterday" },
        .{ .secs = hour, .name = "hour", .last = null },
        .{ .secs = minute, .name = "minute", .last = null },
    };
    for (units) |u| {
        const n = @divFloor(s, u.secs);
        if (n < 1) continue;
        if (n == 1) return if (u.last) |l| l else std.fmt.bufPrint(buf, "1 {s} ago", .{u.name}) catch unreachable;
        return std.fmt.bufPrint(buf, "{d} {s}s ago", .{ n, u.name }) catch unreachable;
    }
    return "now";
}

test "formats like GitHub's relative-time" {
    var buf: [64]u8 = undefined;
    const t: i64 = 1794727622;
    try std.testing.expectEqualStrings("2026-11-15T07:27:02.000Z", iso(&buf, t));
    try std.testing.expectEqualStrings("Nov 15, 2026, 7:27 AM UTC", title(&buf, t));
    try std.testing.expectEqualStrings("now", relative(&buf, t, t + 30));
    try std.testing.expectEqualStrings("5 minutes ago", relative(&buf, t, t + 5 * 60));
    try std.testing.expectEqualStrings("yesterday", relative(&buf, t, t + 30 * 3600));
    try std.testing.expectEqualStrings("2 days ago", relative(&buf, t, t + 2 * 86400));
    try std.testing.expectEqualStrings("last week", relative(&buf, t, t + 8 * 86400));
    try std.testing.expectEqualStrings("3 months ago", relative(&buf, t, t + 95 * 86400));
}
