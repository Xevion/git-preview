//! Writers for the markup GitHub's React components render, shared by the chrome fillers.

const std = @import("std");
const time = @import("time.zig");
const Zone = @import("Zone.zig");

pub const Writer = std.Io.Writer;

/// Text or attribute content.
pub fn escaped(w: *Writer, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(ch),
    };
}

/// A site-relative path from GitHub's JSON, made absolute since the page is opened from disk.
pub fn href(w: *Writer, path: []const u8) !void {
    if (std.mem.startsWith(u8, path, "/") and !std.mem.startsWith(u8, path, "//")) try w.writeAll("https://github.com");
    try escaped(w, path);
}

/// What the `<relative-time>` element would display, frozen at `now`.
pub fn relativeTime(w: *Writer, t: i64, now: i64, zone: *const Zone) !void {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    var r: [64]u8 = undefined;
    try w.print("<relative-time data-component=\"RelativeTime\" tense=\"past\" datetime=\"{s}\" title=\"{s}\">{s}</relative-time>", .{
        time.iso(&a, t), time.title(&b, t, zone), time.relative(&r, t, now, zone),
    });
}

/// Parses the ISO 8601 instants GitHub's JSON carries (`2026-02-03T16:21:04Z`, `...000-06:00`).
pub fn parseIso(s: []const u8) ?i64 {
    if (s.len < 19 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return null;
    const civil = @import("civil.zig");
    const num = struct {
        fn f(x: []const u8) ?u32 {
            return std.fmt.parseInt(u32, x, 10) catch null;
        }
    }.f;
    const days = civil.toDays(@intCast(num(s[0..4]) orelse return null), @intCast(num(s[5..7]) orelse return null), @intCast(num(s[8..10]) orelse return null));
    var t = days * 86400 + @as(i64, num(s[11..13]) orelse return null) * 3600 + @as(i64, num(s[14..16]) orelse return null) * 60 + (num(s[17..19]) orelse return null);
    var rest = s[19..];
    if (rest.len > 0 and rest[0] == '.') {
        rest = rest[1..];
        while (rest.len > 0 and std.ascii.isDigit(rest[0])) rest = rest[1..];
    }
    if (rest.len == 6 and (rest[0] == '+' or rest[0] == '-') and rest[3] == ':') {
        const off = @as(i64, num(rest[1..3]) orelse return null) * 3600 + @as(i64, num(rest[4..6]) orelse return null) * 60;
        t -= if (rest[0] == '+') off else -off;
    } else if (!std.mem.eql(u8, rest, "Z")) return null;
    return t;
}

/// A commit summary as GitHub links it: text runs to the commit, `#123` to the issue, `:emoji:` replaced.
/// Whitespace at the edges of a run stays outside its link.
pub fn commitSummary(w: *Writer, repo_path: []const u8, commit_url: []const u8, summary: []const u8, with_title: bool) !void {
    const run = struct {
        fn f(out: *Writer, url: []const u8, full: []const u8, titled: bool, text: []const u8) !void {
            const core = std.mem.trim(u8, text, " \t");
            if (core.len == 0) return out.writeAll(text);
            const lead = std.mem.indexOf(u8, text, core).?;
            try out.writeAll(text[0..lead]);
            try out.writeAll("<a data-pjax=\"true\" ");
            if (titled) {
                try out.writeAll("title=\"");
                try escaped(out, full);
                try out.writeAll("\" ");
            }
            try out.print("class=\"Link--secondary\" href=\"{s}\">", .{url});
            try emojified(out, core);
            try out.writeAll("</a>");
            try out.writeAll(text[lead + core.len ..]);
        }
    }.f;
    var start: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, summary, i, '#')) |hash| {
        var end = hash + 1;
        while (end < summary.len and std.ascii.isDigit(summary[end])) end += 1;
        const bounded = (hash == 0 or !isWord(summary[hash - 1])) and (end == summary.len or !isWord(summary[end]));
        if (end == hash + 1 or !bounded) {
            i = hash + 1;
            continue;
        }
        try run(w, commit_url, summary, with_title, summary[start..hash]);
        const n = summary[hash + 1 .. end];
        try w.print("<a class=\"issue-link js-issue-link\" data-url=\"https://github.com/{s}/issues/{s}\" href=\"https://github.com/{s}/issues/{s}\">#{s}</a>", .{ repo_path, n, repo_path, n, n });
        start = end;
        i = end;
    }
    try run(w, commit_url, summary, with_title, summary[start..]);
}

fn isWord(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn emojified(w: *Writer, text: []const u8) !void {
    const emoji = @import("../html/emoji.zig");
    var pos: usize = 0;
    while (emoji.next(text, pos)) |m| {
        try escaped(w, text[pos..m.start]);
        switch (m.emoji) {
            .unicode => |u| try w.writeAll(u),
            .custom => |name| try w.print("<img class=\"emoji\" title=\":{s}:\" alt=\":{s}:\" src=\"https://github.githubassets.com/images/icons/emoji/{s}.png\" height=\"20\" width=\"20\" align=\"absmiddle\">", .{ name, name, name }),
        }
        pos = m.end;
    }
    try escaped(w, text[pos..]);
}

/// `encodeURIComponent`.
pub fn uriComponent(w: *Writer, s: []const u8) !void {
    try std.Uri.Component.percentEncode(w, s, struct {
        fn keep(ch: u8) bool {
            return std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-_.!~*'()", ch) != null;
        }
    }.keep);
}

/// An Octicon as `@primer/react` renders it; `body` is the SVG's inner markup.
pub fn octicon(w: *Writer, class: []const u8, body: []const u8) !void {
    try w.print("<svg data-component=\"Octicon\" aria-hidden=\"true\" focusable=\"false\" class=\"{s}\" viewBox=\"0 0 16 16\" width=\"16\" height=\"16\" fill=\"currentColor\" display=\"inline-block\" overflow=\"visible\" style=\"vertical-align:text-bottom\">{s}</svg>", .{ class, body });
}

/// `Number.prototype.toLocaleString("en-US")`: `34,475`.
pub fn grouped(w: *Writer, n: u64) !void {
    var buf: [32]u8 = undefined;
    const digits = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
    for (digits, 0..) |d, i| {
        if (i > 0 and (digits.len - i) % 3 == 0) try w.writeByte(',');
        try w.writeByte(d);
    }
}

/// `Intl.NumberFormat("en-US", {notation: "compact", maximumFractionDigits: 1, maximumSignificantDigits: 2})`.
pub fn compact(buf: []u8, n: u64) []const u8 {
    // Round to two significant digits first (half up), then pick the suffix: 999 is "1K".
    var unit: u64 = 1;
    while (n / unit >= 100) unit *= 10;
    const r = (n + unit / 2) / unit * unit;
    if (r < 1000) return std.fmt.bufPrint(buf, "{d}", .{r}) catch unreachable;
    const suffixes = [_][]const u8{ "K", "M", "B", "T" };
    var scale: u64 = 1000;
    var i: usize = 0;
    while (r / scale >= 1000 and i + 1 < suffixes.len) : (i += 1) scale *= 1000;
    const tenths = r * 10 / scale;
    if (tenths % 10 == 0) return std.fmt.bufPrint(buf, "{d}{s}", .{ tenths / 10, suffixes[i] }) catch unreachable;
    return std.fmt.bufPrint(buf, "{d}.{d}{s}", .{ tenths / 10, tenths % 10, suffixes[i] }) catch unreachable;
}

test "number formats match Intl en-US" {
    var buf: [32]u8 = undefined;
    // Expected values come from running that Intl formatter.
    const cases = [_]struct { n: u64, want: []const u8 }{
        .{ .n = 7, .want = "7" },
        .{ .n = 155, .want = "160" },
        .{ .n = 994, .want = "990" },
        .{ .n = 995, .want = "1K" },
        .{ .n = 1050, .want = "1.1K" },
        .{ .n = 1234, .want = "1.2K" },
        .{ .n = 34480, .want = "34K" },
        .{ .n = 125_000, .want = "130K" },
        .{ .n = 999_500, .want = "1M" },
        .{ .n = 1_540_000, .want = "1.5M" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c.want, compact(&buf, c.n));

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try grouped(&out.writer, 34475);
    try out.writer.writeByte(' ');
    try grouped(&out.writer, 999);
    try out.writer.writeByte(' ');
    try grouped(&out.writer, 1234567);
    try std.testing.expectEqualStrings("34,475 999 1,234,567", out.written());
}

test "links commit summaries like GitHub's shortMessageHtmlLink" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try commitSummary(&out.writer, "o/r", "C", "Merge pull request #394 from x/y", false);
    try std.testing.expectEqualStrings("<a data-pjax=\"true\" class=\"Link--secondary\" href=\"C\">Merge pull request</a> " ++
        "<a class=\"issue-link js-issue-link\" data-url=\"https://github.com/o/r/issues/394\" href=\"https://github.com/o/r/issues/394\">#394</a> " ++
        "<a data-pjax=\"true\" class=\"Link--secondary\" href=\"C\">from x/y</a>", out.written());
    out.clearRetainingCapacity();
    try commitSummary(&out.writer, "o/r", "C", "fix a#1 & :tada: (#12)", true);
    try std.testing.expectEqualStrings("<a data-pjax=\"true\" title=\"fix a#1 &amp; :tada: (#12)\" class=\"Link--secondary\" href=\"C\">fix a#1 &amp; \u{1f389} (</a>" ++
        "<a class=\"issue-link js-issue-link\" data-url=\"https://github.com/o/r/issues/12\" href=\"https://github.com/o/r/issues/12\">#12</a>" ++
        "<a data-pjax=\"true\" title=\"fix a#1 &amp; :tada: (#12)\" class=\"Link--secondary\" href=\"C\">)</a>", out.written());
}

test "parses GitHub's ISO instants" {
    try std.testing.expectEqual(@as(?i64, 1794727622), parseIso("2026-11-15T01:27:02.000-06:00"));
    try std.testing.expectEqual(@as(?i64, 1794727622), parseIso("2026-11-15T07:27:02Z"));
    try std.testing.expect(parseIso("yesterday") == null);
}
