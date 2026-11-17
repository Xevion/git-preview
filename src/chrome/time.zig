//! Static stand-ins for GitHub's `<relative-time>` element (github/relative-time-element), which a
//! script-free page cannot run: its English output for `tense="past"`, computed in the viewer's zone.

const std = @import("std");
const civil = @import("civil.zig");
const Zone = @import("Zone.zig");

const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// `2026-11-15T07:27:02.000Z`, the element's `datetime` attribute.
pub fn iso(buf: []u8, t: i64) []const u8 {
    const d = civil.fromDays(@divFloor(t, 86400));
    const s: u32 = @intCast(@mod(t, 86400));
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{
        @as(u32, @intCast(d.year)), d.month, d.day, s / 3600, s / 60 % 60, s % 60,
    }) catch unreachable;
}

/// `Nov 15, 2026, 1:27 AM CST`, the hover title (`Intl.DateTimeFormat` en-US, short zone name).
pub fn title(buf: []u8, t: i64, zone: *const Zone) []const u8 {
    const local = zone.at(t);
    const lt = t + local.offset;
    const d = civil.fromDays(@divFloor(lt, 86400));
    const s: u32 = @intCast(@mod(lt, 86400));
    const hour = s / 3600;
    const h12 = if (hour % 12 == 0) 12 else hour % 12;
    var zbuf: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s} {d}, {d}, {d}:{d:0>2} {s} {s}", .{
        month_names[d.month - 1], d.day, d.year, h12, s / 60 % 60, if (hour < 12) "AM" else "PM", zoneName(&zbuf, local),
    }) catch unreachable;
}

/// Intl prints known abbreviations; numeric ones (`+0530` in TZif) become `GMT+5:30`.
fn zoneName(buf: []u8, local: Zone.Local) []const u8 {
    const abbr = local.abbr.slice();
    if (abbr.len > 0 and std.ascii.isAlphabetic(abbr[0])) return abbr;
    if (local.offset == 0) return "GMT";
    const a: u32 = @abs(local.offset);
    const sign: u8 = if (local.offset < 0) '-' else '+';
    if (a % 3600 == 0) return std.fmt.bufPrint(buf, "GMT{c}{d}", .{ sign, a / 3600 }) catch unreachable;
    return std.fmt.bufPrint(buf, "GMT{c}{d}:{d:0>2}", .{ sign, a / 3600, a / 60 % 60 }) catch unreachable;
}

const Duration = struct {
    years: i64 = 0,
    months: i64 = 0,
    weeks: i64 = 0,
    days: i64 = 0,
    hours: i64 = 0,
    minutes: i64 = 0,
    seconds: i64 = 0,
};

/// `Math.round(a / b)` for non-negative operands.
fn roundDiv(a: i64, b: i64) i64 {
    return @divFloor(2 * a + b, 2 * b);
}

/// The element's `elapsedTime` at second precision, as magnitudes.
fn elapsed(secs: i64) Duration {
    const min = @divFloor(secs, 60);
    const hr = @divFloor(min, 60);
    const day = @divFloor(hr, 24);
    const month = @divFloor(day, 30);
    const year = @divFloor(month, 12);
    return .{
        .years = year,
        .months = month - year * 12,
        .days = day - month * 30,
        .hours = hr - day * 24,
        .minutes = min - hr * 60,
        .seconds = secs - min * 60,
    };
}

/// The element's `roundToSingleUnit` for a past duration, with calendar steps on the local date `today`.
fn roundToSingleUnit(d0: Duration, today: civil.Date) Duration {
    var d = d0;
    if (d.seconds >= 55) d.minutes += roundDiv(d.seconds, 60);
    if (d.minutes != 0 or d.hours != 0 or d.days != 0 or d.weeks != 0 or d.months != 0 or d.years != 0) d.seconds = 0;
    if (d.minutes >= 55) d.hours += roundDiv(d.minutes, 60);
    if (d.hours != 0 or d.days != 0 or d.weeks != 0 or d.months != 0 or d.years != 0) d.minutes = 0;
    if (d.days != 0 and d.hours >= 12) d.days += roundDiv(d.hours, 24);
    if (d.days == 0 and d.hours >= 21) d.days += roundDiv(d.hours, 24);
    if (d.days != 0 or d.weeks != 0 or d.months != 0 or d.years != 0) d.hours = 0;

    if (d.days >= 27 or d.years + d.months + d.days != 0) {
        const y: i64 = today.year;
        const m0: i64 = today.month - 1;
        const day: i64 = today.day;
        // Steps mirror the element's Date setter sequence, each normalizing overflow.
        const month_end = civil.normalize(y, m0 - d.months + 1, 0);
        const correction = @max(0, day - month_end.day);
        var nd = civil.normalize(y - d.years, m0, day);
        nd = civil.normalize(nd.year, nd.month - 1, day - correction);
        nd = civil.normalize(nd.year, m0 - d.months, nd.day);
        nd = civil.normalize(nd.year, nd.month - 1, day - correction - d.days);

        const year_diff = @as(i64, nd.year) - y;
        const month_diff = @as(i64, nd.month - 1) - m0;
        const days_diff = @as(i64, @intCast(@abs(civil.toDays(nd.year, nd.month, nd.day) - civil.toDays(today.year, today.month, today.day)))) + correction;
        const months_diff: i64 = @intCast(@abs(year_diff * 12 + month_diff));
        if (days_diff < 27) {
            if (d.days >= 6) {
                d.weeks += roundDiv(d.days, 7);
                d.days = 0;
            } else d.days = days_diff;
            d.months = 0;
            d.years = 0;
        } else if (months_diff <= 11) {
            d.months = months_diff;
            d.years = 0;
        } else {
            d.months = 0;
            d.years = -year_diff;
        }
        if (d.months != 0 or d.years != 0) d.days = 0;
    }
    if (d.years != 0) d.months = 0;
    if (d.weeks >= 4) d.months += roundDiv(d.weeks, 4);
    if (d.months != 0 or d.years != 0) d.weeks = 0;
    if (d.days != 0 and d.weeks != 0 and d.months == 0 and d.years == 0) {
        d.weeks += roundDiv(d.days, 7);
        d.days = 0;
    }
    return d;
}

/// The element's text: "now", "5 minutes ago", "yesterday", "2 days ago", "last week", "3 months ago".
pub fn relative(buf: []u8, t: i64, now: i64, zone: *const Zone) []const u8 {
    if (t >= now) return "now"; // Past tense clamps future dates to an empty duration.
    const today = civil.fromDays(@divFloor(now + zone.at(now).offset, 86400));
    const d = roundToSingleUnit(elapsed(now - t), today);
    const units = [_]struct { n: i64, name: []const u8, last: ?[]const u8 }{
        .{ .n = d.years, .name = "year", .last = "last year" },
        .{ .n = d.months, .name = "month", .last = "last month" },
        .{ .n = d.weeks, .name = "week", .last = "last week" },
        .{ .n = d.days, .name = "day", .last = "yesterday" },
        .{ .n = d.hours, .name = "hour", .last = null },
        .{ .n = d.minutes, .name = "minute", .last = null },
    };
    for (units) |u| {
        if (u.n == 0) continue;
        if (u.n == 1) return u.last orelse std.fmt.bufPrint(buf, "1 {s} ago", .{u.name}) catch unreachable;
        return std.fmt.bufPrint(buf, "{d} {s}s ago", .{ u.n, u.name }) catch unreachable;
    }
    // The element compares the signed count with 10, so every past seconds value reads "now".
    return "now";
}

test "formats titles in the viewer's zone" {
    var buf: [64]u8 = undefined;
    const t: i64 = 1794727622; // 2026-11-15T07:27:02Z
    try std.testing.expectEqualStrings("2026-11-15T07:27:02.000Z", iso(&buf, t));
    try std.testing.expectEqualStrings("Nov 15, 2026, 7:27 AM UTC", title(&buf, t, &Zone.utc));
    const cst: Zone = .{ .initial = .{ .offset = -6 * 3600, .abbr = .init("CST") } };
    try std.testing.expectEqualStrings("Nov 15, 2026, 1:27 AM CST", title(&buf, t, &cst));
    const ist: Zone = .{ .initial = .{ .offset = 5 * 3600 + 1800, .abbr = .init("+0530") } };
    try std.testing.expectEqualStrings("Nov 15, 2026, 12:57 PM GMT+5:30", title(&buf, t, &ist));
}

test "matches relative-time-element on its own output" {
    // Generated by `just relative-time-golden` from the element's code under TZ=America/Chicago.
    const gpa = std.testing.allocator;
    const table = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/time/relative-chicago.txt", gpa, .limited(1 << 20));
    defer gpa.free(table);
    const rule = Zone.Rule.parse("CST6CDT,M3.2.0,M11.1.0").?;
    const chicago: Zone = .{ .initial = rule.std, .rule = rule };
    var buf: [64]u8 = undefined;
    var lines = std.mem.tokenizeScalar(u8, table, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ' ');
        const t = try std.fmt.parseInt(i64, fields.next().?, 10);
        const now = try std.fmt.parseInt(i64, fields.next().?, 10);
        const want = fields.rest();
        const got = relative(&buf, t, now, &chicago);
        if (!std.mem.eql(u8, want, got)) {
            std.debug.print("{d} -> {d}: want {s}, got {s}\n", .{ t, now, want, got });
            return error.TestExpectedEqual;
        }
    }
}
