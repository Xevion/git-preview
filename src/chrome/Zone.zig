//! The viewer's local time zone, standing in for the browser's `Intl` zone in static timestamps.
//! Read from `TZ` or `/etc/localtime` (TZif); instants past the last transition follow the
//! file's POSIX rule footer, as libc does.

const Zone = @This();

const std = @import("std");
const civil = @import("civil.zig");

transitions: []const Transition = &.{},
/// The zone in effect before the first transition, and when there is no file at all.
initial: Local = .utc,
rule: ?Rule = null,

pub const Local = struct {
    /// Seconds east of UTC.
    offset: i32,
    abbr: Abbr,

    pub const utc: Local = .{ .offset = 0, .abbr = .init("UTC") };
};

pub const Abbr = struct {
    buf: [8]u8 = undefined,
    len: u8 = 0,

    pub fn init(s: []const u8) Abbr {
        var a: Abbr = .{};
        a.len = @intCast(@min(s.len, a.buf.len));
        @memcpy(a.buf[0..a.len], s[0..a.len]);
        return a;
    }

    pub fn slice(self: *const Abbr) []const u8 {
        return self.buf[0..self.len];
    }
};

const Transition = struct { at: i64, local: Local };

pub const utc: Zone = .{};

/// The local zone, or UTC when it cannot be determined.
pub fn load(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) Zone {
    const tz = env.get("TZ");
    if (tz) |v| if (v.len == 0) return utc;
    const name = if (tz) |v| (if (v[0] == ':') v[1..] else v) else null;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path: []const u8 = if (name) |n|
        (if (std.fs.path.isAbsolute(n)) n else std.fmt.bufPrint(&buf, "{s}/{s}", .{ env.get("TZDIR") orelse "/usr/share/zoneinfo", n }) catch return utc)
    else
        "/etc/localtime";

    if (readFile(gpa, io, path)) |z| return z else |_| {}
    // TZ may itself be a POSIX rule such as `CST6CDT,M3.2.0,M11.1.0`.
    if (name) |n| if (Rule.parse(n)) |r| return .{ .initial = r.std, .rule = r };
    return utc;
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Zone {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(data);
    return parse(gpa, data);
}

/// Parses TZif data; the result owns its transitions.
pub fn parse(gpa: std.mem.Allocator, data: []const u8) !Zone {
    var reader: std.Io.Reader = .fixed(data);
    var tz = try std.tz.Tz.parse(gpa, &reader);
    defer tz.deinit();

    const transitions = try gpa.alloc(Transition, tz.transitions.len);
    for (tz.transitions, transitions) |t, *out| out.* = .{ .at = t.ts, .local = localOf(t.timetype) };
    // RFC 8536: before the first transition the first non-DST type applies, else type 0.
    const first = for (tz.timetypes) |*tt| {
        if (!tt.isDst()) break tt;
    } else &tz.timetypes[0];
    return .{
        .transitions = transitions,
        .initial = localOf(first),
        .rule = if (tz.footer) |f| Rule.parse(f) else null,
    };
}

fn localOf(tt: *const std.tz.Timetype) Local {
    return .{ .offset = tt.offset, .abbr = .init(tt.name()) };
}

pub fn deinit(self: *Zone, gpa: std.mem.Allocator) void {
    gpa.free(self.transitions);
    self.* = utc;
}

/// The offset and abbreviation in effect at Unix time `t`.
pub fn at(self: *const Zone, t: i64) Local {
    const ts = self.transitions;
    if (ts.len == 0 or t >= ts[ts.len - 1].at) {
        if (self.rule) |r| return r.at(t);
        return if (ts.len == 0) self.initial else ts[ts.len - 1].local;
    }
    if (t < ts[0].at) return self.initial;
    // Last transition at or before t.
    var lo: usize = 0;
    var hi: usize = ts.len - 1;
    while (lo < hi) {
        const mid = lo + (hi - lo + 1) / 2;
        if (ts[mid].at <= t) lo = mid else hi = mid - 1;
    }
    return ts[lo].local;
}

/// A POSIX TZ string: `std offset [dst [offset] [,start[/time],end[/time]]]`.
pub const Rule = struct {
    std: Local,
    dst: ?Local = null,
    start: Date = undefined,
    end: Date = undefined,

    const Date = struct {
        kind: enum { month_week_day, julian_no_leap, zero_based },
        month: u8 = 0,
        week: u8 = 0,
        weekday: u8 = 0,
        day: u16 = 0,
        /// Local seconds after midnight; may be negative or past a day.
        time: i32 = 2 * 3600,
    };

    pub fn parse(s: []const u8) ?Rule {
        var p: Parser = .{ .s = s };
        const std_name = p.name() orelse return null;
        const std_off = p.offset() orelse return null;
        var r: Rule = .{ .std = .{ .offset = -std_off, .abbr = .init(std_name) } };
        if (p.done()) return r;
        const dst_name = p.name() orelse return null;
        const dst_off = if (p.peek() == ',' or p.done()) std_off - 3600 else p.offset() orelse return null;
        r.dst = .{ .offset = -dst_off, .abbr = .init(dst_name) };
        if (!p.eat(',')) return null; // Rule-less DST strings defer to the system's default rules; not worth guessing.
        r.start = p.date() orelse return null;
        if (!p.eat(',')) return null;
        r.end = p.date() orelse return null;
        return if (p.done()) r else null;
    }

    fn at(self: Rule, t: i64) Local {
        const dst = self.dst orelse return self.std;
        const year = civil.fromDays(@divFloor(t + self.std.offset, 86400)).year;
        // Start is given in standard time, end in daylight time.
        const start = transitionDay(self.start, year) * 86400 + self.start.time - self.std.offset;
        const end = transitionDay(self.end, year) * 86400 + self.end.time - dst.offset;
        const in_dst = if (start < end) t >= start and t < end else !(t >= end and t < start);
        return if (in_dst) dst else self.std;
    }

    /// Days since the epoch of the rule's date in `year`.
    fn transitionDay(d: Date, year: i32) i64 {
        const jan1 = civil.toDays(year, 1, 1);
        return switch (d.kind) {
            .zero_based => jan1 + d.day,
            .julian_no_leap => jan1 + d.day - 1 + @intFromBool(civil.isLeap(year) and d.day >= 60),
            .month_week_day => blk: {
                const first = civil.toDays(year, d.month, 1);
                const first_wd: i64 = @mod(first + 4, 7); // 1970-01-01 was a Thursday.
                var day = first + @mod(@as(i64, d.weekday) - first_wd, 7) + (@as(i64, d.week) - 1) * 7;
                const dim = civil.daysInMonth(year, d.month);
                while (day >= first + dim) day -= 7; // Week 5 means the last such weekday.
                break :blk day;
            },
        };
    }
};

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn done(p: *Parser) bool {
        return p.i >= p.s.len;
    }

    fn peek(p: *Parser) u8 {
        return if (p.done()) 0 else p.s[p.i];
    }

    fn eat(p: *Parser, ch: u8) bool {
        if (p.peek() != ch) return false;
        p.i += 1;
        return true;
    }

    fn name(p: *Parser) ?[]const u8 {
        if (p.eat('<')) {
            const start = p.i;
            while (!p.done() and p.peek() != '>') p.i += 1;
            const n = p.s[start..p.i];
            return if (p.eat('>')) n else null;
        }
        const start = p.i;
        while (!p.done() and std.ascii.isAlphabetic(p.peek())) p.i += 1;
        return if (p.i - start >= 3) p.s[start..p.i] else null;
    }

    fn number(p: *Parser) ?u32 {
        const start = p.i;
        var n: u32 = 0;
        while (!p.done() and std.ascii.isDigit(p.peek())) : (p.i += 1) n = n *| 10 +| (p.peek() - '0');
        return if (p.i > start) n else null;
    }

    /// `[+-]hh[:mm[:ss]]` in seconds.
    fn offset(p: *Parser) ?i32 {
        const neg = p.eat('-');
        if (!neg) _ = p.eat('+');
        const hours: i32 = @intCast(@min(p.number() orelse return null, 167));
        var secs = hours * 3600;
        if (p.eat(':')) secs += @as(i32, @intCast(@min(p.number() orelse return null, 59))) * 60;
        if (p.eat(':')) secs += @intCast(@min(p.number() orelse return null, 59));
        return if (neg) -secs else secs;
    }

    fn date(p: *Parser) ?Rule.Date {
        var d: Rule.Date = undefined;
        if (p.eat('M')) {
            const m = p.number() orelse return null;
            if (!p.eat('.')) return null;
            const w = p.number() orelse return null;
            if (!p.eat('.')) return null;
            const wd = p.number() orelse return null;
            if (m < 1 or m > 12 or w < 1 or w > 5 or wd > 6) return null;
            d = .{ .kind = .month_week_day, .month = @intCast(m), .week = @intCast(w), .weekday = @intCast(wd) };
        } else if (p.eat('J')) {
            const n = p.number() orelse return null;
            if (n < 1 or n > 365) return null;
            d = .{ .kind = .julian_no_leap, .day = @intCast(n) };
        } else {
            const n = p.number() orelse return null;
            if (n > 365) return null;
            d = .{ .kind = .zero_based, .day = @intCast(n) };
        }
        if (p.eat('/')) d.time = p.offset() orelse return null;
        return d;
    }
};

test "POSIX rules pick standard or daylight time" {
    const r = Rule.parse("CST6CDT,M3.2.0,M11.1.0").?;
    const z: Zone = .{ .initial = r.std, .rule = r };
    // 2026-11-15T07:27:02Z is after the first Sunday of November.
    try std.testing.expectEqualStrings("CST", z.at(1794727622).abbr.slice());
    try std.testing.expectEqual(-6 * 3600, z.at(1794727622).offset);
    // 2026-07-01T12:00:00Z
    try std.testing.expectEqualStrings("CDT", z.at(1782907200).abbr.slice());
    // DST starts 2026-03-08 at 02:00 CST = 08:00Z.
    try std.testing.expectEqualStrings("CST", z.at(1772956800 - 1).abbr.slice());
    try std.testing.expectEqualStrings("CDT", z.at(1772956800).abbr.slice());

    const south = Rule.parse("<+1030>-10:30<+11>-11,M10.1.0,M4.1.0").?;
    const lhi: Zone = .{ .initial = south.std, .rule = south };
    try std.testing.expectEqual(11 * 3600, lhi.at(1767225600).offset); // January: summer
    try std.testing.expectEqual(10 * 3600 + 1800, lhi.at(1782907200).offset); // July: winter
    try std.testing.expect(Rule.parse("EST5EDT") == null);
}
