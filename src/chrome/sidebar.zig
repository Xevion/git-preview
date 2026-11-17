//! Fills the repository sidebar's skeleton sections (Releases, Sponsors, Used by, Contributors,
//! Languages) the way GitHub's React sidebar renders its `_sidebar` data. Sections without data
//! are removed, as React renders nothing for them.

const std = @import("std");
const dom = @import("../html/dom.zig");
const template = @import("template.zig");
const markup = @import("markup.zig");
const octicons = @import("../render/octicons.zig");
const github = @import("../net/github.zig");
const Zone = @import("Zone.zig");
const Node = dom.Node;
const Writer = markup.Writer;
const escaped = markup.escaped;
const log = std.log.scoped(.chrome);

pub const Data = struct {
    sidebar: ?github.Sidebar,
    now: i64,
    zone: *const Zone,
};

pub fn fill(gpa: std.mem.Allocator, page: *template.Page, data: Data) !void {
    const sections = try dom.findAll(gpa, page.root(), {}, isSection);
    defer gpa.free(sections);
    const counts = releaseCounts(page.source);
    for (sections) |node| {
        // Server-rendered sections (About) are complete; only skeletons wait for client data.
        if (dom.find(node, {}, isSkeleton) == null) continue;
        const heading = dom.find(node, {}, isHeading) orelse continue;
        const title = dom.firstText(heading) orelse continue;
        var out: Writer.Allocating = .init(gpa);
        defer out.deinit();
        var s: Section = .{ .page = page, .w = &out.writer, .data = data, .counts = counts };
        if (try s.render(title)) try page.replaceWith(node, out.written()) else dom.remove(node);
    }
}

fn isSection(_: void, n: *Node) bool {
    return dom.hasClassPrefix(n, "sidebarSection__");
}

fn isSkeleton(_: void, n: *Node) bool {
    return dom.hasClassPrefix(n, "prc-Skeleton");
}

fn isHeading(_: void, n: *Node) bool {
    return std.mem.eql(u8, dom.localName(n), "h2");
}

const Counts = struct { releases: u64 = 0, tags: u64 = 0 };

/// Release and tag counts live only in the page's embedded route payload (`"sections":{"releases":{...}}`).
fn releaseCounts(source: []const u8) Counts {
    const key = "\"releases\":{\"releaseCount\":";
    const at = std.mem.indexOf(u8, source, key) orelse return .{};
    const rest = source[at + key.len ..];
    const tags_key = "\"tagCount\":";
    const tags_at = std.mem.indexOf(u8, rest[0..@min(rest.len, 64)], tags_key) orelse return .{ .releases = leadingInt(rest) };
    return .{ .releases = leadingInt(rest), .tags = leadingInt(rest[tags_at + tags_key.len ..]) };
}

fn leadingInt(s: []const u8) u64 {
    var end: usize = 0;
    while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
    return std.fmt.parseInt(u64, s[0..end], 10) catch 0;
}

const Count = union(enum) { number: u64, text: []const u8 };

const Section = struct {
    page: *const template.Page,
    w: *Writer,
    data: Data,
    counts: Counts,

    fn cls(s: *const Section, stem: []const u8) []const u8 {
        return s.page.class(stem, "");
    }

    /// Returns false when GitHub would render nothing for this section.
    fn render(s: *Section, title: []const u8) !bool {
        const sb = s.data.sidebar orelse return false;
        if (std.mem.eql(u8, title, "Releases")) return s.releases(sb.releases orelse return false);
        if (std.mem.eql(u8, title, "Contributors")) return s.contributors(sb.contributors orelse return false);
        if (std.mem.eql(u8, title, "Languages")) return s.languages(sb.languages orelse return false);
        if (std.mem.eql(u8, title, "Used by")) return s.usedBy(sb.usedBy orelse return false);
        if (std.mem.eql(u8, title, "Sponsor this project")) return s.sponsors(sb.sponsors orelse return false);
        log.debug("sidebar section \"{s}\" not rendered", .{title});
        return false;
    }

    fn open(s: *Section, title: []const u8, href: ?[]const u8, count: ?Count) !void {
        const w = s.w;
        try w.print("<div class=\"{s}\"><h2 class=\"{s} {s}\" data-variant=\"small\" data-component=\"Heading\">", .{
            s.cls("sidebarSection"), s.page.classNear("sectionHeading", "headingLinkWrapper", ""), s.cls("prc-Heading-Heading"),
        });
        if (href) |h| {
            try w.print("<span class=\"{s}\"><a class=\"{s} {s}\" data-component=\"Link\" data-muted=\"true\" href=\"", .{
                s.cls("headingLinkWrapper"), s.cls("headingLink"), s.cls("prc-Link-Link"),
            });
            try markup.href(w, h);
            try w.print("\"><span>{s}</span></a>", .{title});
            if (count) |c| {
                var buf: Writer.Allocating = .init(s.page.gpa);
                defer buf.deinit();
                switch (c) {
                    .number => |n| try markup.grouped(&buf.writer, n),
                    .text => |t| try buf.writer.writeAll(t),
                }
                try w.print("<span aria-hidden=\"true\" data-variant=\"secondary\" data-component=\"CounterLabel\" class=\"ml-1 {s}\">{s}</span><span class=\"{s}\">&nbsp;({s})</span>", .{
                    s.cls("prc-CounterLabel-CounterLabel"), buf.written(), s.cls("prc-VisuallyHidden-VisuallyHidden"), buf.written(),
                });
            }
            try w.writeAll("</span>");
        } else try w.print("<span>{s}</span>", .{title});
        try w.writeAll("</h2>");
    }

    fn close(s: *Section, href: ?[]const u8, more: u64, label: []const u8) !void {
        if (more > 0) if (href) |h| {
            try s.w.print("<div class=\"{s}\"><a class=\"text-small {s}\" data-component=\"Link\" href=\"", .{
                s.page.classNear("moreLink", "headingLinkWrapper", ""), s.cls("prc-Link-Link"),
            });
            try markup.href(s.w, h);
            try s.w.writeAll("\"><span>+ ");
            try markup.grouped(s.w, more);
            try s.w.print(" {s}</span></a></div>", .{label});
        };
        try s.w.writeAll("</div>");
    }

    fn avatar(s: *Section, extra_class: []const u8, alt: []const u8, src: []const u8) !void {
        try s.w.print("<img data-component=\"Avatar\" class=\"{s}{s}\" alt=\"@", .{ extra_class, s.cls("prc-Avatar-Avatar") });
        try escaped(s.w, alt);
        try s.w.writeAll("\" width=\"32\" height=\"32\" data-testid=\"github-avatar\" src=\"");
        try escaped(s.w, src);
        try s.w.writeAll("\" style=\"--avatarSize-regular: 32px;\">");
    }

    fn link(s: *Section, class: []const u8, path: []const u8) !void {
        try s.w.print("<a class=\"{s}{s}\" data-component=\"Link\" href=\"", .{ class, s.cls("prc-Link-Link") });
        try markup.href(s.w, path);
        try s.w.writeAll("\">");
    }

    fn releases(s: *Section, r: github.Releases) !bool {
        const w = s.w;
        const n = s.counts.releases;
        if (r.latestRelease) |latest| {
            try s.open("Releases", r.releasesPath, if (n > 0) .{ .number = n } else null);
            try s.link(try s.prefixed("releaseLink"), latest.path);
            try markup.octicon(w, try s.joined("octicon octicon-release ", s.cls("releaseIconSuccess")), octicons.release);
            try w.print("<div class=\"{s}\"><div class=\"{s}\"><span class=\"{s} {s}\" title=\"", .{
                s.cls("releaseInfo"), s.cls("releaseNameRow"), s.cls("releaseName"), s.cls("prc-Truncate-Truncate"),
            });
            try escaped(w, latest.name);
            try w.writeAll("\" style=\"--truncate-max-width: none;\">");
            try escaped(w, latest.name);
            try w.print("</span><span class=\"{s} {s}\" data-size=\"small\" data-variant=\"success\" data-component=\"Label\">Latest</span></div><div class=\"{s}\">", .{
                s.cls("latestLabel"), s.cls("prc-Label-Label"), s.cls("releaseMeta"),
            });
            if (latest.publishedAt) |p| if (markup.parseIso(p)) |t| try markup.relativeTime(w, t, s.data.now, s.data.zone);
            try w.writeAll("</div></div></a>");
            try s.close(r.releasesPath, if (n > 1) n - 1 else 0, if (n == 2) "release" else "releases");
            return true;
        }
        try s.open("Releases", r.releasesPath, null);
        const tags = s.counts.tags;
        if (tags > 0) {
            try s.link(try s.prefixed("tagsLink"), r.tagsPath);
            try markup.octicon(w, try s.joined("octicon octicon-tag ", s.cls("tagIconMuted")), octicons.tag);
            try w.print("<span class=\"{s}\">", .{s.cls("tagCount")});
            try markup.grouped(w, tags);
            try w.print("</span><span class=\"{s}\">{s}</span></a>", .{ s.cls("tagLabel"), if (tags == 1) "tag" else "tags" });
        } else {
            try w.print("<div class=\"{s}\"><span>No releases published</span></div>", .{s.page.classNear("emptyState", "tagsLink", "")});
        }
        try s.close(r.releasesPath, 0, "");
        return true;
    }

    fn contributors(s: *Section, c: github.Contributors) !bool {
        const w = s.w;
        if (c.contributorCount == 0) {
            try s.open("Contributors", null, null);
            try w.print("<div class=\"{s}\">No contributors</div>", .{s.page.classNear("emptyState", "avatarGrid", "")});
            try s.close(null, 0, "");
            return true;
        }
        const n = c.contributorCount;
        const limit: u64 = if (n < 14) n else if (n == 15) 15 else 14;
        const shown: usize = @intCast(@min(c.contributors.len, limit));
        try s.open("Contributors", c.contributorsPath, .{ .number = n });
        if (shown > 4) {
            try w.print("<ul class=\"{s}\">", .{s.cls("avatarGrid")});
            for (c.contributors[0..shown]) |p| {
                try w.print("<li class=\"{s}\">", .{s.cls("avatarGridItem")});
                try s.link("", p.profilePath);
                try s.avatar("", p.login, p.avatarUrl);
                try w.writeAll("</a></li>");
            }
        } else {
            try w.print("<ul class=\"{s}\">", .{s.cls("avatarList")});
            for (c.contributors[0..shown]) |p| {
                try w.print("<li class=\"{s}\">", .{s.cls("avatarListItem")});
                try s.link(try s.prefixed("avatarLink"), p.profilePath);
                try s.avatar("", p.login, p.avatarUrl);
                try w.print("</a><span class=\"{s} {s}\" title=\"", .{ s.cls("contributorName"), s.cls("prc-Truncate-Truncate") });
                try escaped(w, p.login);
                if (p.profileName) |name| {
                    try w.writeByte(' ');
                    try escaped(w, name);
                }
                try w.writeAll("\" style=\"--truncate-max-width: none;\">");
                try s.link(try s.joined(s.page.classNear("nameLink", "avatarGrid", ""), " "), p.profilePath);
                try w.writeAll("<strong>");
                try escaped(w, p.login);
                try w.writeAll("</strong>");
                if (p.profileName) |name| {
                    try w.print("<span class=\"{s}\">", .{s.cls("profileName")});
                    try escaped(w, name);
                    try w.writeAll("</span>");
                }
                try w.writeAll("</a></span></li>");
            }
        }
        try w.writeAll("</ul>");
        try s.close(c.contributorsPath, n - shown, if (n - shown == 1) "contributor" else "contributors");
        return true;
    }

    fn languages(s: *Section, l: github.Languages) !bool {
        if (l.languages.len == 0) return false;
        const w = s.w;
        try s.open("Languages", null, null);
        try w.print("<div class=\"mb-2\"><span data-component=\"ProgressBar\" class=\"{s}\" data-progress-display=\"block\" data-progress-bar-size=\"default\">", .{s.cls("prc-ProgressBar-ProgressBarContainer")});
        for (l.languages) |lang| {
            try w.print("<span data-component=\"ProgressBar.Item\" class=\"{s}\" role=\"progressbar\" aria-label=\"", .{s.cls("prc-ProgressBar-ProgressBarItem")});
            try escaped(w, lang.name orelse "Other");
            try w.print(": {d}%\" aria-valuenow=\"{d}\" aria-valuemin=\"0\" aria-valuemax=\"100\" style=\"--progress-width: {d}%; --progress-bg: var(--bgColor-success-emphasis);", .{
                lang.percentage, @as(i64, @intFromFloat(@round(lang.percentage))), lang.percentage,
            });
            try s.background(lang.color);
            try w.writeAll("\"></span>");
        }
        try w.print("</span></div><ul class=\"{s}\">", .{s.cls("languageList")});
        for (l.languages) |lang| {
            try w.print("<li class=\"{s}\">", .{s.cls("languageListItem")});
            const name = lang.name orelse "Other";
            if (l.isFork or lang.name == null) {
                try w.print("<span class=\"{s}\">", .{s.cls("languageItem")});
            } else {
                try w.print("<a class=\"{s} {s}\" data-component=\"Link\" href=\"https://github.com/", .{ s.cls("languageLink"), s.cls("prc-Link-Link") });
                try escaped(w, l.ownerLogin);
                try w.writeByte('/');
                try escaped(w, l.repoName);
                try w.writeAll("/search?l=");
                try markup.uriComponent(w, lang.searchAlias orelse name);
                try w.writeAll("\">");
            }
            try w.print("<span class=\"{s}\" style=\"", .{s.cls("languageDot")});
            try s.background(lang.color);
            try w.print("\"></span><span class=\"{s}\" itemprop=\"keywords\">", .{s.cls("languageName")});
            try escaped(w, name);
            try w.print("</span><span>{d}%</span>", .{lang.percentage});
            try w.writeAll(if (l.isFork or lang.name == null) "</span></li>" else "</a></li>");
        }
        try w.writeAll("</ul>");
        try s.close(null, 0, "");
        return true;
    }

    fn background(s: *Section, color: ?[]const u8) !void {
        const c = color orelse return;
        try s.w.writeAll(" background-color: ");
        try escaped(s.w, c);
        try s.w.writeByte(';');
    }

    fn usedBy(s: *Section, u: github.UsedBy) !bool {
        if (u.dependentCount == 0 or u.dependents.len == 0) return false;
        const w = s.w;
        var buf: [16]u8 = undefined;
        try s.open("Used by", u.dependentsPath, .{ .text = markup.compact(&buf, u.dependentCount) });
        const shown = u.dependents[0..@min(u.dependents.len, 5)];
        try s.link(try s.prefixed("avatarRow"), u.dependentsPath);
        try w.print("<span data-component=\"AvatarStack\" data-variant=\"stack\" data-shape=\"circle\" data-avatar-count=\"{s}\" data-responsive=\"\" class=\"pc-AvatarStack--variant pc-AvatarStack--shape{s} {s}\" style=\"--stackSize-narrow: 32px; --stackSize-regular: 32px; --stackSize-wide: 32px;\"><div data-component=\"AvatarStack.Body\" data-disable-expand=\"\" class=\"pc-AvatarStack--disableExpand pc-AvatarStackBody {s}\"> ", .{
            switch (shown.len) {
                1 => "1",
                2 => "2",
                else => "3+",
            },
            if (shown.len >= 3) " pc-AvatarStack--three-plus" else "",
            s.cls("prc-AvatarStack-AvatarStack"),
            s.cls("prc-AvatarStack-AvatarStackBody"),
        });
        for (shown) |d| try s.avatar(try s.joined("pc-AvatarItem ", try s.joined(s.cls("prc-AvatarStack-AvatarItem"), " ")), d.ownerLogin, d.avatarUrl);
        try w.writeAll("</div></span>");
        if (u.dependentCount > shown.len) {
            try w.print("<span class=\"{s}\">+ ", .{s.cls("moreCount")});
            try markup.grouped(w, u.dependentCount - shown.len);
            try w.writeAll("</span>");
        }
        try w.writeAll("</a>");
        try s.close(null, 0, "");
        return true;
    }

    fn sponsors(s: *Section, sp: github.Sponsors) !bool {
        const w = s.w;
        try s.open("Sponsor this project", null, null);
        const list = s.cls("sponsorList");
        const item = s.cls("sponsorItem");
        if (sp.sponsorables.len > 0) {
            try w.print("<ul class=\"{s}\">", .{list});
            for (sp.sponsorables) |p| {
                try w.print("<li class=\"{s}\">", .{item});
                try s.link("", p.profilePath);
                try s.avatar("", p.login, p.avatarUrl);
                try w.print("</a><span class=\"{s}\">", .{s.cls("sponsorName")});
                try s.link(try s.joined(s.page.classNear("nameLink", "sponsorList", ""), " "), p.profilePath);
                try w.writeAll("<strong>");
                try escaped(w, p.login);
                try w.writeAll("</strong></a>");
                if (p.displayName) |name| {
                    try w.print("<span class=\"{s}\">", .{s.cls("displayName")});
                    try escaped(w, name);
                    try w.writeAll("</span>");
                }
                try w.print("</span><a data-component=\"IconButton\" type=\"button\" href=\"https://github.com/sponsors/", .{});
                try escaped(w, p.login);
                try w.print("\" class=\"{s} {s} {s}\" data-loading=\"false\" data-no-visuals=\"true\" data-size=\"small\" data-variant=\"default\" aria-label=\"Sponsor @", .{
                    s.cls("prc-Button-ButtonBase"), s.cls("sponsorButton"), s.cls("prc-Button-IconButton"),
                });
                try escaped(w, p.login);
                try w.writeAll("\">");
                try markup.octicon(w, "octicon octicon-heart", octicons.heart);
                try w.writeAll("</a></li>");
            }
            try w.writeAll("</ul>");
        }
        if (sp.externalFundingLinks.len > 0) {
            try w.print("<ul class=\"{s}\">", .{list});
            for (sp.externalFundingLinks) |f| {
                try w.print("<li class=\"{s}\"><span class=\"{s}\">", .{ item, s.cls("fundingIcon") });
                if (f.iconUrl) |icon| {
                    try w.print("<img width=\"32\" height=\"32\" alt=\"\" aria-hidden=\"true\" class=\"{s}\" src=\"", .{s.cls("platformIcon")});
                    try escaped(w, icon);
                    try w.writeAll("\">");
                } else try markup.octicon(w, "octicon octicon-link", octicons.link);
                try w.print("</span><span class=\"{s}\"><a class=\"{s}\" data-component=\"Link\" href=\"", .{ s.cls("fundingName"), s.cls("prc-Link-Link") });
                try escaped(w, f.url);
                try w.writeAll("\" target=\"_blank\" rel=\"noopener noreferrer\">");
                try escaped(w, f.label orelse f.platform);
                try w.writeAll("</a></span></li>");
            }
            try w.writeAll("</ul>");
        }
        if ((sp.sponsorableCount orelse sp.sponsorables.len) > 0) {
            try w.print("<div class=\"{s}\"><a class=\"{s}\" data-component=\"Link\" data-inline=\"true\" href=\"", .{ s.cls("learnMore"), s.cls("prc-Link-Link") });
            try markup.href(w, sp.sponsorsLearnMorePath orelse sp.sponsorsPath);
            try w.writeAll("\"><span>Learn more about GitHub Sponsors</span></a></div>");
        }
        try s.close(null, 0, "");
        return true;
    }

    /// `stem`'s hashed class followed by a space, for class lists that continue with `prc-Link-Link`.
    fn prefixed(s: *Section, stem: []const u8) ![]const u8 {
        return s.joined(s.cls(stem), " ");
    }

    fn joined(s: *Section, a: []const u8, b: []const u8) ![]const u8 {
        return std.fmt.allocPrint(s.page.gpa, "{s}{s}", .{ a, b });
    }
};

test "fills sidebar sections from GitHub's sidebar data" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var fetcher: @import("../net/Fetcher.zig") = .init(gpa, std.testing.io, &env, true);
    defer fetcher.deinit();

    const skeleton = "<div class=\"sidebarSection__oqw6Y8\"><h2><span>{s}</span></h2><div class=\"prc-Skeleton-skeleton-Hkezl\"></div></div>";
    var page = try template.parse(arena, &fetcher, "<html><head><style>.sidebarSection__oqw6Y8{}.avatarGrid___nXATx{}.emptyState__4RNm3Z{}</style></head><body>" ++
        "<div class=\"sidebarSection__oqw6Y8\"><h2>About</h2><p>kept</p></div>" ++
        std.fmt.comptimePrint(skeleton, .{"Releases"}) ++ std.fmt.comptimePrint(skeleton, .{"Packages"}) ++
        std.fmt.comptimePrint(skeleton, .{"Contributors"}) ++ std.fmt.comptimePrint(skeleton, .{"Languages"}) ++
        "<script type=\"application/json\">{\"sections\":{\"releases\":{\"releaseCount\":0,\"tagCount\":1234}}}</script></body></html>");
    defer page.deinit();

    const people = [_]github.Person{
        .{ .login = "a", .profileName = "Ann <A>", .profilePath = "/a", .avatarUrl = "https://x/a" },
        .{ .login = "b[bot]", .profilePath = "/b[bot]", .avatarUrl = "https://x/b" },
    };
    const langs = [_]github.Language{
        .{ .name = "C++", .percentage = 86.7, .color = "#f34b7d", .searchAlias = "c++" },
        .{ .name = "Other", .percentage = 13.3, .color = "#ededed" },
    };
    try fill(arena, &page, .{
        .sidebar = .{
            .releases = .{ .releasesPath = "/o/r/releases", .tagsPath = "/o/r/tags" },
            .contributors = .{ .contributorCount = 2, .contributors = &people, .contributorsPath = "/o/r/graphs/contributors" },
            .languages = .{ .languages = &langs, .ownerLogin = "o", .repoName = "r" },
        },
        .now = 0,
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
    try has(html, ">1,234</span><span class=\"\">tags</span>");
    try std.testing.expect(std.mem.indexOf(u8, html, "Packages") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "prc-Skeleton") == null);
    try has(html, "<p>kept</p>");
    try has(html, "title=\"a Ann &lt;A&gt;\"");
    try has(html, "&nbsp;(2)");
    try has(html, "href=\"https://github.com/o/r/search?l=c%2B%2B\"");
    try has(html, "aria-label=\"C++: 86.7%\" aria-valuenow=\"87\"");
    try has(html, "<span>13.3%</span>");
}
