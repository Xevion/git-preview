//! Fills a repository home page template with local data (branch, commit count, latest commit, file
//! table) and GitHub's view of it (author account, checks, branch and tag counts), replacing the
//! skeletons GitHub's scripts would fill.

const std = @import("std");
const c = @import("lexbor");
const dom = @import("../html/dom.zig");
const template = @import("template.zig");
const markup = @import("markup.zig");
const octicons = @import("../render/octicons.zig");
const github = @import("../net/github.zig");
const Repo = @import("../repo/Repo.zig");
const Zone = @import("Zone.zig");
const Node = dom.Node;
const Writer = markup.Writer;
const escaped = markup.escaped;
const log = std.log.scoped(.chrome);

pub const Entry = struct {
    /// The entry's name, or `a/b/c` when GitHub skips through directories holding a single directory.
    name: []const u8,
    kind: Repo.EntryKind,
    commit: Repo.Commit,
    submodule: ?Submodule = null,
};

pub const Submodule = struct {
    /// `name @ 1a2b3c4`.
    display: []const u8,
    /// The submodule repository at the pinned commit, when its URL is a web URL.
    url: ?[]const u8,
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
    /// The GitHub account behind `head`'s author, when GitHub knows the commit or one like it.
    author: ?github.Author = null,
    /// `head`'s checks rollup, only when GitHub has seen `head` itself.
    status: ?[]const u8 = null,
    ref_counts: ?github.RefCounts = null,
    /// A fork's comparison with its upstream; its bar is dropped without one.
    branch_info: ?github.BranchInfo = null,
};

pub fn fill(gpa: std.mem.Allocator, page: *template.Page, data: Data) !void {
    setBranch(page, data.ref);
    if (data.ref_counts) |counts| try setRefCounts(gpa, page, counts);
    try setBranchInfo(gpa, page, data);
    try setCommitCount(gpa, page, data);
    try setLatestCommit(gpa, page, data);
    try setRows(gpa, page, data);
}

fn setText(node: *Node, text: []const u8) void {
    _ = c.lxb_dom_node_text_content_set(node, text.ptr, text.len);
}

fn setBranch(page: *template.Page, ref: []const u8) void {
    const label = dom.find(page.root(), {}, struct {
        fn pred(_: void, n: *Node) bool {
            return dom.hasClassPrefix(n, "RefSelectorText__");
        }
    }.pred) orelse return log.warn("template has no branch selector", .{});
    setText(label, ref);
}

/// The "Branches" and "Tags" buttons, which GitHub's scripts prefix with counts.
fn setRefCounts(gpa: std.mem.Allocator, page: *template.Page, counts: github.RefCounts) !void {
    const Kind = struct { suffix: []const u8, n: u64, one: []const u8, many: []const u8 };
    const kinds = [_]Kind{
        .{ .suffix = "/branches", .n = counts.branches, .one = "Branch", .many = "Branches" },
        .{ .suffix = "/tags", .n = counts.tags, .one = "Tag", .many = "Tags" },
    };
    for (kinds) |k| {
        const button = dom.find(page.root(), k.suffix, struct {
            fn pred(suffix: []const u8, n: *Node) bool {
                if (!std.mem.eql(u8, dom.localName(n), "a")) return false;
                const el: *dom.Element = @ptrCast(n);
                const href = dom.getAttr(el, "href") orelse return false;
                return std.mem.endsWith(u8, href, suffix) and dom.hasAttr(el, "data-component") and !dom.hasAttr(el, "aria-label");
            }
        }.pred) orelse continue;
        const label = dom.find(button, {}, struct {
            fn pred(_: void, n: *Node) bool {
                return dom.hasClassPrefix(n, "prc-Button-Label-");
            }
        }.pred) orelse continue;
        const html = try std.fmt.allocPrint(gpa, "<span><strong class=\"color-fg-default\">{d} </strong>{s}</span>", .{ k.n, if (k.n == 1) k.one else k.many });
        defer gpa.free(html);
        try page.setInnerHtml(label, html);
    }
}

/// The fork bar: "This branch is N commits ahead of and M commits behind upstream:branch."
fn setBranchInfo(gpa: std.mem.Allocator, page: *template.Page, data: Data) !void {
    const bar = template.byTestId(page, "branch-info-bar") orelse return;
    const info = data.branch_info orelse return dom.remove(bar);
    const cmp = info.refComparison orelse return dom.remove(bar);
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    const link = page.class("prc-Link-Link", "");
    const Side = struct {
        fn compare(o: *Writer, repo: []const u8, base: []const u8, head: []const u8, cls: []const u8, n: u64, what: []const u8) !void {
            try o.print("<a class=\"{s}\" data-component=\"Link\" href=\"https://github.com/{s}/compare/", .{ cls, repo });
            try markup.uriComponent(o, base);
            try o.writeAll("...");
            try markup.uriComponent(o, head);
            try o.print("\">{d} commit{s} {s}</a>", .{ n, if (n == 1) "" else "s", what });
        }
    };
    try w.writeAll("<span>");
    if (cmp.ahead == 0 and cmp.behind == 0) {
        try w.writeAll("This branch is up to date with ");
    } else {
        try w.writeAll("This branch is ");
        if (cmp.ahead > 0) try Side.compare(w, data.repo_path, cmp.baseBranchRange, cmp.currentRef, link, cmp.ahead, "ahead of");
        if (cmp.ahead > 0 and cmp.behind > 0) try w.writeAll(" and ");
        if (cmp.behind > 0) try Side.compare(w, data.repo_path, cmp.currentRef, cmp.baseBranchRange, link, cmp.behind, "behind");
        try w.writeByte(' ');
    }
    try w.print("<span class=\"{s}\" data-component=\"BranchName\">", .{page.class("prc-BranchName-BranchName", "branch-name")});
    try escaped(w, cmp.baseBranch);
    try w.writeAll("</span>.</span>");
    if (info.pullRequestNumber) |pr| {
        try w.print("<div class=\"d-flex gap-2\"><a class=\"{s} {s}\" data-component=\"Link\" href=\"https://github.com/{s}/pull/{d}\">", .{
            page.classNear("Link", "branchInfoBarBase", ""), link, data.repo_path, pr,
        });
        try markup.octicon(w, "octicon octicon-git-pull-request", octicons.git_pull_request);
        try w.print("#{d}</a></div>", .{pr});
    }
    try page.setInnerHtml(bar, out.written());
}

fn setCommitCount(gpa: std.mem.Allocator, page: *template.Page, data: Data) !void {
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
            return dom.hasClassPrefix(n, "fgColor-default");
        }
    }.pred) orelse return;
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try markup.grouped(&out.writer, data.commit_count);
    try out.writer.print(" Commit{s}", .{if (data.commit_count == 1) "" else "s"});
    setText(label, out.written());
    const href = try std.fmt.allocPrint(gpa, "https://github.com/{s}/commits/{s}/", .{ data.repo_path, data.ref });
    defer gpa.free(href);
    dom.setAttr(@ptrCast(link), "href", href);
}

fn commitHref(w: *Writer, data: Data, commit: Repo.Commit) !void {
    var hex: [Repo.Oid.max_hex_len]u8 = undefined;
    try w.print("https://github.com/{s}/commit/{s}", .{ data.repo_path, commit.oid.hex(&hex) });
}

fn summaryLinks(w: *Writer, data: Data, commit: Repo.Commit, with_title: bool) !void {
    var url: [256]u8 = undefined;
    var fixed: Writer = .fixed(&url);
    try commitHref(&fixed, data, commit);
    try markup.commitSummary(w, data.repo_path, fixed.buffered(), commit.summary, with_title);
}

/// The checks badge's icon and color per rollup state, as GitHub's `ChecksStatusBadge` maps them.
fn statusIcon(status: []const u8) ?struct { name: []const u8, body: []const u8, color: []const u8 } {
    if (std.mem.eql(u8, status, "success")) return .{ .name = "check", .body = octicons.check, .color = "var(--bgColor-success-emphasis, var(--color-success-emphasis))" };
    if (std.mem.eql(u8, status, "pending")) return .{ .name = "dot-fill", .body = octicons.dot_fill, .color = "var(--bgColor-attention-emphasis, var(--color-scale-yellow-4))" };
    if (std.mem.eql(u8, status, "failure")) return .{ .name = "x", .body = octicons.x, .color = "var(--bgColor-danger-emphasis, var(--color-scale-red-4))" };
    if (std.mem.eql(u8, status, "error")) return .{ .name = "question", .body = octicons.question, .color = "var(--fgColor-muted, var(--color-canvas-subtle))" };
    return null;
}

fn setLatestCommit(gpa: std.mem.Allocator, page: *template.Page, data: Data) !void {
    const loading = template.byTestId(page, "loading") orelse return log.warn("template has no latest-commit placeholder", .{});
    const head = data.head;
    var hex: [Repo.Oid.max_hex_len]u8 = undefined;
    const sha = head.oid.hex(&hex);

    var bar: Writer.Allocating = .init(gpa);
    defer bar.deinit();
    const w = &bar.writer;
    try w.print("<div data-testid=\"latest-commit\" class=\"{s}\"><div class=\"{s}\"><div data-testid=\"author-avatar\" class=\"{s}\">", .{
        page.classNear("Box_1", "ChecksStatusBadgeIconButton", "d-flex flex-items-center gap-2 min-width-0"),
        page.class("CommitAttributionContainer", "d-flex flex-items-center"),
        page.class("AuthorAvatarContainer", "d-flex flex-items-center gap-2"),
    });
    const author_style = "--author-font-weight: var(--base-text-weight-semibold); --author-font-color: var(--fgColor-default);";
    if (data.author) |a| {
        const name = a.login orelse a.displayName;
        if (a.path) |p| {
            try w.print("<a class=\"{s}\" data-component=\"Link\" href=\"", .{page.class("prc-Link-Link", "")});
            try markup.href(w, p);
            try w.writeAll("\" data-testid=\"avatar-icon-link\">");
        }
        try w.print("<img data-component=\"Avatar\" class=\"{s} {s}\" alt=\"", .{ page.class("authorAvatarImage", ""), page.class("prc-Avatar-Avatar", "avatar circle") });
        try escaped(w, name);
        try w.writeAll("\" width=\"20\" height=\"20\" data-testid=\"github-avatar\" aria-label=\"");
        try escaped(w, name);
        try w.writeAll("\" src=\"");
        try escaped(w, a.avatarUrl);
        try w.writeAll("\" style=\"--avatarSize-regular: 20px;\">");
        if (a.path != null) try w.writeAll("</a>");
        if (a.login) |login| {
            try w.print("<a class=\"{s} {s}\" data-component=\"Link\" href=\"https://github.com/{s}/commits?author=", .{ page.class("authorHoverableLink", ""), page.class("prc-Link-Link", ""), data.repo_path });
            try escaped(w, login);
            try w.writeAll("\" aria-label=\"commits by ");
            try escaped(w, login);
            try w.print("\" style=\"{s}\">", .{author_style});
            try escaped(w, login);
            try w.writeAll("</a>");
        } else try authorName(w, page, a.displayName, author_style);
    } else {
        // No GitHub account known: a neutral avatar so the name does not sit bare.
        try w.print("<span class=\"{s} {s}\" aria-hidden=\"true\" style=\"--avatarSize-regular: 20px; width: 20px; height: 20px; display: inline-flex; align-items: center; justify-content: center; background-color: var(--bgColor-neutral-muted); color: var(--fgColor-muted);\">", .{
            page.class("authorAvatarImage", ""), page.class("prc-Avatar-Avatar", "avatar circle"),
        });
        try w.print("<svg aria-hidden=\"true\" focusable=\"false\" class=\"octicon octicon-person\" viewBox=\"0 0 16 16\" width=\"12\" height=\"12\" fill=\"currentColor\">{s}</svg></span>", .{octicons.person});
        try authorName(w, page, head.author_name, author_style);
    }
    try w.print("</div><span class=\"\"></span></div><div class=\"d-none d-sm-flex {s}\"><div class=\"Truncate flex-items-center f5\"><span class=\"Truncate-text {s}\" data-component=\"Text\" data-testid=\"latest-commit-html\">", .{
        page.classNear("Box_2", "ChecksStatusBadgeIconButton", "flex-items-center min-width-0"), page.class("prc-Text-Text", ""),
    });
    try summaryLinks(w, data, head, false);
    try w.writeAll("</span></div>");
    if (head.has_body) {
        try w.print("<button data-component=\"IconButton\" type=\"button\" aria-pressed=\"false\" aria-expanded=\"false\" data-testid=\"latest-commit-details-toggle\" class=\"{s} {s} {s}\" data-loading=\"false\" data-no-visuals=\"true\" data-size=\"small\" data-variant=\"invisible\" aria-label=\"Open commit details\">", .{
            page.class("prc-Button-ButtonBase", ""), page.classNear("IconButton", "ChecksStatusBadgeIconButton", ""), page.class("prc-Button-IconButton", ""),
        });
        try markup.octicon(w, "octicon octicon-ellipsis", octicons.ellipsis);
        try w.writeAll("</button>");
    }
    if (data.status) |status| if (statusIcon(status)) |icon| {
        try w.print("<button data-component=\"IconButton\" type=\"button\" data-testid=\"checks-status-badge-icon\" class=\"{s} {s} {s}\" data-loading=\"false\" data-no-visuals=\"true\" data-size=\"small\" data-variant=\"invisible\" aria-label=\"{s}\" style=\"--checks-icon-color: {s};\">", .{
            page.class("prc-Button-ButtonBase", ""), page.class("ChecksStatusBadgeIconButton", ""), page.class("prc-Button-IconButton", ""), status, icon.color,
        });
        try markup.octicon(w, try std.fmt.allocPrint(gpa, "octicon octicon-{s}", .{icon.name}), icon.body);
        try w.writeAll("</button>");
    };
    try w.writeAll("</div><span class=\"d-flex d-sm-none fgColor-muted\">");
    try markup.relativeTime(w, head.commit_time, data.now, data.zone);
    try w.writeAll("</span></div>");
    // The skeleton's own box sized the placeholder; the bar takes its place.
    try page.replaceWith(loading, bar.written());

    if (template.byTestId(page, "latest-commit-details")) |d| {
        var info: Writer.Allocating = .init(gpa);
        defer info.deinit();
        try info.writer.print("<span class=\"d-flex flex-nowrap fgColor-muted f6\"><a class=\"Link--secondary {s}\" data-component=\"Link\" aria-label=\"Commit {s}\" href=\"", .{ page.class("prc-Link-Link", ""), sha[0..7] });
        try commitHref(&info.writer, data, head);
        try info.writer.print("\">{s}</a>&nbsp;·&nbsp;", .{sha[0..7]});
        try markup.relativeTime(&info.writer, head.commit_time, data.now, data.zone);
        try info.writer.writeAll("</span>");
        try page.setInnerHtml(d, info.written());
    }
}

fn authorName(w: *Writer, page: *const template.Page, name: []const u8, style: []const u8) !void {
    try w.print("<span class=\"{s}\" style=\"{s} font-weight: var(--base-text-weight-semibold); color: var(--fgColor-default);\">", .{ page.class("authorHoverableLink", ""), style });
    try escaped(w, name);
    try w.writeAll("</span>");
}

fn isRow(_: void, n: *Node) bool {
    return std.mem.eql(u8, dom.localName(n), "tr") and dom.hasClassPrefix(n, "react-directory-row");
}

fn isDirLike(kind: Repo.EntryKind) bool {
    return kind == .directory or kind == .submodule;
}

/// Directories first; within each group the input's git tree order is kept, as GitHub does.
fn entryOrder(_: void, a: Entry, b: Entry) bool {
    return isDirLike(a.kind) and !isDirLike(b.kind);
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

    var rows: Writer.Allocating = .init(gpa);
    defer rows.deinit();
    for (entries, 0..) |e, i| try writeRow(&rows.writer, data, e, i);
    // The first template row is the splice point, so the rows land where GitHub's were.
    try page.replaceWith(first, rows.written());
}

fn writeRow(w: *Writer, data: Data, e: Entry, i: usize) !void {
    const is_dir = isDirLike(e.kind);
    const icon_class, const icon, const type_label = switch (e.kind) {
        .directory => .{ "octicon octicon-file-directory-fill icon-directory", octicons.file_directory_fill, "Directory" },
        .submodule => .{ "octicon octicon-file-submodule icon-directory", octicons.file_submodule, "Submodule" },
        .symlink => .{ "octicon octicon-file-symlink-file icon-directory", octicons.file_symlink_file, "Symlink to file" },
        .file, .executable => .{ "octicon octicon-file color-fg-muted", octicons.file, "File" },
    };
    const collapsed = std.mem.indexOfScalar(u8, e.name, '/') != null;
    try w.print("<tr class=\"react-directory-row {s}\" id=\"folder-row-{d}\">", .{ if (i < 10) "undefined" else "truncate-for-mobile", i });
    inline for (.{ .{ "small", "2" }, .{ "large", "1" } }) |cell| {
        try w.print("<td class=\"react-directory-row-name-cell-{s}-screen\" colspan=\"{s}\"><div class=\"react-directory-filename-column\">", .{ cell[0], cell[1] });
        try markup.octicon(w, icon_class, icon);
        try w.writeAll("<div class=\"overflow-hidden\"><div class=\"react-directory-filename-cell\"><div class=\"react-directory-truncate\"><a title=\"");
        if (collapsed) try w.writeAll("This path skips through empty directories") else try escaped(w, e.name);
        try w.writeAll("\" aria-label=\"");
        try escaped(w, e.name);
        try w.print(", ({s})\"", .{type_label});
        if (e.kind != .symlink) try w.writeAll(" class=\"Link--primary\"");
        try w.writeAll(" href=\"");
        if (e.submodule) |s| if (s.url) |u| {
            try escaped(w, u);
        } else try entryHref(w, data, e, is_dir) else try entryHref(w, data, e, is_dir);
        try w.writeAll("\">");
        if (e.submodule) |s| {
            try w.writeAll("<span style=\"color:var(--fgColor-accent, var(--color-accent-fg))\">");
            try escaped(w, s.display);
            try w.writeAll("</span>");
        } else if (collapsed) {
            var parts = std.mem.splitScalar(u8, e.name, '/');
            while (parts.next()) |part| {
                const last = parts.peek() == null;
                try w.print("<span class=\"{s}\" data-testid=\"path-name-segment\">", .{if (last) "" else "react-directory-default-color"});
                try escaped(w, part);
                try w.writeAll(if (last) "</span>" else "/</span>");
            }
        } else try escaped(w, e.name);
        try w.writeAll("</a></div></div></div></div></td>");
    }
    try w.writeAll("<td class=\"react-directory-row-commit-cell\"><div><div class=\"react-directory-commit-message\">");
    try summaryLinks(w, data, e.commit, true);
    try w.writeAll("</div></div></td><td><div class=\"react-directory-commit-age\">");
    try markup.relativeTime(w, e.commit.commit_time, data.now, data.zone);
    try w.writeAll("</div></td></tr>");
}

fn entryHref(w: *Writer, data: Data, e: Entry, is_dir: bool) !void {
    try w.print("https://github.com/{s}/{s}/{s}/", .{ data.repo_path, if (is_dir) "tree" else "blob", data.ref });
    try escaped(w, e.name);
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
        \\<a data-component="Button" href="/o/r/branches"><span class="prc-Button-Label-FWkx3">Branches</span></a>
        \\<a data-component="Button" aria-label="Go to Tags page" href="/o/r/tags"></a>
        \\<a data-component="Button" href="/o/r/tags"><span class="prc-Button-Label-FWkx3">Tags</span></a>
        \\<div style="width:120px" class="Skeleton" data-testid="loading"> </div><div data-testid="latest-commit-details"></div>
        \\<a data-component="LinkButton" href="/o/r/commits/main/"><span class="fgColor-default">9 Commits</span></a>
        \\<table><tbody><tr class="react-directory-row undefined" id="folder-row-0"><td>old</td></tr>
        \\<tr class="react-directory-row undefined" id="folder-row-1"><td>old2</td></tr><tr data-testid="view-all-files-row"></tr></tbody></table>
        \\</body></html>
    );
    defer page.deinit();

    const oid = try Repo.Oid.parseHex("0123456789abcdef0123456789abcdef01234567");
    const commit: Repo.Commit = .{ .oid = oid, .summary = @constCast("fix: a <b>"), .author_name = @constCast("Ann"), .author_email = @constCast("a@x"), .author_time = 900, .commit_time = 1000, .has_body = true };
    try fill(arena, &page, .{
        .repo_path = "o/r",
        .ref = "dev",
        .commit_count = 1234,
        .head = commit,
        .entries = &.{
            .{ .name = "z.txt", .kind = .file, .commit = commit },
            .{ .name = "src/main", .kind = .directory, .commit = commit },
            .{ .name = "vendor", .kind = .submodule, .commit = commit, .submodule = .{ .display = "vendor @ 89abcde", .url = "https://github.com/v/v/tree/89abcde" } },
        },
        .now = 1000 + 2 * 86400,
        .zone = &Zone.utc,
        .status = "failure",
        .ref_counts = .{ .branches = 1, .tags = 52 },
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
    try has(html, ">1,234 Commits</span>");
    try has(html, "<strong class=\"color-fg-default\">1 </strong>Branch</span>");
    try has(html, "<strong class=\"color-fg-default\">52 </strong>Tags</span>");
    try has(html, "fix: a &lt;b&gt;</a>");
    try has(html, ">2 days ago</relative-time>");
    try has(html, ">0123456</a>");
    try has(html, "octicon-person");
    try has(html, ">Ann</span>");
    try has(html, "octicon octicon-x");
    try has(html, "latest-commit-details-toggle");
    try std.testing.expect(std.mem.indexOf(u8, html, "<td>old") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Skeleton") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "src/main, (Directory)").? < std.mem.indexOf(u8, html, "z.txt, (File)").?);
    try has(html, "title=\"This path skips through empty directories\"");
    try has(html, "react-directory-default-color\" data-testid=\"path-name-segment\">src/</span>");
    try has(html, "href=\"https://github.com/v/v/tree/89abcde\"");
    try has(html, "view-all-files-row");
}
