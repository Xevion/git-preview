//! Fills a repository home page template with local data: branch, commit count, latest commit,
//! and the file table, replacing GitHub's skeleton placeholders and its remote state.

const std = @import("std");
const c = @import("lexbor");
const dom = @import("../html/dom.zig");
const template = @import("template.zig");
const time = @import("time.zig");
const Zone = @import("Zone.zig");
const octicons = @import("../render/octicons.zig");
const Repo = @import("../repo/Repo.zig");
const Node = dom.Node;
const log = std.log.scoped(.chrome);

pub const Entry = struct {
    name: []const u8,
    kind: Repo.EntryKind,
    commit: Repo.Commit,
};

pub const Data = struct {
    /// `owner/name` on the forge, for links.
    repo_path: []const u8,
    /// Branch name, or the abbreviated commit when HEAD is detached.
    ref: []const u8,
    commit_count: u64,
    head: Repo.Commit,
    entries: []const Entry,
    now: i64,
    zone: *const Zone,
};

pub fn fill(gpa: std.mem.Allocator, page: *template.Page, data: Data) !void {
    setBranch(page, data.ref);
    setCommitCount(gpa, page, data);
    try setLatestCommit(gpa, page, data);
    try setRows(gpa, page, data);
}

fn classPrefix(node: *Node, prefix: []const u8) bool {
    const cls = dom.getAttr(@ptrCast(node), "class") orelse return false;
    var it = std.mem.tokenizeScalar(u8, cls, ' ');
    while (it.next()) |t| if (std.mem.startsWith(u8, t, prefix)) return true;
    return false;
}

fn setText(node: *Node, text: []const u8) void {
    _ = c.lxb_dom_node_text_content_set(node, text.ptr, text.len);
}

fn setBranch(page: *template.Page, ref: []const u8) void {
    const label = dom.find(page.root(), {}, struct {
        fn pred(_: void, n: *Node) bool {
            return classPrefix(n, "RefSelectorText__");
        }
    }.pred) orelse return log.warn("template has no branch selector", .{});
    setText(label, ref);
}

fn setCommitCount(gpa: std.mem.Allocator, page: *template.Page, data: Data) void {
    const link = dom.find(page.root(), {}, struct {
        fn pred(_: void, n: *Node) bool {
            if (!std.mem.eql(u8, dom.localName(n), "a")) return false;
            const href = dom.getAttr(@ptrCast(n), "href") orelse return false;
            return std.mem.indexOf(u8, href, "/commits/") != null and
                std.mem.eql(u8, dom.getAttr(@ptrCast(n), "data-component") orelse "", "LinkButton");
        }
    }.pred) orelse return log.warn("template has no commit history link", .{});
    const label = dom.find(link, {}, struct {
        fn pred(_: void, n: *Node) bool {
            return classPrefix(n, "fgColor-default");
        }
    }.pred) orelse return;
    var buf: [64]u8 = undefined;
    setText(label, std.fmt.bufPrint(&buf, "{d} Commit{s}", .{ data.commit_count, if (data.commit_count == 1) "" else "s" }) catch return);
    const href = std.fmt.allocPrint(gpa, "https://github.com/{s}/commits/{s}/", .{ data.repo_path, data.ref }) catch return;
    defer gpa.free(href);
    dom.setAttr(@ptrCast(link), "href", href);
}

fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(ch),
    };
}

fn writeRelativeTime(w: *std.Io.Writer, t: i64, now: i64, zone: *const Zone) !void {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    var r: [64]u8 = undefined;
    try w.print("<relative-time data-component=\"RelativeTime\" tense=\"past\" datetime=\"{s}\" title=\"{s}\">{s}</relative-time>", .{
        time.iso(&a, t), time.title(&b, t, zone), time.relative(&r, t, now, zone),
    });
}

fn commitHref(w: *std.Io.Writer, data: Data, commit: Repo.Commit) !void {
    var hex: [Repo.Oid.max_hex_len]u8 = undefined;
    try w.print("https://github.com/{s}/commit/{s}", .{ data.repo_path, commit.oid.hex(&hex) });
}

fn setLatestCommit(gpa: std.mem.Allocator, page: *template.Page, data: Data) !void {
    const loading = template.byTestId(page, "loading") orelse return log.warn("template has no latest-commit placeholder", .{});
    const details = template.byTestId(page, "latest-commit-details");
    const head = data.head;
    var hex: [Repo.Oid.max_hex_len]u8 = undefined;
    const sha = head.oid.hex(&hex);

    var bar: std.Io.Writer.Allocating = .init(gpa);
    defer bar.deinit();
    const w = &bar.writer;
    try w.print("<div data-testid=\"latest-commit\" class=\"d-flex flex-items-center gap-2 min-width-0\"><div class=\"d-flex flex-items-center gap-2\"><span class=\"{s}\" style=\"--author-font-weight: var(--base-text-weight-semibold); --author-font-color: var(--fgColor-default); font-weight: var(--base-text-weight-semibold); color: var(--fgColor-default);\">", .{page.class("authorHoverableLink", "")});
    try writeEscaped(w, head.author_name);
    try w.writeAll("</span></div><div class=\"d-none d-sm-flex min-width-0\"><div class=\"Truncate flex-items-center f5\"><span class=\"Truncate-text\" data-testid=\"latest-commit-html\"><a class=\"Link--secondary\" href=\"");
    try commitHref(w, data, head);
    try w.writeAll("\">");
    try writeEscaped(w, head.summary);
    try w.writeAll("</a></span></div></div><span class=\"d-flex d-sm-none fgColor-muted\">");
    try writeRelativeTime(w, head.author_time, data.now, data.zone);
    try w.writeAll("</span></div>");
    try page.setInnerHtml(loading, "gp-latest", try gpa.dupe(u8, bar.written()));
    unwrapMarkerHost(loading);

    if (details) |d| {
        var info: std.Io.Writer.Allocating = .init(gpa);
        defer info.deinit();
        try info.writer.print("<span class=\"d-flex flex-nowrap fgColor-muted f6\"><a class=\"Link--secondary {s}\" aria-label=\"Commit {s}\" href=\"", .{ page.class("prc-Link-Link", ""), sha[0..7] });
        try commitHref(&info.writer, data, head);
        try info.writer.print("\">{s}</a>&nbsp;·&nbsp;", .{sha[0..7]});
        try writeRelativeTime(&info.writer, head.author_time, data.now, data.zone);
        try info.writer.writeAll("</span>");
        try page.setInnerHtml(d, "gp-latest-details", try gpa.dupe(u8, info.written()));
    }
}

/// The skeleton element has a fixed width and skeleton styling; keep only its new contents.
fn unwrapMarkerHost(node: *Node) void {
    dom.setAttr(@ptrCast(node), "class", "d-flex flex-items-center min-width-0");
    dom.setAttr(@ptrCast(node), "style", "");
    dom.setAttr(@ptrCast(node), "data-testid", "latest-commit-host");
}

fn isRow(_: void, n: *Node) bool {
    return std.mem.eql(u8, dom.localName(n), "tr") and classPrefix(n, "react-directory-row");
}

/// Directories first; within each group the input's git tree order is kept, as GitHub does.
fn entryOrder(_: void, a: Entry, b: Entry) bool {
    const a_dir = a.kind == .directory or a.kind == .submodule;
    const b_dir = b.kind == .directory or b.kind == .submodule;
    return a_dir and !b_dir;
}

fn setRows(gpa: std.mem.Allocator, page: *template.Page, data: Data) !void {
    const first = dom.find(page.root(), {}, isRow) orelse return log.warn("template has no file table", .{});
    const body: *Node = @as(?*Node, first.parent) orelse return;
    var cur: ?*Node = body.first_child;
    while (cur) |n| {
        cur = n.next;
        if (n.type == c.LXB_DOM_NODE_TYPE_ELEMENT and isRow({}, n) and n != first) dom.remove(n);
    }

    const entries = try gpa.dupe(Entry, data.entries);
    defer gpa.free(entries);
    std.sort.insertion(Entry, entries, {}, entryOrder);

    var rows: std.Io.Writer.Allocating = .init(gpa);
    defer rows.deinit();
    for (entries, 0..) |e, i| try writeRow(&rows.writer, data, e, i);

    // The first template row is the splice point, so the rows land where GitHub's were.
    try page.replaceWith(first, "gp-rows", try gpa.dupe(u8, rows.written()));
}

fn writeRow(w: *std.Io.Writer, data: Data, e: Entry, i: usize) !void {
    const is_dir = e.kind == .directory or e.kind == .submodule;
    const icon_class, const icon = switch (e.kind) {
        .directory => .{ "octicon octicon-file-directory-fill icon-directory", octicons.file_directory_fill },
        .submodule => .{ "octicon octicon-file-submodule color-fg-muted", octicons.file_submodule },
        .symlink => .{ "octicon octicon-file-symlink-file color-fg-muted", octicons.file_symlink_file },
        else => .{ "octicon octicon-file color-fg-muted", octicons.file },
    };
    try w.print("<tr class=\"react-directory-row {s}\" id=\"folder-row-{d}\">", .{ if (i < 10) "undefined" else "truncate-for-mobile", i });
    inline for (.{ .{ "small", "2" }, .{ "large", "1" } }) |cell| {
        try w.print("<td class=\"react-directory-row-name-cell-{s}-screen\" colspan=\"{s}\"><div class=\"react-directory-filename-column\">", .{ cell[0], cell[1] });
        try w.print("<svg data-component=\"Octicon\" aria-hidden=\"true\" focusable=\"false\" class=\"{s}\" viewBox=\"0 0 16 16\" width=\"16\" height=\"16\" fill=\"currentColor\" display=\"inline-block\" overflow=\"visible\" style=\"vertical-align:text-bottom\">{s}</svg>", .{ icon_class, icon });
        try w.writeAll("<div class=\"overflow-hidden\"><div class=\"react-directory-filename-cell\"><div class=\"react-directory-truncate\"><a title=\"");
        try writeEscaped(w, e.name);
        try w.writeAll("\" aria-label=\"");
        try writeEscaped(w, e.name);
        try w.print(", ({s})\" class=\"Link--primary\" href=\"https://github.com/{s}/{s}/{s}/", .{ if (is_dir) "Directory" else "File", data.repo_path, if (is_dir) "tree" else "blob", data.ref });
        try writeEscaped(w, e.name);
        try w.writeAll("\">");
        try writeEscaped(w, e.name);
        try w.writeAll("</a></div></div></div></div></td>");
    }
    try w.writeAll("<td class=\"react-directory-row-commit-cell\"><div><div class=\"react-directory-commit-message\"><a title=\"");
    try writeEscaped(w, e.commit.summary);
    try w.writeAll("\" class=\"Link--secondary\" href=\"");
    try commitHref(w, data, e.commit);
    try w.writeAll("\">");
    try writeEscaped(w, e.commit.summary);
    try w.writeAll("</a></div></div></td><td><div class=\"react-directory-commit-age\">");
    try writeRelativeTime(w, e.commit.author_time, data.now, data.zone);
    try w.writeAll("</div></td></tr>");
}

test "fills the skeleton regions of a repo page template" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var fetcher: @import("../net/Fetcher.zig") = .init(gpa, std.testing.io, &env, true);
    defer fetcher.deinit();

    var page = try template.parse(arena, &fetcher,
        \\<html><body><button><span class="RefSelectorText__abc123">main</span></button>
        \\<div style="width:120px" class="Skeleton" data-testid="loading"> </div><div data-testid="latest-commit-details"></div>
        \\<a data-component="LinkButton" href="/o/r/commits/main/"><span class="fgColor-default">9 Commits</span></a>
        \\<table><tbody><tr class="react-directory-row undefined" id="folder-row-0"><td>old</td></tr>
        \\<tr class="react-directory-row undefined" id="folder-row-1"><td>old2</td></tr><tr data-testid="view-all-files-row"></tr></tbody></table>
        \\</body></html>
    );
    defer page.deinit();

    const oid = try Repo.Oid.parseHex("0123456789abcdef0123456789abcdef01234567");
    const commit: Repo.Commit = .{ .oid = oid, .summary = @constCast("fix: a <b>"), .author_name = @constCast("Ann"), .author_email = @constCast("a@x"), .author_time = 1000, .commit_time = 1000, .has_body = false };
    try fill(arena, &page, .{
        .repo_path = "o/r",
        .ref = "dev",
        .commit_count = 1,
        .head = commit,
        .entries = &.{
            .{ .name = "z.txt", .kind = .file, .commit = commit },
            .{ .name = "src", .kind = .directory, .commit = commit },
        },
        .now = 1000 + 2 * 86400,
        .zone = &Zone.utc,
    });
    const html = try page.serialize(arena);

    const has = struct {
        fn f(h: []const u8, needle: []const u8) !void {
            if (std.mem.indexOf(u8, h, needle) == null) {
                std.debug.print("missing: {s}\n", .{needle});
                return error.TestExpectedEqual;
            }
        }
    }.f;
    try has(html, ">dev</span>");
    try has(html, ">1 Commit</span>");
    try has(html, "fix: a &lt;b&gt;</a>");
    try has(html, ">2 days ago</relative-time>");
    try has(html, ">0123456</a>");
    try std.testing.expect(std.mem.indexOf(u8, html, "<td>old") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "src, (Directory)").? < std.mem.indexOf(u8, html, "z.txt, (File)").?);
    try has(html, "view-all-files-row");
}
