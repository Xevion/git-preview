//! Build-time syntax highlighting: tree-sitter parses, `highlights.scm` captures are painted onto
//! the source bytes, and the result is written as GitHub's `pl-*` spans. The caller owns the wrapper.

const std = @import("std");
const c = @import("ts");
const classes = @import("classes.zig");
const languages = @import("languages.zig");
const regex = @import("regex.zig");

const Class = classes.Class;
const rows = languages.rows;

pub const resolve = languages.resolve;

pub const Error = error{ OutOfMemory, WriteFailed, UnsupportedLanguage, LanguageVersionMismatch, ParseFailed, InvalidQuery };

/// Linguist's scope for a fence language with dots as dashes (`source-shell`), or null when it is not built in.
pub fn scope(info_lang: []const u8) ?[]const u8 {
    const idx = resolve(info_lang) orelse return null;
    return dashed_scopes[idx];
}

const dashed_scopes = blk: {
    var out: [rows.len][]const u8 = undefined;
    for (rows, 0..) |row, i| {
        var buf: [row.scope.len]u8 = undefined;
        for (row.scope, 0..) |ch, k| buf[k] = if (ch == '.') '-' else ch;
        const final = buf;
        out[i] = &final;
    }
    break :blk out;
};

/// Writes the escaped source with `<span class="pl-*">` runs and no wrapper. One trailing newline is
/// dropped, as GitHub does. Fails with `UnsupportedLanguage` where `scope` is null.
pub fn writeSpans(gpa: std.mem.Allocator, info_lang: []const u8, code: []const u8, w: *std.Io.Writer) Error!void {
    const idx = resolve(info_lang) orelse return error.UnsupportedLanguage;
    const body = if (std.mem.endsWith(u8, code, "\n")) code[0 .. code.len - 1] else code;

    var canvas = try Canvas.init(gpa, body.len);
    defer canvas.deinit(gpa);
    try paintLanguage(gpa, &canvas, idx, body);
    try canvas.write(w, body);
}

/// Per-byte styling: the winning class, the pattern that set it, and the escape overlay.
const Canvas = struct {
    class: []Class,
    prio: []u32,
    escape: []bool,

    fn init(gpa: std.mem.Allocator, len: usize) !Canvas {
        const class = try gpa.alloc(Class, len);
        errdefer gpa.free(class);
        const prio = try gpa.alloc(u32, len);
        errdefer gpa.free(prio);
        const escape = try gpa.alloc(bool, len);
        @memset(class, .none);
        @memset(prio, 0);
        @memset(escape, false);
        return .{ .class = class, .prio = prio, .escape = escape };
    }

    fn deinit(self: Canvas, gpa: std.mem.Allocator) void {
        gpa.free(self.class);
        gpa.free(self.prio);
        gpa.free(self.escape);
    }

    /// The earliest pattern wins, as in tree-sitter's own highlighter, so specific rules precede general ones.
    fn paint(self: *Canvas, start: usize, end: usize, class: Class, pattern: u32) void {
        const stop = @min(end, self.class.len);
        for (start..stop) |i| {
            if (class == .escape) {
                self.escape[i] = true;
            } else if (self.prio[i] == 0 or pattern < self.prio[i]) {
                self.prio[i] = pattern;
                self.class[i] = class;
            }
        }
    }

    /// Spans end at each newline so every line is balanced on its own, and a string's escapes nest inside it.
    fn write(self: Canvas, w: *std.Io.Writer, code: []const u8) !void {
        var open: Class = .none;
        var i: usize = 0;
        while (i < code.len) {
            if (code[i] == '\n') {
                if (open != .none) try w.writeAll("</span>");
                open = .none;
                try w.writeByte('\n');
                i += 1;
                continue;
            }
            const class = self.class[i];
            const esc = self.escape[i];
            var j = i + 1;
            while (j < code.len and code[j] != '\n' and self.class[j] == class and self.escape[j] == esc) j += 1;
            if (class != open) {
                if (open != .none) try w.writeAll("</span>");
                if (class != .none) try w.print("<span class=\"{s}\">", .{class.css()});
                open = class;
            }
            if (esc) try w.writeAll("<span class=\"pl-cce\">");
            try writeEscaped(w, code[i..j]);
            if (esc) try w.writeAll("</span>");
            i = j;
        }
        if (open != .none) try w.writeAll("</span>");
    }
};

/// Escapes exactly what the Markdown renderer's text escaper does.
pub fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    var start: usize = 0;
    for (s, 0..) |ch, i| {
        const rep: []const u8 = switch (ch) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            else => continue,
        };
        try w.writeAll(s[start..i]);
        try w.writeAll(rep);
        start = i + 1;
    }
    try w.writeAll(s[start..]);
}

const Loaded = struct {
    language: *const c.TSLanguage,
    query: *c.TSQuery,
    capture_class: []Class,
};

var loaded: [rows.len]?Loaded = @splat(null);

fn languageOf(idx: usize) *const c.TSLanguage {
    inline for (rows, 0..) |row, i| {
        if (i == idx) {
            const get = @extern(*const fn () callconv(.c) *const c.TSLanguage, .{ .name = "tree_sitter_" ++ row.name });
            return get();
        }
    }
    unreachable;
}

fn querySource(comptime idx: usize) []const u8 {
    const src = comptime blk: {
        var joined: []const u8 = "";
        for (0..rows[idx].query_parts) |part| {
            joined = joined ++ @embedFile(std.fmt.comptimePrint("hlq_{s}_{d}", .{ rows[idx].name, part })) ++ "\n";
        }
        break :blk joined;
    };
    return src;
}

fn querySourceOf(idx: usize) []const u8 {
    inline for (0..rows.len) |i| if (i == idx) return querySource(i);
    unreachable;
}

/// Grammars and compiled queries live for the process; the first use of a language pays for compiling its query.
fn load(idx: usize) Error!Loaded {
    if (loaded[idx]) |l| return l;
    const language = languageOf(idx);
    const src = querySourceOf(idx);
    var err_offset: u32 = 0;
    var err_type: c.TSQueryError = c.TSQueryErrorNone;
    const query = c.ts_query_new(language, src.ptr, @intCast(src.len), &err_offset, &err_type) orelse return error.InvalidQuery;
    const count = c.ts_query_capture_count(query);
    const capture_class = try std.heap.page_allocator.alloc(Class, count);
    for (capture_class, 0..) |*slot, i| {
        var len: u32 = 0;
        const name = c.ts_query_capture_name_for_id(query, @intCast(i), &len);
        slot.* = classes.classify(name[0..len]);
        if (rows[idx].operators_constant and slot.* == .keyword and std.mem.eql(u8, name[0..len], "operator")) slot.* = .constant;
    }
    const l: Loaded = .{ .language = language, .query = query, .capture_class = capture_class };
    loaded[idx] = l;
    return l;
}

fn paintLanguage(gpa: std.mem.Allocator, canvas: *Canvas, idx: usize, code: []const u8) Error!void {
    const l = try load(idx);
    const parser = c.ts_parser_new() orelse return error.OutOfMemory;
    defer c.ts_parser_delete(parser);
    if (!c.ts_parser_set_language(parser, l.language)) return error.LanguageVersionMismatch;
    const tree = c.ts_parser_parse_string(parser, null, code.ptr, @intCast(code.len)) orelse return error.ParseFailed;
    defer c.ts_tree_delete(tree);
    const root = c.ts_tree_root_node(tree);
    const base = try runQuery(canvas, l, root, code, 0);

    const inner_name = rows[idx].inline_lang;
    if (inner_name.len == 0) return;
    const inner_idx = inline for (rows, 0..) |row, i| {
        if (comptime row.name.len > 0) {
            if (std.mem.eql(u8, row.name, inner_name)) break i;
        }
    } else return;
    try paintInline(gpa, canvas, inner_idx, root, code, base);
}

/// Markdown's inline grammar runs over the block grammar's `inline` nodes only.
fn paintInline(gpa: std.mem.Allocator, canvas: *Canvas, idx: usize, root: c.TSNode, code: []const u8, base: u32) Error!void {
    var ranges: std.ArrayList(c.TSRange) = .empty;
    defer ranges.deinit(gpa);
    try collectInline(gpa, &ranges, root);
    if (ranges.items.len == 0) return;

    const l = try load(idx);
    const parser = c.ts_parser_new() orelse return error.OutOfMemory;
    defer c.ts_parser_delete(parser);
    if (!c.ts_parser_set_language(parser, l.language)) return error.LanguageVersionMismatch;
    if (!c.ts_parser_set_included_ranges(parser, ranges.items.ptr, @intCast(ranges.items.len))) return error.ParseFailed;
    const tree = c.ts_parser_parse_string(parser, null, code.ptr, @intCast(code.len)) orelse return error.ParseFailed;
    defer c.ts_tree_delete(tree);
    _ = try runQuery(canvas, l, c.ts_tree_root_node(tree), code, base);
}

fn collectInline(gpa: std.mem.Allocator, out: *std.ArrayList(c.TSRange), node: c.TSNode) !void {
    if (std.mem.eql(u8, std.mem.span(c.ts_node_type(node)), "inline")) {
        try out.append(gpa, .{
            .start_point = c.ts_node_start_point(node),
            .end_point = c.ts_node_end_point(node),
            .start_byte = c.ts_node_start_byte(node),
            .end_byte = c.ts_node_end_byte(node),
        });
        return;
    }
    const n = c.ts_node_child_count(node);
    for (0..n) |i| try collectInline(gpa, out, c.ts_node_child(node, @intCast(i)));
}

/// Returns the priority base for a following query, so a second grammar's patterns outrank this one's.
fn runQuery(canvas: *Canvas, l: Loaded, root: c.TSNode, code: []const u8, base: u32) Error!u32 {
    const cursor = c.ts_query_cursor_new() orelse return error.OutOfMemory;
    defer c.ts_query_cursor_delete(cursor);
    c.ts_query_cursor_exec(cursor, l.query, root);

    var match: c.TSQueryMatch = undefined;
    while (c.ts_query_cursor_next_match(cursor, &match)) {
        if (!predicatesHold(l.query, match, code)) continue;
        const pattern: u32 = base + @as(u32, match.pattern_index) + 1;
        for (match.captures[0..match.capture_count]) |cap| {
            const class = l.capture_class[cap.index];
            if (class == .none) continue;
            canvas.paint(c.ts_node_start_byte(cap.node), c.ts_node_end_byte(cap.node), class, pattern);
        }
    }
    return base + c.ts_query_pattern_count(l.query);
}

const Arg = union(enum) { capture: u32, string: []const u8 };

fn predicatesHold(query: *const c.TSQuery, match: c.TSQueryMatch, code: []const u8) bool {
    var count: u32 = 0;
    const raw = c.ts_query_predicates_for_pattern(query, match.pattern_index, &count);
    if (count == 0) return true;
    const steps = raw[0..count];
    var args: [16]Arg = undefined;
    var i: usize = 0;
    while (i < steps.len) {
        const name = stringValue(query, steps[i].value_id);
        i += 1;
        var n: usize = 0;
        while (i < steps.len and steps[i].type != c.TSQueryPredicateStepTypeDone) : (i += 1) {
            if (n == args.len) continue;
            args[n] = if (steps[i].type == c.TSQueryPredicateStepTypeCapture)
                .{ .capture = steps[i].value_id }
            else
                .{ .string = stringValue(query, steps[i].value_id) };
            n += 1;
        }
        i += 1;
        if (!evaluate(name, args[0..n], match, code)) return false;
    }
    return true;
}

fn stringValue(query: *const c.TSQuery, id: u32) []const u8 {
    var len: u32 = 0;
    const ptr = c.ts_query_string_value_for_id(query, id, &len);
    return ptr[0..len];
}

fn argText(arg: Arg, match: c.TSQueryMatch, code: []const u8) ?[]const u8 {
    switch (arg) {
        .string => |s| return s,
        .capture => |id| {
            for (match.captures[0..match.capture_count]) |cap| {
                if (cap.index == id) return code[c.ts_node_start_byte(cap.node)..c.ts_node_end_byte(cap.node)];
            }
            return null;
        },
    }
}

/// `#set!`, `#is-not?` and other directives carry no filtering meaning here and pass.
fn evaluate(name: []const u8, args: []const Arg, match: c.TSQueryMatch, code: []const u8) bool {
    return evaluateText(name, args, struct {
        match: c.TSQueryMatch,
        code: []const u8,
        pub fn text(self: @This(), arg: Arg) ?[]const u8 {
            return argText(arg, self.match, self.code);
        }
    }{ .match = match, .code = code });
}

/// Predicate semantics over any argument resolver, so they can be tested without a parse tree.
fn evaluateText(name: []const u8, args: []const Arg, ctx: anytype) bool {
    const eql = std.mem.eql;
    if (args.len == 0) return true;
    if (eql(u8, name, "eq?") or eql(u8, name, "not-eq?")) {
        if (args.len < 2) return true;
        const a = ctx.text(args[0]) orelse return true;
        const b = ctx.text(args[1]) orelse return true;
        return eql(u8, a, b) == eql(u8, name, "eq?");
    }
    if (eql(u8, name, "any-of?") or eql(u8, name, "not-any-of?")) {
        const a = ctx.text(args[0]) orelse return true;
        var hit = false;
        for (args[1..]) |arg| switch (arg) {
            .string => |s| if (eql(u8, a, s)) {
                hit = true;
            },
            .capture => {},
        };
        return hit == eql(u8, name, "any-of?");
    }
    if (eql(u8, name, "contains?")) {
        const a = ctx.text(args[0]) orelse return true;
        for (args[1..]) |arg| switch (arg) {
            .string => |s| if (std.mem.indexOf(u8, a, s) != null) return true,
            .capture => {},
        };
        return false;
    }
    const positive = eql(u8, name, "match?") or eql(u8, name, "lua-match?") or eql(u8, name, "vim-match?");
    const negative = eql(u8, name, "not-match?") or eql(u8, name, "not-lua-match?");
    if (positive or negative) {
        if (args.len < 2) return true;
        const a = ctx.text(args[0]) orelse return true;
        const pat = switch (args[1]) {
            .string => |s| s,
            .capture => return true,
        };
        return switch (regex.search(pat, a)) {
            .match => positive,
            .no_match => negative,
            .unsupported => false,
        };
    }
    return true;
}

const test_gpa = std.testing.allocator;

const StubCtx = struct {
    capture: []const u8,
    pub fn text(self: StubCtx, arg: Arg) ?[]const u8 {
        return switch (arg) {
            .string => |s| s,
            .capture => self.capture,
        };
    }
};

test "predicates: eq, any-of, match" {
    const ctx: StubCtx = .{ .capture = "MAX_SIZE" };
    const cap: Arg = .{ .capture = 0 };
    try std.testing.expect(evaluateText("eq?", &.{ cap, .{ .string = "MAX_SIZE" } }, ctx));
    try std.testing.expect(!evaluateText("eq?", &.{ cap, .{ .string = "other" } }, ctx));
    try std.testing.expect(evaluateText("not-eq?", &.{ cap, .{ .string = "other" } }, ctx));
    try std.testing.expect(evaluateText("any-of?", &.{ cap, .{ .string = "A" }, .{ .string = "MAX_SIZE" } }, ctx));
    try std.testing.expect(!evaluateText("any-of?", &.{ cap, .{ .string = "A" }, .{ .string = "B" } }, ctx));
    try std.testing.expect(evaluateText("lua-match?", &.{ cap, .{ .string = "^[A-Z][A-Z_]+$" } }, ctx));
    try std.testing.expect(!evaluateText("match?", &.{ cap, .{ .string = "^[a-z]" } }, ctx));
    try std.testing.expect(evaluateText("not-match?", &.{ cap, .{ .string = "^[a-z]" } }, ctx));
}

test "predicates: unsupported regex rejects, unknown directives pass" {
    const ctx: StubCtx = .{ .capture = "x" };
    const cap: Arg = .{ .capture = 0 };
    try std.testing.expect(!evaluateText("match?", &.{ cap, .{ .string = "(ab)+" } }, ctx));
    try std.testing.expect(evaluateText("set!", &.{ cap, .{ .string = "k" } }, ctx));
}

fn spansToString(info: []const u8, code: []const u8) !?[]u8 {
    var out: std.Io.Writer.Allocating = .init(test_gpa);
    defer out.deinit();
    writeSpans(test_gpa, info, code, &out.writer) catch |err| switch (err) {
        error.UnsupportedLanguage => return null,
        else => return err,
    };
    return try out.toOwnedSlice();
}

/// The `/markdown` API's block wrapper; the README view uses another one, owned by the renderer.
fn apiBlock(info: []const u8, code: []const u8) !?[]u8 {
    const spans = (try spansToString(info, code)) orelse return null;
    defer test_gpa.free(spans);
    return try std.fmt.allocPrint(test_gpa, "<div class=\"highlight highlight-{s}\" dir=\"auto\"><pre class=\"notranslate\">{s}</pre></div>", .{ scope(info).?, spans });
}

test "unknown languages have no scope and write nothing" {
    try std.testing.expectEqual(@as(?[]const u8, null), scope("brainfuck"));
    var out: std.Io.Writer.Allocating = .init(test_gpa);
    defer out.deinit();
    try std.testing.expectError(error.UnsupportedLanguage, writeSpans(test_gpa, "brainfuck", "+++", &out.writer));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "scope swaps dots for dashes" {
    if (scope("rs")) |s| try std.testing.expectEqualStrings("source-rust", s);
    if (scope("c++")) |s| try std.testing.expectEqualStrings("source-c++", s);
    if (scope("html")) |s| try std.testing.expectEqualStrings("text-html-basic", s);
}

test "escaping matches the renderer's text escaper" {
    var out: std.Io.Writer.Allocating = .init(test_gpa);
    defer out.deinit();
    try writeEscaped(&out.writer, "a < b && c > \"d\"");
    try std.testing.expectEqualStrings("a &lt; b &amp;&amp; c &gt; \"d\"", out.written());
}

/// Visible text of a rendered block: tags removed, entities decoded.
fn visibleText(gpa: std.mem.Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            i = std.mem.indexOfScalarPos(u8, html, i, '>').? + 1;
            continue;
        }
        const entities = [_]struct { []const u8, u8 }{ .{ "&amp;", '&' }, .{ "&lt;", '<' }, .{ "&gt;", '>' } };
        const decoded = for (entities) |e| {
            if (std.mem.startsWith(u8, html[i..], e[0])) {
                try out.append(gpa, e[1]);
                i += e[0].len;
                break true;
            }
        } else false;
        if (decoded) continue;
        try out.append(gpa, html[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// Opening and closing spans must nest and balance within every line.
fn expectBalancedSpans(html: []const u8) !void {
    var depth: usize = 0;
    for (html) |ch| if (ch == '\n') try std.testing.expectEqual(@as(usize, 0), depth);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, html, i, "<")) |lt| {
        if (std.mem.startsWith(u8, html[lt..], "<span")) depth += 1;
        if (std.mem.startsWith(u8, html[lt..], "</span>")) depth -= 1;
        i = lt + 1;
    }
    try std.testing.expectEqual(@as(usize, 0), depth);
}

const Fence = struct { info: []const u8, code: []const u8 };

/// The fenced code blocks of a small Markdown fixture, in order.
fn fences(gpa: std.mem.Allocator, md: []const u8) ![]Fence {
    var out: std.ArrayList(Fence) = .empty;
    errdefer out.deinit(gpa);
    var rest = md;
    while (std.mem.indexOf(u8, rest, "```")) |open| {
        const info_start = open + 3;
        const info_end = std.mem.indexOfScalarPos(u8, rest, info_start, '\n').?;
        const code_start = info_end + 1;
        const close = std.mem.indexOfPos(u8, rest, code_start, "```").?;
        try out.append(gpa, .{ .info = rest[info_start..info_end], .code = rest[code_start..close] });
        rest = rest[close + 3 ..];
    }
    return out.toOwnedSlice(gpa);
}

/// Each `<div class="highlight ...">` block of GitHub's recorded output, in order.
fn goldenBlocks(gpa: std.mem.Allocator, golden: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var rest = golden;
    while (std.mem.indexOf(u8, rest, "<div class=\"highlight ")) |start| {
        const end = std.mem.indexOfPos(u8, rest, start, "</pre></div>").? + "</pre></div>".len;
        try out.append(gpa, rest[start..end]);
        rest = rest[end..];
    }
    return out.toOwnedSlice(gpa);
}

test "fixture blocks have GitHub's wrapper and the same text" {
    const io = std.testing.io;
    const md = try std.Io.Dir.cwd().readFileAlloc(io, "tests/markdown/highlight.md", test_gpa, .limited(1 << 20));
    defer test_gpa.free(md);
    const golden = try std.Io.Dir.cwd().readFileAlloc(io, "tests/markdown/highlight.github.html", test_gpa, .limited(1 << 20));
    defer test_gpa.free(golden);

    const blocks = try fences(test_gpa, md);
    defer test_gpa.free(blocks);
    const expected = try goldenBlocks(test_gpa, golden);
    defer test_gpa.free(expected);
    try std.testing.expectEqual(expected.len, blocks.len);

    for (blocks, expected) |fence, gold| {
        const lang = fence.info[0 .. std.mem.indexOfAny(u8, fence.info, " \t") orelse fence.info.len];
        const html = (try apiBlock(lang, fence.code)) orelse return error.SkipZigTest;
        defer test_gpa.free(html);

        const wrapper_end = std.mem.indexOf(u8, gold, "<pre class=\"notranslate\">").? + "<pre class=\"notranslate\">".len;
        try std.testing.expect(std.mem.startsWith(u8, html, gold[0..wrapper_end]));
        try std.testing.expect(std.mem.endsWith(u8, html, "</pre></div>"));
        try expectBalancedSpans(html);

        const ours = try visibleText(test_gpa, html);
        defer test_gpa.free(ours);
        const theirs = try visibleText(test_gpa, gold);
        defer test_gpa.free(theirs);
        try std.testing.expectEqualStrings(theirs, ours);
        try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"pl-") != null);
    }
}

test "escapes and string escapes nest inside their string" {
    const html = (try spansToString("zig", "const s = \"a\\n<b>\";\n")) orelse return error.SkipZigTest;
    defer test_gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"pl-s\">\"a<span class=\"pl-cce\">\\n</span>&lt;b&gt;\"</span>") != null);
    try expectBalancedSpans(html);
}

test "multi-line tokens are split at each newline" {
    const html = (try spansToString("c", "/* a\nb */\nint x;\n")) orelse return error.SkipZigTest;
    defer test_gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"pl-c\">/* a</span>\n<span class=\"pl-c\">b */</span>\n") != null);
}

const snippets = [_]struct { name: []const u8, code: []const u8 }{
    .{ .name = "zig", .code = "const x: u8 = 1; // c\n" },
    .{ .name = "rust", .code = "fn main() { let _x = 1 < 2; }\n" },
    .{ .name = "python", .code = "def f(a): return a  # c\n" },
    .{ .name = "javascript", .code = "const f = (a) => a && `x${a}`;\n" },
    .{ .name = "typescript", .code = "let a: Array<number> = [1];\n" },
    .{ .name = "tsx", .code = "const e = <div id=\"a\">{1}</div>;\n" },
    .{ .name = "bash", .code = "echo \"$HOME\" | grep -c x # c\n" },
    .{ .name = "c", .code = "#include <stdio.h>\nint main(void) { return 0; }\n" },
    .{ .name = "cpp", .code = "template <class T> struct S { T v; };\n" },
    .{ .name = "go", .code = "package main\nfunc main() { x := 1 }\n" },
    .{ .name = "java", .code = "class A { int f(int x) { return x; } }\n" },
    .{ .name = "json", .code = "{\"a\": [1, true, null]}\n" },
    .{ .name = "toml", .code = "[a]\nb = \"c\"\n" },
    .{ .name = "yaml", .code = "a:\n  - b\n  - 1\n" },
    .{ .name = "html", .code = "<a href=\"x\">y &amp; z</a>\n" },
    .{ .name = "css", .code = "a > b { color: #fff; }\n" },
    .{ .name = "markdown", .code = "# T\n\n*a* `b` [c](d)\n" },
    .{ .name = "diff", .code = "@@ -1 +1 @@\n-a\n+b\n" },
};

test "every selected language renders balanced markup that keeps the source text" {
    for (rows) |row| {
        if (row.scope.len == 0) continue;
        const code = for (snippets) |s| {
            if (std.mem.eql(u8, s.name, row.name)) break s.code;
        } else continue;
        const html = (try spansToString(row.name, code)) orelse return error.TestUnexpectedResult;
        defer test_gpa.free(html);
        try expectBalancedSpans(html);
        const text = try visibleText(test_gpa, html);
        defer test_gpa.free(text);
        try std.testing.expectEqualStrings(code[0 .. code.len - 1], text);
    }
}

test "every selected query uses only regexes the matcher supports" {
    inline for (0..rows.len) |i| {
        const l = try load(i);
        for (0..c.ts_query_pattern_count(l.query)) |pattern| {
            var count: u32 = 0;
            const raw = c.ts_query_predicates_for_pattern(l.query, @intCast(pattern), &count);
            if (count == 0) continue;
            const steps = raw[0..count];
            var k: usize = 0;
            while (k + 2 < steps.len) : (k += 1) {
                if (steps[k].type != c.TSQueryPredicateStepTypeString) continue;
                if (!std.mem.endsWith(u8, stringValue(l.query, steps[k].value_id), "match?")) continue;
                if (steps[k + 2].type != c.TSQueryPredicateStepTypeString) continue;
                const pat = stringValue(l.query, steps[k + 2].value_id);
                std.testing.expect(regex.search(pat, "") != .unsupported) catch |err| {
                    std.debug.print("{s}: unsupported regex {s}\n", .{ rows[i].name, pat });
                    return err;
                };
            }
        }
    }
}
