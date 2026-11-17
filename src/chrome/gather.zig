//! Collects what the repository home page shows: the file table and history from the local
//! repository, and account, checks and sidebar data from GitHub.

const std = @import("std");
const Repo = @import("../repo/Repo.zig");
const github = @import("../net/github.zig");
const home = @import("home.zig");
const Zone = @import("Zone.zig");
const log = std.log.scoped(.chrome);

pub const Source = struct {
    repo: *const Repo,
    /// The commit being previewed.
    oid: Repo.Oid,
    /// The `--rev` argument, shown as the ref when given.
    rev: ?[]const u8,
    /// Remote name from `--remote`, or null for origin / the sole remote.
    remote_name: ?[]const u8,
    /// `owner/name` on GitHub.
    repo_path: []const u8,
};

pub fn homeData(arena: std.mem.Allocator, io: std.Io, src: Source, web: *const github.Web, api: *github.Api, zone: *const Zone, now: i64) !home.Data {
    const repo = src.repo;
    var hex: [Repo.Oid.max_hex_len]u8 = undefined;
    const branch = try repo.headBranch(arena, io);
    const ref = src.rev orelse branch orelse try arena.dupe(u8, src.oid.hex(&hex)[0..7]);
    const head = try repo.commitInfo(arena, io, src.oid);

    var data: home.Data = .{
        .repo_path = src.repo_path,
        .ref = ref,
        .commit_count = try repo.commitCount(arena, io, src.oid),
        .head = head,
        .entries = try entries(arena, io, repo, src.oid),
        .now = now,
        .zone = zone,
        .ref_counts = web.refCounts().get(),
        .branch_info = if (branch) |b| web.branchInfo(b).get() else null,
    };

    switch (web.latestCommit(head.oid.hex(&hex))) {
        .ok => |lc| {
            data.author = lc.author;
            data.status = lc.status;
        },
        // Unpushed: borrow the account from the newest pushed commit by the same author.
        .missing => data.author = try pushedAuthor(arena, io, src, web, branch, head.author_email),
        .failed => data.author = api.commitAuthor(arena, src.repo_path, head.oid.hex(&hex)) catch |err| blk: {
            log.warn("commit author unavailable: {s}", .{@errorName(err)});
            break :blk null;
        },
    }
    return data;
}

fn pushedAuthor(arena: std.mem.Allocator, io: std.Io, src: Source, web: *const github.Web, branch: ?[]const u8, email: []const u8) !?github.Author {
    const tip = try src.repo.remoteTip(arena, io, src.remote_name, branch) orelse return null;
    const pushed = try src.repo.newestByAuthor(arena, io, tip, email, 1000) orelse return null;
    var hex: [Repo.Oid.max_hex_len]u8 = undefined;
    const lc = web.latestCommit(pushed.hex(&hex)).get() orelse return null;
    return lc.author;
}

/// The root's entries with their last commits, directory chains collapsed and submodules resolved.
fn entries(arena: std.mem.Allocator, io: std.Io, repo: *const Repo, oid: Repo.Oid) ![]home.Entry {
    const tree = try repo.listTree(arena, io, oid, "");
    const commits = try repo.lastCommits(arena, io, oid, "");
    const modules = try submodules(arena, io, repo, oid);
    const out = try arena.alloc(home.Entry, tree.len);
    for (tree, out) |t, *e| {
        const commit = for (commits) |pc| {
            if (std.mem.eql(u8, pc.name, t.name)) break pc.commit;
        } else return error.MissingLastCommit;
        e.* = .{ .name = t.name, .kind = t.kind, .commit = commit };
        if (t.kind == .directory) e.name = try collapse(arena, io, repo, oid, t.name);
        if (t.kind == .submodule) {
            var hex: [Repo.Oid.max_hex_len]u8 = undefined;
            const short = t.oid.hex(&hex)[0..7];
            const url = for (modules) |m| {
                if (std.mem.eql(u8, m.path, t.name)) break webUrl(arena, m.url, t.oid.hex(&hex)) catch null;
            } else null;
            e.submodule = .{ .display = try std.fmt.allocPrint(arena, "{s} @ {s}", .{ t.name, short }), .url = url };
        }
    }
    return out;
}

/// GitHub shows `a/b/c` for a directory whose only entry is a directory, down to the first that is not.
fn collapse(arena: std.mem.Allocator, io: std.Io, repo: *const Repo, oid: Repo.Oid, dir: []const u8) ![]const u8 {
    var path = dir;
    while (true) {
        const children = try repo.listTree(arena, io, oid, path);
        if (children.len != 1 or children[0].kind != .directory) return path;
        path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ path, children[0].name });
    }
}

const Module = struct { path: []const u8, url: []const u8 };

/// `path` and `url` of each `[submodule]` section in the commit's `.gitmodules`.
fn submodules(arena: std.mem.Allocator, io: std.Io, repo: *const Repo, oid: Repo.Oid) ![]Module {
    const text = repo.readPath(arena, io, oid, ".gitmodules") catch return &.{};
    return parseGitmodules(arena, text);
}

fn parseGitmodules(arena: std.mem.Allocator, text: []const u8) ![]Module {
    var out: std.ArrayList(Module) = .empty;
    var cur: Module = .{ .path = "", .url = "" };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "[")) {
            if (cur.path.len > 0 and cur.url.len > 0) try out.append(arena, cur);
            cur = .{ .path = "", .url = "" };
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\"");
        if (std.mem.eql(u8, key, "path")) cur.path = value;
        if (std.mem.eql(u8, key, "url")) cur.url = value;
    }
    if (cur.path.len > 0 and cur.url.len > 0) try out.append(arena, cur);
    return out.toOwnedSlice(arena);
}

/// The submodule's page at `sha` for URLs that name a web host (`https://`, `git@host:`, `ssh://`).
fn webUrl(arena: std.mem.Allocator, url: []const u8, sha: []const u8) !?[]const u8 {
    var rest = url;
    var host: []const u8 = undefined;
    if (std.mem.startsWith(u8, rest, "https://") or std.mem.startsWith(u8, rest, "http://") or std.mem.startsWith(u8, rest, "ssh://")) {
        rest = rest[std.mem.indexOf(u8, rest, "://").? + 3 ..];
        if (std.mem.indexOfScalar(u8, rest, '@')) |at| rest = rest[at + 1 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        host = rest[0..slash];
        if (std.mem.indexOfScalar(u8, host, ':')) |colon| host = host[0..colon];
        rest = rest[slash + 1 ..];
    } else if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
        const colon = std.mem.indexOfScalarPos(u8, rest, at, ':') orelse return null;
        host = rest[at + 1 .. colon];
        rest = rest[colon + 1 ..];
    } else return null;
    if (std.mem.endsWith(u8, rest, ".git")) rest = rest[0 .. rest.len - 4];
    rest = std.mem.trim(u8, rest, "/");
    if (rest.len == 0) return null;
    return try std.fmt.allocPrint(arena, "https://{s}/{s}/tree/{s}", .{ host, rest, sha });
}

test "reads submodules and turns their URLs into pages" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const mods = try parseGitmodules(arena,
        \\[submodule "vendor/lib"]
        \\    path = vendor/lib
        \\    url = git@github.com:acme/lib.git
        \\[submodule "docs"]
        \\    url = https://gitlab.com/acme/docs
        \\    path = docs
    );
    try std.testing.expectEqual(@as(usize, 2), mods.len);
    try std.testing.expectEqualStrings("vendor/lib", mods[0].path);
    try std.testing.expectEqualStrings("https://github.com/acme/lib/tree/abc", (try webUrl(arena, mods[0].url, "abc")).?);
    try std.testing.expectEqualStrings("https://gitlab.com/acme/docs/tree/abc", (try webUrl(arena, mods[1].url, "abc")).?);
    try std.testing.expectEqualStrings("https://example.com/a/b/tree/abc", (try webUrl(arena, "ssh://git@example.com:2222/a/b.git", "abc")).?);
    try std.testing.expect(try webUrl(arena, "../sibling.git", "abc") == null);
}
