//! Read-only view of a git repository, parsed straight from `.git` with no subprocesses.
//!
//! Supported: SHA-1 object format, loose and packed objects, loose and packed refs,
//! linked worktrees (`commondir`), submodule-style `gitdir:` files, bare repositories.
//! Not supported: SHA-256 repositories, reftable ref storage, alternates, pack index v1,
//! config `include` directives, and revision syntax beyond names and hex ids (`~`, `^`, `@{}`).

const Repo = @This();

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const odb = @import("odb.zig");
const config = @import("config.zig");
const object = @import("object.zig");
const refs = @import("refs.zig");

pub const Oid = odb.Oid;
pub const EntryKind = object.EntryKind;

pub const Entry = struct {
    name: []u8,
    mode: u32,
    oid: Oid,
    kind: EntryKind,
};

/// Absolute path of the directory holding HEAD and per-worktree state.
git_dir: []u8,
/// Absolute path of the directory holding objects, shared refs and config; equals `git_dir` unless linked.
common_dir: []u8,
/// Absolute path of the checked-out tree, or null for bare repositories.
work_tree: ?[]u8,

const max_config_len = 16 << 20;
const max_packed_refs_len = 256 << 20;
const max_ref_len = 4096;

pub fn deinit(self: *Repo, gpa: Allocator) void {
    gpa.free(self.git_dir);
    gpa.free(self.common_dir);
    if (self.work_tree) |w| gpa.free(w);
    self.* = undefined;
}

pub fn freeEntries(gpa: Allocator, entries: []Entry) void {
    for (entries) |e| gpa.free(e.name);
    gpa.free(entries);
}

/// Walks up from `start_path` looking for `.git` (directory or `gitdir:` file) or a bare repository.
pub fn discover(gpa: Allocator, io: Io, start_path: []const u8) !Repo {
    const abs = try Dir.cwd().realPathFileAlloc(io, start_path, gpa);
    defer gpa.free(abs);
    const st = try Dir.cwd().statFile(io, abs, .{});
    var cur: []const u8 = if (st.kind == .directory)
        abs
    else
        std.fs.path.dirname(abs) orelse return error.NotARepository;

    while (true) {
        if (try probe(gpa, io, cur)) |repo| return repo;
        cur = std.fs.path.dirname(cur) orelse return error.NotARepository;
    }
}

fn statKind(io: Io, path: []const u8) !?Io.File.Kind {
    const st = Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    return st.kind;
}

fn isGitDir(gpa: Allocator, io: Io, path: []const u8, bare: bool) !bool {
    const head = try std.fs.path.join(gpa, &.{ path, "HEAD" });
    defer gpa.free(head);
    if ((try statKind(io, head)) != .file) return false;
    if (!bare) return true;
    for ([_][]const u8{ "objects", "refs" }) |name| {
        const p = try std.fs.path.join(gpa, &.{ path, name });
        defer gpa.free(p);
        if ((try statKind(io, p)) != .directory) return false;
    }
    return true;
}

fn probe(gpa: Allocator, io: Io, dir: []const u8) !?Repo {
    const dot_git = try std.fs.path.join(gpa, &.{ dir, ".git" });
    defer gpa.free(dot_git);
    switch (try statKind(io, dot_git) orelse .unknown) {
        .directory => if (try isGitDir(gpa, io, dot_git, false)) return try open(gpa, io, dot_git, dir),
        .file => {
            const raw = try readFileLimited(gpa, io, dot_git, max_ref_len) orelse return null;
            defer gpa.free(raw);
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            const target = std.mem.cutPrefix(u8, trimmed, "gitdir:") orelse return null;
            const rel = std.mem.trim(u8, target, " \t");
            const git_dir = if (std.fs.path.isAbsolute(rel))
                try gpa.dupe(u8, rel)
            else
                try std.fs.path.join(gpa, &.{ dir, rel });
            defer gpa.free(git_dir);
            return try open(gpa, io, git_dir, dir);
        },
        else => {},
    }
    if (try isGitDir(gpa, io, dir, true)) return try open(gpa, io, dir, null);
    return null;
}

fn canonical(gpa: Allocator, io: Io, path: []const u8) ![]u8 {
    const real = try Dir.cwd().realPathFileAlloc(io, path, gpa);
    defer gpa.free(real);
    return gpa.dupe(u8, real);
}

fn open(gpa: Allocator, io: Io, git_dir_path: []const u8, work_tree: ?[]const u8) !Repo {
    const git_dir = try canonical(gpa, io, git_dir_path);
    errdefer gpa.free(git_dir);

    const common_dir = if (try readFileIn(gpa, io, git_dir, "commondir", max_ref_len)) |raw| blk: {
        defer gpa.free(raw);
        const rel = std.mem.trim(u8, raw, " \t\r\n");
        if (std.fs.path.isAbsolute(rel)) break :blk try canonical(gpa, io, rel);
        const joined = try std.fs.path.join(gpa, &.{ git_dir, rel });
        defer gpa.free(joined);
        break :blk try canonical(gpa, io, joined);
    } else try gpa.dupe(u8, git_dir);
    errdefer gpa.free(common_dir);

    const wt = if (work_tree) |w| try gpa.dupe(u8, w) else null;
    return .{ .git_dir = git_dir, .common_dir = common_dir, .work_tree = wt };
}

fn readFileLimited(gpa: Allocator, io: Io, path: []const u8, limit: usize) !?[]u8 {
    return Dir.cwd().readFileAlloc(io, path, gpa, .limited(limit)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir => null,
        else => err,
    };
}

fn readFileIn(gpa: Allocator, io: Io, dir: []const u8, name: []const u8, limit: usize) !?[]u8 {
    const path = try std.fs.path.join(gpa, &.{ dir, name });
    defer gpa.free(path);
    return readFileLimited(gpa, io, path, limit);
}

fn loadConfig(self: *const Repo, arena: Allocator, io: Io) ![]config.Entry {
    const text = try readFileIn(arena, io, self.common_dir, "config", max_config_len) orelse return &.{};
    return config.parse(arena, text);
}

fn checkFormat(self: *const Repo, gpa: Allocator, io: Io) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (try self.loadConfig(arena.allocator(), io)) |e| {
        const value = e.value orelse continue;
        if (e.is("extensions", "objectformat") and !std.ascii.eqlIgnoreCase(value, "sha1"))
            return error.UnsupportedObjectFormat;
        if (e.is("extensions", "refstorage") and !std.ascii.eqlIgnoreCase(value, "files"))
            return error.UnsupportedRefStorage;
    }
}

/// Returns the fetch URL of remote `name`, or of `origin` / the sole remote when `name` is null.
pub fn remoteUrl(self: *const Repo, gpa: Allocator, io: Io, name: ?[]const u8) !?[]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const entries = try self.loadConfig(arena.allocator(), io);

    const url = if (name) |n|
        remoteUrlOf(entries, n) orelse return null
    else
        remoteUrlOf(entries, "origin") orelse (soleRemoteUrl(entries) orelse return null);
    return try applyInsteadOf(gpa, entries, url);
}

fn remoteUrlOf(entries: []const config.Entry, name: []const u8) ?[]const u8 {
    for (entries) |e| {
        if (!e.is("remote", "url")) continue;
        const sub = e.subsection orelse continue;
        if (std.mem.eql(u8, sub, name)) return e.value;
    }
    return null;
}

fn soleRemoteUrl(entries: []const config.Entry) ?[]const u8 {
    var only: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    for (entries) |e| {
        if (!e.is("remote", "url")) continue;
        const sub = e.subsection orelse continue;
        if (only) |o| {
            if (!std.mem.eql(u8, o, sub)) return null;
        } else {
            only = sub;
            url = e.value;
        }
    }
    return url;
}

fn applyInsteadOf(gpa: Allocator, entries: []const config.Entry, url: []const u8) ![]u8 {
    var best_base: []const u8 = "";
    var best_len: usize = 0;
    for (entries) |e| {
        if (!e.is("url", "insteadof")) continue;
        const base = e.subsection orelse continue;
        const prefix = e.value orelse continue;
        if (prefix.len > best_len and std.mem.startsWith(u8, url, prefix)) {
            best_base = base;
            best_len = prefix.len;
        }
    }
    if (best_len == 0) return gpa.dupe(u8, url);
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ best_base, url[best_len..] });
}

fn openOdb(self: *const Repo, gpa: Allocator, io: Io) !odb.Odb {
    try self.checkFormat(gpa, io);
    const path = try std.fs.path.join(gpa, &.{ self.common_dir, "objects" });
    defer gpa.free(path);
    const dir = try Dir.cwd().openDir(io, path, .{ .iterate = true });
    return odb.Odb.init(gpa, io, dir);
}

const RefValue = struct {
    oid: Oid,
    peeled: ?Oid = null,
};

fn lookupRef(self: *const Repo, gpa: Allocator, io: Io, start: []const u8) !?RefValue {
    var owned: ?[]u8 = null;
    defer if (owned) |o| gpa.free(o);
    var name = start;

    var depth: u8 = 0;
    while (depth < 8) : (depth += 1) {
        if (!refs.isSafeName(name)) return null;
        const base = if (refs.isPerWorktree(name)) self.git_dir else self.common_dir;
        if (try readFileIn(gpa, io, base, name, max_ref_len)) |raw| {
            defer gpa.free(raw);
            const content = std.mem.trim(u8, raw, " \t\r\n");
            if (std.mem.cutPrefix(u8, content, "ref:")) |target| {
                const next = try gpa.dupe(u8, std.mem.trim(u8, target, " \t"));
                if (owned) |o| gpa.free(o);
                owned = next;
                name = next;
                continue;
            }
            if (content.len < Oid.hex_len) return error.CorruptRef;
            return .{ .oid = Oid.parseHex(content[0..Oid.hex_len]) catch return error.CorruptRef };
        }
        const text = try readFileIn(gpa, io, self.common_dir, "packed-refs", max_packed_refs_len) orelse return null;
        defer gpa.free(text);
        const p = refs.findPacked(text, name) orelse return null;
        return .{ .oid = p.oid, .peeled = p.peeled };
    }
    return error.SymrefLoop;
}

fn peel(db: *const odb.Odb, gpa: Allocator, io: Io, oid: Oid) !Oid {
    var cur = oid;
    for (0..32) |_| {
        const obj = try db.read(gpa, io, cur);
        defer obj.deinit(gpa);
        if (obj.kind != .tag) return cur;
        cur = try object.tagTarget(obj.data);
    }
    return error.CorruptObject;
}

fn isHex(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

const rev_rules = [_][]const u8{
    "{s}",
    "refs/{s}",
    "refs/tags/{s}",
    "refs/heads/{s}",
    "refs/remotes/{s}",
    "refs/remotes/{s}/HEAD",
};

/// Resolves a ref name, full or unique-prefix hex id to a commit id, peeling annotated tags.
pub fn resolveRev(self: *const Repo, gpa: Allocator, io: Io, rev: []const u8) !Oid {
    var db = try self.openOdb(gpa, io);
    defer db.deinit(gpa, io);

    if (rev.len == Oid.hex_len) {
        if (Oid.parseHex(rev)) |oid| return peel(&db, gpa, io, oid) else |_| {}
    }

    if (refs.isSafeName(rev)) {
        inline for (rev_rules, 0..) |rule, i| {
            const usable = i != 0 or refs.isPseudoRef(rev) or std.mem.startsWith(u8, rev, "refs/");
            if (usable) {
                const candidate = try std.fmt.allocPrint(gpa, rule, .{rev});
                defer gpa.free(candidate);
                if (try self.lookupRef(gpa, io, candidate)) |v| {
                    return v.peeled orelse try peel(&db, gpa, io, v.oid);
                }
            }
        }
    }

    if (rev.len >= 4 and rev.len < Oid.hex_len and isHex(rev)) {
        const oid = db.resolvePrefix(io, rev) catch |err| switch (err) {
            error.ObjectNotFound => return error.RevisionNotFound,
            else => return err,
        };
        return peel(&db, gpa, io, oid);
    }
    return error.RevisionNotFound;
}

fn rootTree(db: *const odb.Odb, gpa: Allocator, io: Io, oid: Oid) !Oid {
    var cur = oid;
    for (0..32) |_| {
        const obj = try db.read(gpa, io, cur);
        defer obj.deinit(gpa);
        switch (obj.kind) {
            .tree => return cur,
            .commit => return object.commitTree(obj.data),
            .tag => cur = try object.tagTarget(obj.data),
            .blob => return error.NotACommit,
        }
    }
    return error.CorruptObject;
}

const Found = struct { oid: Oid, mode: u32 };

fn lookup(db: *const odb.Odb, gpa: Allocator, io: Io, root: Oid, path: []const u8) !Found {
    var cur: Found = .{ .oid = root, .mode = 0o040000 };
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (object.kindOfMode(cur.mode) != .directory) return error.PathNotFound;
        const tree = try db.read(gpa, io, cur.oid);
        defer tree.deinit(gpa);
        if (tree.kind != .tree) return error.CorruptObject;
        var it: object.TreeIterator = .{ .data = tree.data };
        cur = while (try it.next()) |item| {
            if (std.mem.eql(u8, item.name, part)) break .{ .oid = item.oid, .mode = item.mode };
        } else return error.PathNotFound;
    }
    return cur;
}

/// Returns the bytes of the blob at `path` in `commit`'s tree. Symlinks yield their target text.
/// Errors: `PathNotFound`, `IsDir` for a directory, `IsSubmodule` for a gitlink.
pub fn readPath(self: *const Repo, gpa: Allocator, io: Io, commit: Oid, path: []const u8) ![]u8 {
    var db = try self.openOdb(gpa, io);
    defer db.deinit(gpa, io);

    const found = try lookup(&db, gpa, io, try rootTree(&db, gpa, io, commit), path);
    switch (object.kindOfMode(found.mode)) {
        .directory => return error.IsDir,
        .submodule => return error.IsSubmodule,
        else => {},
    }
    const blob = try db.read(gpa, io, found.oid);
    errdefer blob.deinit(gpa);
    if (blob.kind != .blob) return error.CorruptObject;
    return blob.data;
}

/// Lists the entries of the directory at `dir_path` ("" for the root) in tree order.
/// Free the result with `freeEntries`. Errors: `PathNotFound`, `NotDir`.
pub fn listTree(self: *const Repo, gpa: Allocator, io: Io, commit: Oid, dir_path: []const u8) ![]Entry {
    var db = try self.openOdb(gpa, io);
    defer db.deinit(gpa, io);

    const found = try lookup(&db, gpa, io, try rootTree(&db, gpa, io, commit), dir_path);
    if (object.kindOfMode(found.mode) != .directory) return error.NotDir;
    const tree = try db.read(gpa, io, found.oid);
    defer tree.deinit(gpa);
    if (tree.kind != .tree) return error.CorruptObject;

    var list: std.ArrayList(Entry) = .empty;
    errdefer {
        for (list.items) |e| gpa.free(e.name);
        list.deinit(gpa);
    }
    var it: object.TreeIterator = .{ .data = tree.data };
    while (try it.next()) |item| {
        const name = try gpa.dupe(u8, item.name);
        errdefer gpa.free(name);
        try list.append(gpa, .{
            .name = name,
            .mode = item.mode,
            .oid = item.oid,
            .kind = object.kindOfMode(item.mode),
        });
    }
    return list.toOwnedSlice(gpa);
}

test {
    _ = odb;
    _ = config;
    _ = object;
    _ = refs;
}

const testing = std.testing;

const Fixture = struct {
    gpa: Allocator,
    io: Io,
    tmp: testing.TmpDir,
    root: []u8,
    repo_path: []u8,

    fn deinit(self: *Fixture) void {
        self.gpa.free(self.root);
        self.gpa.free(self.repo_path);
        self.tmp.cleanup();
    }

    fn run(self: *Fixture, cwd: []const u8, args: []const []const u8) ![]u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        try argv.appendSlice(self.gpa, &.{
            "git",                     "-c",                   "user.name=Test",             "-c",                "user.email=test@example.com",
            "-c",                      "commit.gpgsign=false", "-c",                         "tag.gpgsign=false", "-c",
            "init.defaultBranch=main", "-c",                   "protocol.file.allow=always",
        });
        try argv.appendSlice(self.gpa, args);
        const res = std.process.run(self.gpa, self.io, .{ .argv = argv.items, .cwd = .{ .path = cwd } }) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
        defer self.gpa.free(res.stderr);
        errdefer self.gpa.free(res.stdout);
        if (!res.term.success()) {
            std.debug.print("git failed ({any}): {s}\n", .{ args, res.stderr });
            return error.GitFailed;
        }
        return res.stdout;
    }

    fn git(self: *Fixture, args: []const []const u8) ![]u8 {
        return self.run(self.repo_path, args);
    }

    fn gitDiscard(self: *Fixture, args: []const []const u8) !void {
        self.gpa.free(try self.git(args));
    }

    fn rev(self: *Fixture, cwd: []const u8, name: []const u8) !Oid {
        const out = try self.run(cwd, &.{ "rev-parse", name });
        defer self.gpa.free(out);
        return Oid.parseHex(std.mem.trim(u8, out, " \r\n"));
    }

    fn writeRevision(self: *Fixture, i: usize) !void {
        const readme = try bigText(self.gpa, i, "readme");
        defer self.gpa.free(readme);
        const intro = try bigText(self.gpa, i + 100, "intro");
        defer self.gpa.free(intro);
        const small = try std.fmt.allocPrint(self.gpa, "revision {d}\n", .{i});
        defer self.gpa.free(small);
        try self.tmp.dir.writeFile(self.io, .{ .sub_path = "repo/README.md", .data = readme });
        try self.tmp.dir.writeFile(self.io, .{ .sub_path = "repo/docs/guide/intro.md", .data = intro });
        try self.tmp.dir.writeFile(self.io, .{ .sub_path = "repo/src/a.txt", .data = small });
    }

    fn commitRevision(self: *Fixture, i: usize) !void {
        try self.writeRevision(i);
        try self.gitDiscard(&.{ "add", "-A" });
        const msg = try std.fmt.allocPrint(self.gpa, "revision {d}", .{i});
        defer self.gpa.free(msg);
        try self.gitDiscard(&.{ "commit", "-q", "-m", msg });
    }
};

fn bigText(gpa: Allocator, rev: usize, tag: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..300) |line| {
        if (line == (rev * 41) % 300) {
            try out.print(gpa, "{s} changed in revision {d}\n", .{ tag, rev });
        } else {
            try out.print(gpa, "{s} line {d}: the quick brown fox jumps over the lazy dog\n", .{ tag, line });
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Five packed commits (with deltas), a packed annotated tag, then one loose commit on top.
fn setupFixture(gpa: Allocator, io: Io) !Fixture {
    var f: Fixture = .{ .gpa = gpa, .io = io, .tmp = testing.tmpDir(.{}), .root = undefined, .repo_path = undefined };
    errdefer f.tmp.cleanup();

    const real = try f.tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(real);
    f.root = try gpa.dupe(u8, real);
    errdefer gpa.free(f.root);
    f.repo_path = try std.fs.path.join(gpa, &.{ f.root, "repo" });
    errdefer gpa.free(f.repo_path);

    try f.tmp.dir.createDirPath(io, "repo/docs/guide");
    try f.tmp.dir.createDirPath(io, "repo/src");
    gpa.free(try f.run(f.root, &.{ "init", "-q", "repo" }));

    for (0..5) |i| {
        try f.commitRevision(i);
        if (i == 1) {
            try f.gitDiscard(&.{ "tag", "-a", "v1.0", "-m", "release one" });
            try f.gitDiscard(&.{ "tag", "light" });
        }
    }
    try f.gitDiscard(&.{ "branch", "feature", "HEAD~2" });
    try f.gitDiscard(&.{ "remote", "add", "origin", "https://example.com/acme/widget.git" });
    try f.gitDiscard(&.{ "gc", "-q", "--aggressive", "--prune=now" });

    const verify = try f.git(&.{ "count-objects", "-v" });
    defer gpa.free(verify);
    try testing.expect(std.mem.indexOf(u8, verify, "in-pack: 0") == null);

    try f.commitRevision(5);
    try f.gitDiscard(&.{ "update-ref", "refs/remotes/origin/main", "HEAD~1" });
    return f;
}

fn expectOid(expected: Oid, actual: Oid) !void {
    try testing.expectEqualStrings(&expected.toHex(), &actual.toHex());
}

test "fixture contains deltas" {
    const gpa = testing.allocator;
    var f = try setupFixture(gpa, testing.io);
    defer f.deinit();

    const packs = try f.git(&.{ "rev-parse", "--git-path", "objects/pack" });
    defer gpa.free(packs);
    const pack_dir = try std.fs.path.join(gpa, &.{ f.repo_path, std.mem.trim(u8, packs, "\n") });
    defer gpa.free(pack_dir);
    var dir = try Dir.cwd().openDir(f.io, pack_dir, .{ .iterate = true });
    defer dir.close(f.io);
    var it = dir.iterate();
    var verified = false;
    while (try it.next(f.io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
        const idx = try std.fs.path.join(gpa, &.{ pack_dir, entry.name });
        defer gpa.free(idx);
        const out = try f.git(&.{ "verify-pack", "-v", idx });
        defer gpa.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "chain length") != null);
        verified = true;
    }
    try testing.expect(verified);
}

test "resolveRev agrees with git" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try setupFixture(gpa, io);
    defer f.deinit();
    var repo = try Repo.discover(gpa, io, f.repo_path);
    defer repo.deinit(gpa);

    const cases = [_]struct { rev: []const u8, git_rev: []const u8 }{
        .{ .rev = "HEAD", .git_rev = "HEAD" },
        .{ .rev = "main", .git_rev = "main" },
        .{ .rev = "refs/heads/main", .git_rev = "refs/heads/main" },
        .{ .rev = "feature", .git_rev = "feature" },
        .{ .rev = "v1.0", .git_rev = "v1.0^{commit}" },
        .{ .rev = "refs/tags/v1.0", .git_rev = "v1.0^{commit}" },
        .{ .rev = "light", .git_rev = "light" },
        .{ .rev = "origin/main", .git_rev = "origin/main" },
    };
    for (cases) |c| {
        const want = try f.rev(f.repo_path, c.git_rev);
        try expectOid(want, try repo.resolveRev(gpa, io, c.rev));
    }

    const tag_object = try f.rev(f.repo_path, "v1.0");
    const commit = try f.rev(f.repo_path, "v1.0^{commit}");
    try testing.expect(!tag_object.eql(commit));
    try expectOid(commit, try repo.resolveRev(gpa, io, &tag_object.toHex()));

    for ([_][]const u8{ "HEAD", "HEAD~1", "feature", "v1.0^{commit}" }) |name| {
        const want = try f.rev(f.repo_path, name);
        const full = want.toHex();
        try expectOid(want, try repo.resolveRev(gpa, io, &full));
        try expectOid(want, try repo.resolveRev(gpa, io, full[0..10]));
        const short = try f.run(f.repo_path, &.{ "rev-parse", "--short=7", &full });
        defer gpa.free(short);
        try expectOid(want, try repo.resolveRev(gpa, io, std.mem.trim(u8, short, "\n")));
    }

    try testing.expectError(error.RevisionNotFound, repo.resolveRev(gpa, io, "nonexistent"));
    try testing.expectError(error.RevisionNotFound, repo.resolveRev(gpa, io, "0000000"));
    try testing.expectError(error.RevisionNotFound, repo.resolveRev(gpa, io, "../config"));
    try testing.expectError(error.RevisionNotFound, repo.resolveRev(gpa, io, "config"));
}

test "readPath and listTree agree with git across packed and loose objects" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try setupFixture(gpa, io);
    defer f.deinit();
    var repo = try Repo.discover(gpa, io, f.repo_path);
    defer repo.deinit(gpa);

    const log = try f.git(&.{ "rev-list", "HEAD" });
    defer gpa.free(log);
    var commits = std.mem.tokenizeScalar(u8, log, '\n');
    var n: usize = 0;
    while (commits.next()) |hex| : (n += 1) {
        const commit = try Oid.parseHex(hex);
        for ([_][]const u8{ "README.md", "docs/guide/intro.md", "src/a.txt" }) |path| {
            const spec = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ hex, path });
            defer gpa.free(spec);
            const want = try f.git(&.{ "show", spec });
            defer gpa.free(want);
            const got = try repo.readPath(gpa, io, commit, path);
            defer gpa.free(got);
            try testing.expectEqualSlices(u8, want, got);
        }

        for ([_][2][]const u8{ .{ "", "" }, .{ "docs", "docs" }, .{ "docs/guide", "docs/guide" }, .{ "/docs//guide/", "docs/guide" } }) |pair| {
            const dir = pair[0];
            const spec = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ hex, pair[1] });
            defer gpa.free(spec);
            const out = try f.git(&.{ "ls-tree", spec });
            defer gpa.free(out);
            const entries = try repo.listTree(gpa, io, commit, dir);
            defer freeEntries(gpa, entries);

            var lines = std.mem.tokenizeScalar(u8, out, '\n');
            var i: usize = 0;
            while (lines.next()) |line| : (i += 1) {
                const tab = std.mem.indexOfScalar(u8, line, '\t').?;
                var fields = std.mem.tokenizeScalar(u8, line[0..tab], ' ');
                const mode = try std.fmt.parseInt(u32, fields.next().?, 8);
                const kind = fields.next().?;
                try testing.expectEqual(mode, entries[i].mode);
                try testing.expectEqualStrings(line[tab + 1 ..], entries[i].name);
                try expectOid(try Oid.parseHex(fields.next().?), entries[i].oid);
                try testing.expectEqual(std.mem.eql(u8, kind, "tree"), entries[i].kind == .directory);
            }
            try testing.expectEqual(i, entries.len);
        }
    }
    try testing.expectEqual(@as(usize, 6), n);

    const head = try repo.resolveRev(gpa, io, "HEAD");
    try testing.expectError(error.IsDir, repo.readPath(gpa, io, head, "docs"));
    try testing.expectError(error.IsDir, repo.readPath(gpa, io, head, "docs/guide/"));
    try testing.expectError(error.IsDir, repo.readPath(gpa, io, head, ""));
    try testing.expectError(error.PathNotFound, repo.readPath(gpa, io, head, "nope.txt"));
    try testing.expectError(error.PathNotFound, repo.readPath(gpa, io, head, "README.md/inside"));
    try testing.expectError(error.PathNotFound, repo.listTree(gpa, io, head, "docs/missing"));
    try testing.expectError(error.NotDir, repo.listTree(gpa, io, head, "README.md"));
}

test "discover from a subdirectory and read remotes" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try setupFixture(gpa, io);
    defer f.deinit();

    const sub = try std.fs.path.join(gpa, &.{ f.repo_path, "docs", "guide" });
    defer gpa.free(sub);
    var repo = try Repo.discover(gpa, io, sub);
    defer repo.deinit(gpa);

    try testing.expectEqualStrings(f.repo_path, repo.work_tree.?);
    try testing.expect(std.mem.endsWith(u8, repo.git_dir, "/repo/.git"));
    try testing.expectEqualStrings(repo.git_dir, repo.common_dir);

    const url = (try repo.remoteUrl(gpa, io, null)).?;
    defer gpa.free(url);
    try testing.expectEqualStrings("https://example.com/acme/widget.git", url);
    try testing.expectEqual(@as(?[]u8, null), try repo.remoteUrl(gpa, io, "upstream"));

    try f.gitDiscard(&.{ "remote", "add", "fork", "https://example.com/me/widget.git" });
    try f.gitDiscard(&.{ "config", "url.git@example.com:.insteadOf", "https://example.com/" });
    try f.gitDiscard(&.{ "config", "url.ssh://short/.insteadOf", "https://example.com/me/" });

    const rewritten = (try repo.remoteUrl(gpa, io, "origin")).?;
    defer gpa.free(rewritten);
    const want = try f.git(&.{ "remote", "get-url", "origin" });
    defer gpa.free(want);
    try testing.expectEqualStrings(std.mem.trim(u8, want, "\n"), rewritten);

    const fork = (try repo.remoteUrl(gpa, io, "fork")).?;
    defer gpa.free(fork);
    const want_fork = try f.git(&.{ "remote", "get-url", "fork" });
    defer gpa.free(want_fork);
    try testing.expectEqualStrings(std.mem.trim(u8, want_fork, "\n"), fork);

    const default = (try repo.remoteUrl(gpa, io, null)).?;
    defer gpa.free(default);
    try testing.expectEqualStrings(rewritten, default);
}

test "linked worktree and bare clone" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try setupFixture(gpa, io);
    defer f.deinit();

    try f.gitDiscard(&.{ "worktree", "add", "-q", "-b", "wtbranch", "../wt", "HEAD~1" });
    const wt_path = try std.fs.path.join(gpa, &.{ f.root, "wt" });
    defer gpa.free(wt_path);
    var wt = try Repo.discover(gpa, io, wt_path);
    defer wt.deinit(gpa);
    try testing.expectEqualStrings(wt_path, wt.work_tree.?);
    try testing.expect(std.mem.indexOf(u8, wt.git_dir, "/.git/worktrees/") != null);
    try testing.expect(std.mem.endsWith(u8, wt.common_dir, "/repo/.git"));
    try expectOid(try f.rev(wt_path, "HEAD"), try wt.resolveRev(gpa, io, "HEAD"));
    try expectOid(try f.rev(wt_path, "main"), try wt.resolveRev(gpa, io, "main"));
    const wt_url = (try wt.remoteUrl(gpa, io, null)).?;
    defer gpa.free(wt_url);

    gpa.free(try f.run(f.root, &.{ "clone", "-q", "--bare", "repo", "bare.git" }));
    const bare_path = try std.fs.path.join(gpa, &.{ f.root, "bare.git" });
    defer gpa.free(bare_path);
    var bare = try Repo.discover(gpa, io, bare_path);
    defer bare.deinit(gpa);
    try testing.expectEqual(@as(?[]u8, null), bare.work_tree);
    const head = try bare.resolveRev(gpa, io, "HEAD");
    try expectOid(try f.rev(bare_path, "HEAD"), head);
    try expectOid(try f.rev(bare_path, "v1.0^{commit}"), try bare.resolveRev(gpa, io, "v1.0"));
    const readme = try bare.readPath(gpa, io, head, "docs/guide/intro.md");
    defer gpa.free(readme);
    const spec = try std.fmt.allocPrint(gpa, "{s}:docs/guide/intro.md", .{head.toHex()});
    defer gpa.free(spec);
    const want = try f.run(bare_path, &.{ "show", spec });
    defer gpa.free(want);
    try testing.expectEqualSlices(u8, want, readme);
}

test "sha256 repositories are rejected" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try setupFixture(gpa, io);
    defer f.deinit();

    const out = f.run(f.root, &.{ "init", "-q", "--object-format=sha256", "wide" }) catch |err| switch (err) {
        error.GitFailed => return error.SkipZigTest,
        else => return err,
    };
    gpa.free(out);
    const path = try std.fs.path.join(gpa, &.{ f.root, "wide" });
    defer gpa.free(path);
    var repo = try Repo.discover(gpa, io, path);
    defer repo.deinit(gpa);
    try testing.expectError(error.UnsupportedObjectFormat, repo.resolveRev(gpa, io, "HEAD"));
}

test "discover fails outside a repository" {
    try testing.expectError(error.NotARepository, Repo.discover(testing.allocator, testing.io, "/"));
}
