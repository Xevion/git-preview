//! Read-only view of a git repository, backed by libgit2 (built without TLS or SSH, never writes).
//!
//! Supported: loose and packed objects, alternates, linked worktrees, bare repositories,
//! SHA-1 and (unless built with `-Dsha256=false`) SHA-256 repositories, `~`/`^`/`^{}` revision syntax,
//! and system, global and repository config including `url.<base>.insteadOf`.
//! Not supported: reftable ref storage (`UnsupportedRefStorage`) and lazy fetching of partial-clone objects.

const Repo = @This();

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const c = @import("git2");

const log = std.log.scoped(.git);

/// Whether libgit2 was built with SHA-256 object ids (`git_oid` carries a type tag).
const wide_oids = @hasField(c.git_oid, "type");

pub const Error = error{
    NotARepository,
    UnsafeRepository,
    UnsupportedObjectFormat,
    UnsupportedRefStorage,
    UnsupportedRepository,
    RevisionNotFound,
    AmbiguousRevision,
    ObjectNotFound,
    NotACommit,
    PathNotFound,
    IsDir,
    NotDir,
    IsSubmodule,
    CorruptObject,
    InvalidOid,
    GitFailure,
    OutOfMemory,
};

/// An object id of 20 (SHA-1) or 32 (SHA-256) bytes.
pub const Oid = struct {
    bytes: [max_len]u8 = @splat(0),
    len: u8,

    pub const max_len = 32;
    pub const max_hex_len = 64;

    pub fn parseHex(text: []const u8) error{InvalidOid}!Oid {
        if (text.len != 40 and text.len != 64) return error.InvalidOid;
        var oid: Oid = .{ .len = @intCast(text.len / 2) };
        _ = std.fmt.hexToBytes(oid.bytes[0..oid.len], text) catch return error.InvalidOid;
        return oid;
    }

    pub fn slice(self: *const Oid) []const u8 {
        return self.bytes[0..self.len];
    }

    /// Writes the lowercase hex form into `buf` and returns the used part.
    pub fn hex(self: *const Oid, buf: *[max_hex_len]u8) []const u8 {
        const out = buf[0 .. @as(usize, self.len) * 2];
        _ = std.fmt.bufPrint(out, "{x}", .{self.slice()}) catch unreachable;
        return out;
    }

    pub fn eql(a: Oid, b: Oid) bool {
        return a.len == b.len and std.mem.eql(u8, a.slice(), b.slice());
    }

    pub fn format(self: Oid, w: *Io.Writer) Io.Writer.Error!void {
        var buf: [max_hex_len]u8 = undefined;
        try w.writeAll(self.hex(&buf));
    }
};

pub const EntryKind = enum { file, executable, symlink, directory, submodule };

pub const Entry = struct {
    name: []u8,
    mode: u32,
    oid: Oid,
    kind: EntryKind,
};

handle: *c.git_repository,
/// Absolute path of the directory holding HEAD and per-worktree state.
git_dir: []u8,
/// Absolute path of the directory holding objects, shared refs and config; equals `git_dir` unless linked.
common_dir: []u8,
/// Absolute path of the checked-out tree, or null for bare repositories.
work_tree: ?[]u8,

pub fn deinit(self: *Repo, gpa: Allocator) void {
    c.git_repository_free(self.handle);
    gpa.free(self.git_dir);
    gpa.free(self.common_dir);
    if (self.work_tree) |w| gpa.free(w);
    self.* = undefined;
}

pub fn freeEntries(gpa: Allocator, entries: []Entry) void {
    for (entries) |e| gpa.free(e.name);
    gpa.free(entries);
}

fn check(rc: c_int, not_found: Error) Error!void {
    if (rc >= 0) return;
    switch (rc) {
        c.GIT_ENOTFOUND, c.GIT_EINVALIDSPEC => return not_found,
        c.GIT_EAMBIGUOUS => return error.AmbiguousRevision,
        c.GIT_EPEEL => return error.NotACommit,
        c.GIT_EMISMATCH => return error.CorruptObject,
        c.GIT_EOWNER => return error.UnsafeRepository,
        else => {},
    }
    const err = c.git_error_last() orelse return error.GitFailure;
    const msg = std.mem.span(err.*.message);
    switch (err.*.klass) {
        c.GIT_ERROR_NOMEMORY => return error.OutOfMemory,
        c.GIT_ERROR_ODB, c.GIT_ERROR_ZLIB, c.GIT_ERROR_OBJECT, c.GIT_ERROR_TREE, c.GIT_ERROR_TAG, c.GIT_ERROR_INDEXER, c.GIT_ERROR_SHA => return error.CorruptObject,
        else => {},
    }
    if (std.mem.indexOf(u8, msg, "refstorage") != null) return error.UnsupportedRefStorage;
    if (std.mem.indexOf(u8, msg, "object format") != null) return error.UnsupportedObjectFormat;
    if (std.mem.indexOf(u8, msg, "unsupported extension") != null) return error.UnsupportedRepository;
    log.debug("libgit2 error {d} (class {d}): {s}", .{ rc, err.*.klass, msg });
    return error.GitFailure;
}

fn oidFromC(oid: *const c.git_oid) Oid {
    var out: Oid = .{ .len = 20 };
    if (wide_oids and oid.type == c.GIT_OID_SHA256) out.len = 32;
    @memcpy(out.bytes[0..out.len], oid.id[0..out.len]);
    return out;
}

fn oidToC(oid: Oid) Error!c.git_oid {
    var out: c.git_oid = undefined;
    if (wide_oids) {
        const kind = switch (oid.len) {
            20 => @as(c.git_oid_t, c.GIT_OID_SHA1),
            32 => @as(c.git_oid_t, c.GIT_OID_SHA256),
            else => return error.InvalidOid,
        };
        try check(c.git_oid_fromraw(&out, &oid.bytes, kind), error.InvalidOid);
    } else {
        if (oid.len != 20) return error.UnsupportedObjectFormat;
        try check(c.git_oid_fromraw(&out, &oid.bytes), error.InvalidOid);
    }
    return out;
}

fn stripSlash(path: []const u8) []const u8 {
    return if (path.len > 1 and path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
}

fn dupeCPath(gpa: Allocator, path: ?[*:0]const u8) Error!?[]u8 {
    const p = path orelse return null;
    return try gpa.dupe(u8, stripSlash(std.mem.span(p)));
}

/// Opens the repository containing `start_path` (a directory or a file), searching upward like git does.
pub fn discover(gpa: Allocator, io: Io, start_path: []const u8) !Repo {
    const abs = try Dir.cwd().realPathFileAlloc(io, start_path, gpa);
    defer gpa.free(abs);
    const st = try Dir.cwd().statFile(io, abs, .{});
    const dir = if (st.kind == .directory)
        abs
    else
        std.fs.path.dirname(abs) orelse return error.NotARepository;
    const dir_z = try gpa.dupeSentinel(u8, dir, 0);
    defer gpa.free(dir_z);

    // The count is never released: libgit2's global state lives for the whole process.
    _ = c.git_libgit2_init();
    // Reads never write, so a repository owned by another user is safe to open.
    _ = c.git_libgit2_opts(c.GIT_OPT_SET_OWNER_VALIDATION, @as(c_int, 0));

    var handle: ?*c.git_repository = null;
    try check(c.git_repository_open_ext(&handle, dir_z, 0, null), error.NotARepository);
    const repo = handle.?;
    errdefer c.git_repository_free(repo);

    const git_dir = (try dupeCPath(gpa, c.git_repository_path(repo))) orelse return error.GitFailure;
    errdefer gpa.free(git_dir);
    const common_dir = (try dupeCPath(gpa, c.git_repository_commondir(repo))) orelse try gpa.dupe(u8, git_dir);
    errdefer gpa.free(common_dir);
    const work_tree = try dupeCPath(gpa, c.git_repository_workdir(repo));
    return .{ .handle = repo, .git_dir = git_dir, .common_dir = common_dir, .work_tree = work_tree };
}

fn lookupRemote(self: *const Repo, name: []const u8) Error!?*c.git_remote {
    var remote: ?*c.git_remote = null;
    var buf: [256]u8 = undefined;
    const name_z = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return null;
    check(c.git_remote_lookup(&remote, self.handle, name_z), error.NotARepository) catch |err| switch (err) {
        error.NotARepository => return null,
        else => return err,
    };
    return remote;
}

fn soleRemote(self: *const Repo) Error!?*c.git_remote {
    var names: c.git_strarray = .{ .strings = null, .count = 0 };
    try check(c.git_remote_list(&names, self.handle), error.GitFailure);
    defer c.git_strarray_dispose(&names);
    if (names.count != 1) return null;
    return self.lookupRemote(std.mem.span(names.strings[0]));
}

/// Returns the fetch URL of remote `name`, or of `origin` / the sole remote when `name` is null.
/// `url.<base>.insteadOf` rules from system, global and repository config are applied.
pub fn remoteUrl(self: *const Repo, gpa: Allocator, io: Io, name: ?[]const u8) Error!?[]u8 {
    _ = io;
    const remote = (if (name) |n|
        try self.lookupRemote(n)
    else
        try self.lookupRemote("origin") orelse try self.soleRemote()) orelse return null;
    defer c.git_remote_free(remote);
    const url = c.git_remote_url(remote) orelse return null;
    return try gpa.dupe(u8, std.mem.span(url));
}

/// The last-fetched tip of `branch` on remote `name` (`origin` or the sole remote when null), falling back
/// to that remote's HEAD; null when neither was ever fetched.
pub fn remoteTip(self: *const Repo, gpa: Allocator, io: Io, name: ?[]const u8, branch: ?[]const u8) Error!?Oid {
    const remote = (if (name) |n|
        try self.lookupRemote(n)
    else
        try self.lookupRemote("origin") orelse try self.soleRemote()) orelse return null;
    defer c.git_remote_free(remote);
    const remote_name = std.mem.span(c.git_remote_name(remote) orelse return null);
    var buf: [512]u8 = undefined;
    if (branch) |b| {
        const ref = std.fmt.bufPrint(&buf, "refs/remotes/{s}/{s}", .{ remote_name, b }) catch return null;
        if (self.resolveRev(gpa, io, ref)) |oid| return oid else |err| if (err != error.RevisionNotFound) return err;
    }
    const head = std.fmt.bufPrint(&buf, "refs/remotes/{s}/HEAD", .{remote_name}) catch return null;
    return self.resolveRev(gpa, io, head) catch |err| switch (err) {
        error.RevisionNotFound => null,
        else => err,
    };
}

/// The newest commit reachable from `start` authored by `email` (case-insensitive), within `limit` commits.
pub fn newestByAuthor(self: *const Repo, gpa: Allocator, io: Io, start: Oid, email: []const u8, limit: usize) Error!?Oid {
    _ = gpa;
    _ = io;
    const coid = try oidToC(start);
    var walk: ?*c.git_revwalk = null;
    try check(c.git_revwalk_new(&walk, self.handle), error.GitFailure);
    defer c.git_revwalk_free(walk);
    try check(c.git_revwalk_sorting(walk, c.GIT_SORT_TIME), error.GitFailure);
    try check(c.git_revwalk_push(walk, &coid), error.ObjectNotFound);
    var id: c.git_oid = undefined;
    for (0..limit) |_| {
        const rc = c.git_revwalk_next(&id, walk);
        if (rc == c.GIT_ITEROVER) return null;
        try check(rc, error.GitFailure);
        const commit = try self.lookupCommit(&id);
        defer c.git_commit_free(commit);
        const author = c.git_commit_author(commit) orelse continue;
        const e = if (author.*.email) |p| std.mem.span(p) else continue;
        if (std.ascii.eqlIgnoreCase(e, email)) return oidFromC(&id);
    }
    return null;
}

/// Resolves any revision expression (ref name, full or short id, `HEAD~2`, `v1^{commit}`) to an object id,
/// peeling annotated tags down to the tagged object.
pub fn resolveRev(self: *const Repo, gpa: Allocator, io: Io, rev: []const u8) Error!Oid {
    _ = io;
    if (std.mem.indexOfScalar(u8, rev, 0) != null) return error.RevisionNotFound;
    const rev_z = try gpa.dupeSentinel(u8, rev, 0);
    defer gpa.free(rev_z);

    var obj: ?*c.git_object = null;
    try check(c.git_revparse_single(&obj, self.handle, rev_z), error.RevisionNotFound);
    defer c.git_object_free(obj);
    if (c.git_object_type(obj) != c.GIT_OBJECT_TAG) return oidFromC(c.git_object_id(obj));
    var target: ?*c.git_object = null;
    try check(c.git_object_peel(&target, obj, c.GIT_OBJECT_ANY), error.RevisionNotFound);
    defer c.git_object_free(target);
    return oidFromC(c.git_object_id(target));
}

/// Joins the non-empty, non-"." components of `path` with single slashes.
fn normalizePath(gpa: Allocator, path: []const u8) Error![:0]u8 {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.PathNotFound;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (out.items.len > 0) try out.append(gpa, '/');
        try out.appendSlice(gpa, part);
    }
    return out.toOwnedSliceSentinel(gpa, 0);
}

fn rootTree(self: *const Repo, commit: Oid) Error!*c.git_tree {
    const oid = try oidToC(commit);
    var obj: ?*c.git_object = null;
    try check(c.git_object_lookup(&obj, self.handle, &oid, c.GIT_OBJECT_ANY), error.ObjectNotFound);
    defer c.git_object_free(obj);
    var tree: ?*c.git_object = null;
    try check(c.git_object_peel(&tree, obj, c.GIT_OBJECT_TREE), error.NotACommit);
    return @ptrCast(tree.?);
}

fn kindOfMode(mode: u32) EntryKind {
    return switch (mode & 0o170000) {
        0o040000 => .directory,
        0o160000 => .submodule,
        0o120000 => .symlink,
        else => if (mode & 0o111 != 0) .executable else .file,
    };
}

/// Returns the bytes of the blob at `path` in `commit`'s tree. Symlinks yield their target text.
/// Errors: `PathNotFound`, `IsDir` for a directory, `IsSubmodule` for a gitlink.
pub fn readPath(self: *const Repo, gpa: Allocator, io: Io, commit: Oid, path: []const u8) Error![]u8 {
    _ = io;
    const norm = try normalizePath(gpa, path);
    defer gpa.free(norm);
    const tree = try self.rootTree(commit);
    defer c.git_tree_free(tree);
    if (norm.len == 0) return error.IsDir;

    var entry: ?*c.git_tree_entry = null;
    try check(c.git_tree_entry_bypath(&entry, tree, norm), error.PathNotFound);
    defer c.git_tree_entry_free(entry);
    switch (kindOfMode(c.git_tree_entry_filemode_raw(entry))) {
        .directory => return error.IsDir,
        .submodule => return error.IsSubmodule,
        else => {},
    }
    var blob: ?*c.git_blob = null;
    try check(c.git_blob_lookup(&blob, self.handle, c.git_tree_entry_id(entry)), error.ObjectNotFound);
    defer c.git_blob_free(blob);
    const size: usize = @intCast(c.git_blob_rawsize(blob));
    if (size == 0) return gpa.alloc(u8, 0);
    const content: [*]const u8 = @ptrCast(c.git_blob_rawcontent(blob) orelse return error.CorruptObject);
    return gpa.dupe(u8, content[0..size]);
}

/// Lists the entries of the directory at `dir_path` ("" for the root) in tree order.
/// Free the result with `freeEntries`. Errors: `PathNotFound`, `NotDir`.
pub fn listTree(self: *const Repo, gpa: Allocator, io: Io, commit: Oid, dir_path: []const u8) Error![]Entry {
    _ = io;
    const norm = try normalizePath(gpa, dir_path);
    defer gpa.free(norm);
    const root = try self.rootTree(commit);
    defer c.git_tree_free(root);

    var sub: ?*c.git_tree = null;
    defer if (sub) |s| c.git_tree_free(s);
    var tree = root;
    if (norm.len > 0) {
        var entry: ?*c.git_tree_entry = null;
        try check(c.git_tree_entry_bypath(&entry, root, norm), error.PathNotFound);
        defer c.git_tree_entry_free(entry);
        if (kindOfMode(c.git_tree_entry_filemode_raw(entry)) != .directory) return error.NotDir;
        try check(c.git_tree_lookup(&sub, self.handle, c.git_tree_entry_id(entry)), error.ObjectNotFound);
        tree = sub.?;
    }

    const count = c.git_tree_entrycount(tree);
    var list: std.ArrayList(Entry) = try .initCapacity(gpa, count);
    errdefer {
        for (list.items) |e| gpa.free(e.name);
        list.deinit(gpa);
    }
    for (0..count) |i| {
        const item = c.git_tree_entry_byindex(tree, i) orelse return error.CorruptObject;
        const name = try gpa.dupe(u8, std.mem.span(c.git_tree_entry_name(item)));
        errdefer gpa.free(name);
        const mode: u32 = @intCast(c.git_tree_entry_filemode_raw(item));
        list.appendAssumeCapacity(.{
            .name = name,
            .mode = mode,
            .oid = oidFromC(c.git_tree_entry_id(item)),
            .kind = kindOfMode(mode),
        });
    }
    return list.toOwnedSlice(gpa);
}

/// Returns the short name of the branch HEAD points to, or null when HEAD is detached.
/// An unborn branch still yields its name.
pub fn headBranch(self: *const Repo, gpa: Allocator, io: Io) Error!?[]u8 {
    _ = io;
    var ref: ?*c.git_reference = null;
    try check(c.git_reference_lookup(&ref, self.handle, "HEAD"), error.GitFailure);
    defer c.git_reference_free(ref);
    const target = c.git_reference_symbolic_target(ref) orelse return null;
    const full = std.mem.span(target);
    const prefix = "refs/heads/";
    if (!std.mem.startsWith(u8, full, prefix)) return null;
    return try gpa.dupe(u8, full[prefix.len..]);
}

pub const Commit = struct {
    oid: Oid,
    /// First line of the message.
    summary: []u8,
    author_name: []u8,
    author_email: []u8,
    /// Unix seconds.
    author_time: i64,
    /// Unix seconds; what forges date a commit by.
    commit_time: i64,
    /// The message continues past its first line.
    has_body: bool,
};

pub fn freeCommit(gpa: Allocator, commit: Commit) void {
    gpa.free(commit.summary);
    gpa.free(commit.author_name);
    gpa.free(commit.author_email);
}

pub const PathCommit = struct {
    name: []u8,
    commit: Commit,
};

pub fn freePathCommits(gpa: Allocator, items: []PathCommit) void {
    for (items) |item| {
        gpa.free(item.name);
        freeCommit(gpa, item.commit);
    }
    gpa.free(items);
}

fn lookupCommit(self: *const Repo, oid: *const c.git_oid) Error!*c.git_commit {
    var commit: ?*c.git_commit = null;
    try check(c.git_commit_lookup(&commit, self.handle, oid), error.ObjectNotFound);
    return commit.?;
}

fn commitFromC(gpa: Allocator, commit: *c.git_commit) Error!Commit {
    const message = if (c.git_commit_message(commit)) |m| std.mem.span(m) else "";
    const line = std.mem.trimEnd(u8, message[0 .. std.mem.indexOfScalar(u8, message, '\n') orelse message.len], " \t\r");
    const author = c.git_commit_author(commit) orelse return error.CorruptObject;

    const summary = try gpa.dupe(u8, line);
    errdefer gpa.free(summary);
    const name = try gpa.dupe(u8, if (author.*.name) |n| std.mem.span(n) else "");
    errdefer gpa.free(name);
    const email = try gpa.dupe(u8, if (author.*.email) |e| std.mem.span(e) else "");
    return .{
        .oid = oidFromC(c.git_commit_id(commit)),
        .summary = summary,
        .author_name = name,
        .author_email = email,
        .author_time = author.*.when.time,
        .commit_time = c.git_commit_time(commit),
        .has_body = if (std.mem.indexOfScalar(u8, message, '\n')) |nl| std.mem.trim(u8, message[nl..], " \t\r\n").len > 0 else false,
    };
}

/// Reads the summary and author of the commit `oid`. Free the result with `freeCommit`.
/// Errors: `ObjectNotFound`.
pub fn commitInfo(self: *const Repo, gpa: Allocator, io: Io, oid: Oid) Error!Commit {
    _ = io;
    const coid = try oidToC(oid);
    const commit = try self.lookupCommit(&coid);
    defer c.git_commit_free(commit);
    return commitFromC(gpa, commit);
}

/// Counts the commits reachable from `oid`, like `git rev-list --count`.
pub fn commitCount(self: *const Repo, gpa: Allocator, io: Io, oid: Oid) Error!u64 {
    _ = gpa;
    _ = io;
    const coid = try oidToC(oid);
    var walk: ?*c.git_revwalk = null;
    try check(c.git_revwalk_new(&walk, self.handle), error.GitFailure);
    defer c.git_revwalk_free(walk);
    try check(c.git_revwalk_push(walk, &coid), error.ObjectNotFound);
    var id: c.git_oid = undefined;
    var n: u64 = 0;
    while (true) {
        const rc = c.git_revwalk_next(&id, walk);
        if (rc == c.GIT_ITEROVER) return n;
        try check(rc, error.GitFailure);
        n += 1;
    }
}

/// Returns an owned copy of the tree at `norm` below `root`.
/// Errors: `PathNotFound`, `NotDir`.
fn subTree(self: *const Repo, root: *c.git_tree, norm: [:0]const u8) Error!*c.git_tree {
    var out: ?*c.git_tree = null;
    if (norm.len == 0) {
        try check(c.git_tree_dup(&out, root), error.GitFailure);
        return out.?;
    }
    var entry: ?*c.git_tree_entry = null;
    try check(c.git_tree_entry_bypath(&entry, root, norm), error.PathNotFound);
    defer c.git_tree_entry_free(entry);
    if (kindOfMode(c.git_tree_entry_filemode_raw(entry)) != .directory) return error.NotDir;
    try check(c.git_tree_lookup(&out, self.handle, c.git_tree_entry_id(entry)), error.ObjectNotFound);
    return out.?;
}

/// The tree at `norm` in `commit`, or null when the commit has no directory there.
fn dirTreeOf(self: *const Repo, commit: *c.git_commit, norm: [:0]const u8) Error!?*c.git_tree {
    var root: ?*c.git_tree = null;
    try check(c.git_commit_tree(&root, commit), error.CorruptObject);
    defer c.git_tree_free(root);
    return self.subTree(root.?, norm) catch |err| switch (err) {
        error.PathNotFound, error.NotDir => null,
        else => err,
    };
}

/// For each entry of the directory at `dir_path` in `oid` ("" for the root), finds the commit that last
/// changed it as `git log -1 -- <entry>` reports it, in tree order. Root commits count as adding everything.
/// Free the result with `freePathCommits`. Errors: `PathNotFound`, `NotDir`.
const Queued = struct {
    oid: Oid,
    time: i64,

    fn newerFirst(_: void, x: Queued, y: Queued) std.math.Order {
        return std.math.order(y.time, x.time);
    }
};

pub fn lastCommits(self: *const Repo, gpa: Allocator, io: Io, oid: Oid, dir_path: []const u8) Error![]PathCommit {
    _ = io;
    const norm = try normalizePath(gpa, dir_path);
    defer gpa.free(norm);
    const start_root = try self.rootTree(oid);
    defer c.git_tree_free(start_root);
    const start = try self.subTree(start_root, norm);
    defer c.git_tree_free(start);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const count = c.git_tree_entrycount(start);
    const names = try a.alloc([:0]u8, count);
    const found = try a.alloc(?c.git_oid, count);
    @memset(found, null);
    for (names, 0..) |*name, i| {
        const item = c.git_tree_entry_byindex(start, i) orelse return error.CorruptObject;
        name.* = try a.dupeSentinel(u8, std.mem.span(c.git_tree_entry_name(item)), 0);
    }

    // Each entry follows git's default history simplification, as `git log -1 -- <path>` and GitHub
    // do: through a commit to its first parent holding the same entry, else that commit changed it.
    // Entries travel together, so one pass over the shared history serves them all.
    var pending: std.AutoHashMapUnmanaged(Oid, std.ArrayList(u32)) = .empty;
    var queue: std.PriorityQueue(Queued, void, Queued.newerFirst) = .empty;
    {
        var all: std.ArrayList(u32) = try .initCapacity(a, count);
        for (0..count) |idx| all.appendAssumeCapacity(@intCast(idx));
        try pending.put(a, oid, all);
        try queue.push(a, .{ .oid = oid, .time = 0 });
    }

    while (queue.pop()) |item| {
        const kv = pending.fetchRemove(item.oid) orelse continue;
        const paths = kv.value.items;
        const id = try oidToC(item.oid);
        const commit = try self.lookupCommit(&id);
        defer c.git_commit_free(commit);
        const cur = try self.dirTreeOf(commit, norm) orelse {
            for (paths) |idx| found[idx] = id;
            continue;
        };
        defer c.git_tree_free(cur);

        const nparents = c.git_commit_parentcount(commit);
        const parents = try a.alloc(Oid, nparents);
        const trees = try a.alloc(?*c.git_tree, nparents);
        @memset(trees, null);
        defer for (trees) |t| if (t) |tree| c.git_tree_free(tree);
        for (parents, trees, 0..) |*po, *pt, n| {
            var parent: ?*c.git_commit = null;
            try check(c.git_commit_parent(&parent, commit, @intCast(n)), error.ObjectNotFound);
            defer c.git_commit_free(parent);
            po.* = oidFromC(c.git_commit_id(parent));
            pt.* = try self.dirTreeOf(parent.?, norm);
        }

        for (paths) |idx| {
            const now = c.git_tree_entry_byname(cur, names[idx]) orelse {
                found[idx] = id;
                continue;
            };
            const same = for (trees, 0..) |pt, n| {
                const tree = pt orelse continue;
                // An identical directory means every entry is unchanged against this parent.
                if (c.git_oid_equal(c.git_tree_id(tree), c.git_tree_id(cur)) != 0) break n;
                const before = c.git_tree_entry_byname(tree, names[idx]) orelse continue;
                if (c.git_tree_entry_filemode_raw(now) == c.git_tree_entry_filemode_raw(before) and
                    c.git_oid_equal(c.git_tree_entry_id(now), c.git_tree_entry_id(before)) != 0) break n;
            } else null;
            const n = same orelse {
                found[idx] = id;
                continue;
            };
            const gop = try pending.getOrPut(a, parents[n]);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
                var pid = try oidToC(parents[n]);
                const pc = try self.lookupCommit(&pid);
                defer c.git_commit_free(pc);
                try queue.push(a, .{ .oid = parents[n], .time = c.git_commit_time(pc) });
            }
            try gop.value_ptr.append(a, idx);
        }
    }

    var out: std.ArrayList(PathCommit) = try .initCapacity(gpa, count);
    errdefer {
        for (out.items) |item| {
            gpa.free(item.name);
            freeCommit(gpa, item.commit);
        }
        out.deinit(gpa);
    }
    for (names, found) |name, slot| {
        const last = slot orelse return error.CorruptObject;
        const commit = try self.lookupCommit(&last);
        defer c.git_commit_free(commit);
        const info = try commitFromC(gpa, commit);
        errdefer freeCommit(gpa, info);
        const dup = try gpa.dupe(u8, name);
        out.appendAssumeCapacity(.{ .name = dup, .commit = info });
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

const unreadable_config_dir = "/nonexistent-git-preview-config";

/// Points every libgit2 config level at a directory that does not exist, so tests never read the real user's config.
fn isolateConfig(global_dir: []const u8) !void {
    _ = c.git_libgit2_init();
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const global = try std.fmt.bufPrintSentinel(&buf, "{s}", .{global_dir}, 0);
    for ([_]c_int{ c.GIT_CONFIG_LEVEL_PROGRAMDATA, c.GIT_CONFIG_LEVEL_SYSTEM, c.GIT_CONFIG_LEVEL_XDG }) |level| {
        try testing.expect(c.git_libgit2_opts(c.GIT_OPT_SET_SEARCH_PATH, level, unreadable_config_dir) >= 0);
    }
    try testing.expect(c.git_libgit2_opts(c.GIT_OPT_SET_SEARCH_PATH, @as(c_int, c.GIT_CONFIG_LEVEL_GLOBAL), global.ptr) >= 0);
}

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

    fn path(self: *Fixture, name: []const u8) ![]u8 {
        return std.fs.path.join(self.gpa, &.{ self.root, name });
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

fn newFixture(gpa: Allocator, io: Io) !Fixture {
    try isolateConfig(unreadable_config_dir);
    var f: Fixture = .{ .gpa = gpa, .io = io, .tmp = testing.tmpDir(.{}), .root = undefined, .repo_path = undefined };
    errdefer f.tmp.cleanup();

    const real = try f.tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(real);
    f.root = try gpa.dupe(u8, real);
    errdefer gpa.free(f.root);
    f.repo_path = try std.fs.path.join(gpa, &.{ f.root, "repo" });
    return f;
}

/// Five packed commits (with deltas), a packed annotated tag, then one loose commit on top.
fn setupFixture(gpa: Allocator, io: Io) !Fixture {
    var f = try newFixture(gpa, io);
    errdefer f.deinit();

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
    var a: [Oid.max_hex_len]u8 = undefined;
    var b: [Oid.max_hex_len]u8 = undefined;
    try testing.expectEqualStrings(expected.hex(&a), actual.hex(&b));
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
        .{ .rev = "HEAD~1", .git_rev = "HEAD~1" },
        .{ .rev = "HEAD^", .git_rev = "HEAD^" },
        .{ .rev = "main~3", .git_rev = "main~3" },
        .{ .rev = "feature^^", .git_rev = "feature^^" },
        .{ .rev = "v1.0~1", .git_rev = "v1.0~1" },
        .{ .rev = "HEAD^{tree}", .git_rev = "HEAD^{tree}" },
    };
    for (cases) |c_| {
        const want = try f.rev(f.repo_path, c_.git_rev);
        try expectOid(want, try repo.resolveRev(gpa, io, c_.rev));
    }

    const tag_object = try f.rev(f.repo_path, "v1.0");
    const commit = try f.rev(f.repo_path, "v1.0^{commit}");
    try testing.expect(!tag_object.eql(commit));
    var tag_buf: [Oid.max_hex_len]u8 = undefined;
    try expectOid(commit, try repo.resolveRev(gpa, io, tag_object.hex(&tag_buf)));

    for ([_][]const u8{ "HEAD", "HEAD~1", "feature", "v1.0^{commit}" }) |name| {
        const want = try f.rev(f.repo_path, name);
        var buf: [Oid.max_hex_len]u8 = undefined;
        const full = want.hex(&buf);
        try expectOid(want, try repo.resolveRev(gpa, io, full));
        try expectOid(want, try repo.resolveRev(gpa, io, full[0..10]));
        const short = try f.run(f.repo_path, &.{ "rev-parse", "--short=7", full });
        defer gpa.free(short);
        try expectOid(want, try repo.resolveRev(gpa, io, std.mem.trim(u8, short, "\n")));
    }

    try testing.expectError(error.RevisionNotFound, repo.resolveRev(gpa, io, "nonexistent"));
    try testing.expectError(error.RevisionNotFound, repo.resolveRev(gpa, io, "0000000"));
    try testing.expectError(error.RevisionNotFound, repo.resolveRev(gpa, io, "../config"));
    try testing.expectError(error.RevisionNotFound, repo.resolveRev(gpa, io, "config"));
    try testing.expectError(error.RevisionNotFound, repo.resolveRev(gpa, io, "HEAD~99"));
}

test "readPath and listTree agree with git across packed and loose objects" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try setupFixture(gpa, io);
    defer f.deinit();
    var repo = try Repo.discover(gpa, io, f.repo_path);
    defer repo.deinit(gpa);

    const log_out = try f.git(&.{ "rev-list", "HEAD" });
    defer gpa.free(log_out);
    var commits = std.mem.tokenizeScalar(u8, log_out, '\n');
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

    var again = try Repo.discover(gpa, io, sub);
    defer again.deinit(gpa);
    const rewritten = (try again.remoteUrl(gpa, io, "origin")).?;
    defer gpa.free(rewritten);
    try testing.expectEqualStrings("git@example.com:acme/widget.git", rewritten);

    const fork = (try again.remoteUrl(gpa, io, "fork")).?;
    defer gpa.free(fork);
    try testing.expectEqualStrings("ssh://short/widget.git", fork);

    const default = (try again.remoteUrl(gpa, io, null)).?;
    defer gpa.free(default);
    try testing.expectEqualStrings(rewritten, default);
}

test "global config insteadOf applies, and the real user config is not read" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try setupFixture(gpa, io);
    defer f.deinit();

    var repo = try Repo.discover(gpa, io, f.repo_path);
    defer repo.deinit(gpa);
    const plain = (try repo.remoteUrl(gpa, io, null)).?;
    defer gpa.free(plain);
    try testing.expectEqualStrings("https://example.com/acme/widget.git", plain);

    try f.tmp.dir.createDirPath(io, "home");
    try f.tmp.dir.writeFile(io, .{
        .sub_path = "home/.gitconfig",
        .data = "[url \"git@example.com:\"]\n\tinsteadOf = https://example.com/\n",
    });
    const home = try f.path("home");
    defer gpa.free(home);
    try isolateConfig(home);
    defer isolateConfig(unreadable_config_dir) catch {};

    var with_global = try Repo.discover(gpa, io, f.repo_path);
    defer with_global.deinit(gpa);
    const rewritten = (try with_global.remoteUrl(gpa, io, null)).?;
    defer gpa.free(rewritten);
    try testing.expectEqualStrings("git@example.com:acme/widget.git", rewritten);
}

test "linked worktree and bare clone" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try setupFixture(gpa, io);
    defer f.deinit();

    try f.gitDiscard(&.{ "worktree", "add", "-q", "-b", "wtbranch", "../wt", "HEAD~1" });
    const wt_path = try f.path("wt");
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
    try testing.expectEqualStrings("https://example.com/acme/widget.git", wt_url);

    gpa.free(try f.run(f.root, &.{ "clone", "-q", "--bare", "repo", "bare.git" }));
    const bare_path = try f.path("bare.git");
    defer gpa.free(bare_path);
    var bare = try Repo.discover(gpa, io, bare_path);
    defer bare.deinit(gpa);
    try testing.expectEqual(@as(?[]u8, null), bare.work_tree);
    const head = try bare.resolveRev(gpa, io, "HEAD");
    try expectOid(try f.rev(bare_path, "HEAD"), head);
    try expectOid(try f.rev(bare_path, "v1.0^{commit}"), try bare.resolveRev(gpa, io, "v1.0"));
    const readme = try bare.readPath(gpa, io, head, "docs/guide/intro.md");
    defer gpa.free(readme);
    var buf: [Oid.max_hex_len]u8 = undefined;
    const spec = try std.fmt.allocPrint(gpa, "{s}:docs/guide/intro.md", .{head.hex(&buf)});
    defer gpa.free(spec);
    const want = try f.run(bare_path, &.{ "show", spec });
    defer gpa.free(want);
    try testing.expectEqualSlices(u8, want, readme);
}

test "alternates supply objects the clone does not hold" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try setupFixture(gpa, io);
    defer f.deinit();

    gpa.free(try f.run(f.root, &.{ "clone", "-q", "--shared", "repo", "shared" }));
    const shared_path = try f.path("shared");
    defer gpa.free(shared_path);
    const alternates = try std.fs.path.join(gpa, &.{ shared_path, ".git", "objects", "info", "alternates" });
    defer gpa.free(alternates);
    try Dir.cwd().access(io, alternates, .{});

    var repo = try Repo.discover(gpa, io, shared_path);
    defer repo.deinit(gpa);
    const head = try repo.resolveRev(gpa, io, "HEAD");
    try expectOid(try f.rev(shared_path, "HEAD"), head);
    const got = try repo.readPath(gpa, io, head, "README.md");
    defer gpa.free(got);
    var buf: [Oid.max_hex_len]u8 = undefined;
    const spec = try std.fmt.allocPrint(gpa, "{s}:README.md", .{head.hex(&buf)});
    defer gpa.free(spec);
    const want = try f.run(shared_path, &.{ "show", spec });
    defer gpa.free(want);
    try testing.expectEqualSlices(u8, want, got);
}

test "sha256 repositories" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try newFixture(gpa, io);
    defer f.deinit();

    const out = f.run(f.root, &.{ "init", "-q", "--object-format=sha256", "repo" }) catch |err| switch (err) {
        error.GitFailed => return error.SkipZigTest,
        else => return err,
    };
    gpa.free(out);
    try f.tmp.dir.writeFile(io, .{ .sub_path = "repo/README.md", .data = "# wide\n" });
    try f.gitDiscard(&.{ "add", "-A" });
    try f.gitDiscard(&.{ "commit", "-q", "-m", "wide" });

    if (!wide_oids) {
        try testing.expectError(error.UnsupportedObjectFormat, Repo.discover(gpa, io, f.repo_path));
        return;
    }
    var repo = try Repo.discover(gpa, io, f.repo_path);
    defer repo.deinit(gpa);
    const head = try repo.resolveRev(gpa, io, "HEAD");
    try testing.expectEqual(@as(u8, 32), head.len);
    try expectOid(try f.rev(f.repo_path, "HEAD"), head);
    const got = try repo.readPath(gpa, io, head, "README.md");
    defer gpa.free(got);
    try testing.expectEqualStrings("# wide\n", got);
    const entries = try repo.listTree(gpa, io, head, "");
    defer freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(@as(u8, 32), entries[0].oid.len);
}

test "reftable repositories are reported, not misread" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try newFixture(gpa, io);
    defer f.deinit();

    const out = f.run(f.root, &.{ "init", "-q", "--ref-format=reftable", "repo" }) catch |err| switch (err) {
        error.GitFailed => return error.SkipZigTest,
        else => return err,
    };
    gpa.free(out);
    try testing.expectError(error.UnsupportedRefStorage, Repo.discover(gpa, io, f.repo_path));
}

test "an object whose content does not match its id is rejected" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try newFixture(gpa, io);
    defer f.deinit();

    gpa.free(try f.run(f.root, &.{ "init", "-q", "repo" }));
    try f.tmp.dir.writeFile(io, .{ .sub_path = "repo/README.md", .data = "good\n" });
    try f.gitDiscard(&.{ "add", "-A" });
    try f.gitDiscard(&.{ "commit", "-q", "-m", "one" });

    const good = try f.git(&.{ "rev-parse", "HEAD:README.md" });
    defer gpa.free(good);
    const good_hex = std.mem.trim(u8, good, "\n");
    try f.tmp.dir.writeFile(io, .{ .sub_path = "evil.txt", .data = "evil\n" });
    const evil = try f.git(&.{ "hash-object", "-w", "../evil.txt" });
    defer gpa.free(evil);
    const evil_hex = std.mem.trim(u8, evil, "\n");

    const good_path = try std.fmt.allocPrint(gpa, "repo/.git/objects/{s}/{s}", .{ good_hex[0..2], good_hex[2..] });
    defer gpa.free(good_path);
    const evil_path = try std.fmt.allocPrint(gpa, "repo/.git/objects/{s}/{s}", .{ evil_hex[0..2], evil_hex[2..] });
    defer gpa.free(evil_path);
    const evil_bytes = try f.tmp.dir.readFileAlloc(io, evil_path, gpa, .limited(1 << 20));
    defer gpa.free(evil_bytes);
    try f.tmp.dir.deleteFile(io, good_path);
    try f.tmp.dir.writeFile(io, .{ .sub_path = good_path, .data = evil_bytes });

    var repo = try Repo.discover(gpa, io, f.repo_path);
    defer repo.deinit(gpa);
    const head = try repo.resolveRev(gpa, io, "HEAD");
    try testing.expectError(error.CorruptObject, repo.readPath(gpa, io, head, "README.md"));
}

test "discover disables owner validation" {
    var f = try newFixture(testing.allocator, testing.io);
    defer f.deinit();
    testing.allocator.free(try f.run(f.root, &.{ "init", "-q", "repo" }));
    var repo = try Repo.discover(testing.allocator, testing.io, f.repo_path);
    defer repo.deinit(testing.allocator);
    var enabled: c_int = -1;
    try testing.expect(c.git_libgit2_opts(c.GIT_OPT_GET_OWNER_VALIDATION, &enabled) >= 0);
    try testing.expectEqual(@as(c_int, 0), enabled);
}

test "discover fails outside a repository" {
    try testing.expectError(error.NotARepository, Repo.discover(testing.allocator, testing.io, "/"));
}

fn commitFiles(f: *Fixture, msg: []const u8, files: []const [2][]const u8) !void {
    for (files) |file| {
        if (std.fs.path.dirname(file[0])) |dir| try f.tmp.dir.createDirPath(f.io, dir);
        try f.tmp.dir.writeFile(f.io, .{ .sub_path = file[0], .data = file[1] });
    }
    try f.gitDiscard(&.{ "add", "-A" });
    try f.gitDiscard(&.{ "commit", "-q", "-m", msg });
}

fn gitCount(f: *Fixture, rev: []const u8) !u64 {
    const out = try f.git(&.{ "rev-list", "--count", rev });
    defer f.gpa.free(out);
    return std.fmt.parseInt(u64, std.mem.trim(u8, out, " \r\n"), 10);
}

fn expectLastCommitsMatchGit(f: *Fixture, repo: *const Repo, head: Oid, dir: []const u8) !void {
    const gpa = f.gpa;
    const got = try repo.lastCommits(gpa, f.io, head, dir);
    defer freePathCommits(gpa, got);

    const spec = try std.fmt.allocPrint(gpa, "HEAD:{s}", .{dir});
    defer gpa.free(spec);
    const listing = try f.git(&.{ "ls-tree", "--name-only", spec });
    defer gpa.free(listing);
    var names = std.mem.tokenizeScalar(u8, listing, '\n');
    var i: usize = 0;
    while (names.next()) |name| : (i += 1) {
        try testing.expectEqualStrings(name, got[i].name);
        const full = try std.fs.path.join(gpa, &.{ dir, name });
        defer gpa.free(full);
        const want = try f.git(&.{ "log", "-1", "--format=%H", "HEAD", "--", full });
        defer gpa.free(want);
        try expectOid(try Oid.parseHex(std.mem.trim(u8, want, "\n")), got[i].commit.oid);
    }
    try testing.expectEqual(i, got.len);
}

test "headBranch on a branch, detached and unborn" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try newFixture(gpa, io);
    defer f.deinit();
    gpa.free(try f.run(f.root, &.{ "init", "-q", "repo" }));

    {
        var repo = try Repo.discover(gpa, io, f.repo_path);
        defer repo.deinit(gpa);
        const name = (try repo.headBranch(gpa, io)).?;
        defer gpa.free(name);
        try testing.expectEqualStrings("main", name);
    }

    try commitFiles(&f, "one", &.{.{ "repo/a.txt", "a\n" }});
    try f.gitDiscard(&.{ "checkout", "-q", "-b", "topic/nested" });
    {
        var repo = try Repo.discover(gpa, io, f.repo_path);
        defer repo.deinit(gpa);
        const name = (try repo.headBranch(gpa, io)).?;
        defer gpa.free(name);
        try testing.expectEqualStrings("topic/nested", name);
    }

    try f.gitDiscard(&.{ "checkout", "-q", "--detach" });
    var repo = try Repo.discover(gpa, io, f.repo_path);
    defer repo.deinit(gpa);
    try testing.expectEqual(@as(?[]u8, null), try repo.headBranch(gpa, io));
}

test "commitInfo and commitCount agree with git" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try setupFixture(gpa, io);
    defer f.deinit();
    try f.tmp.dir.writeFile(io, .{ .sub_path = "repo/extra.txt", .data = "x\n" });
    try f.gitDiscard(&.{ "add", "-A" });
    try f.gitDiscard(&.{ "-c", "user.name=Ada L\xc3\xb6velace", "-c", "user.email=ada@example.org", "commit", "-q", "-m", "headline here  ", "-m", "body text" });
    try f.gitDiscard(&.{ "checkout", "-q", "-b", "side", "HEAD~3" });
    try f.tmp.dir.writeFile(io, .{ .sub_path = "repo/side.txt", .data = "s\n" });
    try f.gitDiscard(&.{ "add", "-A" });
    try f.gitDiscard(&.{ "commit", "-q", "-m", "side work" });
    try f.gitDiscard(&.{ "checkout", "-q", "main" });
    try f.gitDiscard(&.{ "merge", "-q", "--no-ff", "-m", "merge side", "side" });

    var repo = try Repo.discover(gpa, io, f.repo_path);
    defer repo.deinit(gpa);

    for ([_][]const u8{ "HEAD", "HEAD~1", "HEAD^2", "feature", "side", "v1.0^{commit}" }) |name| {
        const oid = try f.rev(f.repo_path, name);
        try testing.expectEqual(try gitCount(&f, name), try repo.commitCount(gpa, io, oid));
    }

    const author_commit = try repo.commitInfo(gpa, io, try f.rev(f.repo_path, "HEAD^"));
    defer freeCommit(gpa, author_commit);
    try testing.expectEqualStrings("headline here", author_commit.summary);
    try testing.expect(author_commit.has_body);
    try testing.expectEqualStrings("Ada L\xc3\xb6velace", author_commit.author_name);
    try testing.expectEqualStrings("ada@example.org", author_commit.author_email);
    try expectOid(try f.rev(f.repo_path, "HEAD^"), author_commit.oid);
    const at = try f.git(&.{ "log", "-1", "--format=%at", "HEAD^" });
    defer gpa.free(at);
    try testing.expectEqual(try std.fmt.parseInt(i64, std.mem.trim(u8, at, "\n"), 10), author_commit.author_time);
    const ct = try f.git(&.{ "log", "-1", "--format=%ct", "HEAD^" });
    defer gpa.free(ct);
    try testing.expectEqual(try std.fmt.parseInt(i64, std.mem.trim(u8, ct, "\n"), 10), author_commit.commit_time);

    const merge = try repo.commitInfo(gpa, io, try f.rev(f.repo_path, "HEAD"));
    defer freeCommit(gpa, merge);
    try testing.expectEqualStrings("merge side", merge.summary);
    try testing.expect(!merge.has_body);
    try testing.expectEqualStrings("Test", merge.author_name);
    try testing.expectEqualStrings("test@example.com", merge.author_email);

    const missing = try Oid.parseHex("0123456789012345678901234567890123456789");
    try testing.expectError(error.ObjectNotFound, repo.commitInfo(gpa, io, missing));
}

test "remoteTip and newestByAuthor find the pushed commit to ask the forge about" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try setupFixture(gpa, io);
    defer f.deinit();
    try f.tmp.dir.writeFile(io, .{ .sub_path = "repo/extra.txt", .data = "x\n" });
    try f.gitDiscard(&.{ "add", "-A" });
    try f.gitDiscard(&.{ "-c", "user.email=Ada@Example.org", "commit", "-q", "-m", "local only" });

    var repo = try Repo.discover(gpa, io, f.repo_path);
    defer repo.deinit(gpa);

    // The fixture's origin/main sits one commit behind the loose revision.
    const tip = (try repo.remoteTip(gpa, io, null, "main")).?;
    try expectOid(try f.rev(f.repo_path, "origin/main"), tip);
    // No origin/HEAD in a repository that was never cloned.
    try testing.expect(try repo.remoteTip(gpa, io, "origin", "no-such-branch") == null);
    try testing.expect(try repo.remoteTip(gpa, io, "upstream", "main") == null);

    try expectOid(tip, (try repo.newestByAuthor(gpa, io, tip, "TEST@example.com", 10)).?);
    const head = try f.rev(f.repo_path, "HEAD");
    try expectOid(head, (try repo.newestByAuthor(gpa, io, head, "ada@example.org", 10)).?);
    try testing.expect(try repo.newestByAuthor(gpa, io, tip, "ada@example.org", 10) == null);
}

test "lastCommits finds the newest commit touching each entry" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try newFixture(gpa, io);
    defer f.deinit();
    gpa.free(try f.run(f.root, &.{ "init", "-q", "repo" }));

    try commitFiles(&f, "root", &.{
        .{ "repo/old.txt", "old\n" },
        .{ "repo/a.txt", "a1\n" },
        .{ "repo/b.txt", "b1\n" },
        .{ "repo/docs/x.md", "x1\n" },
        .{ "repo/docs/z.md", "z1\n" },
        .{ "repo/docs/deep/n.md", "n1\n" },
    });
    try commitFiles(&f, "touch a", &.{.{ "repo/a.txt", "a2\n" }});
    try commitFiles(&f, "touch inner x", &.{.{ "repo/docs/x.md", "x2\n" }});
    try commitFiles(&f, "touch deep", &.{.{ "repo/docs/deep/n.md", "n2\n" }});
    try commitFiles(&f, "touch b", &.{.{ "repo/b.txt", "b2\n" }});
    try f.gitDiscard(&.{ "checkout", "-q", "-b", "side", "HEAD~2" });
    try commitFiles(&f, "side only", &.{.{ "repo/side.txt", "s\n" }});
    try f.gitDiscard(&.{ "checkout", "-q", "main" });
    try f.gitDiscard(&.{ "merge", "-q", "--no-ff", "-m", "merge side", "side" });

    var repo = try Repo.discover(gpa, io, f.repo_path);
    defer repo.deinit(gpa);
    const head = try repo.resolveRev(gpa, io, "HEAD");

    const root = try repo.lastCommits(gpa, io, head, "");
    defer freePathCommits(gpa, root);
    const want = [_]struct { []const u8, []const u8 }{
        .{ "a.txt", "touch a" },
        .{ "b.txt", "touch b" },
        .{ "docs", "touch deep" },
        .{ "old.txt", "root" },
        // Merges are looked through: side.txt matches the merge's second parent.
        .{ "side.txt", "side only" },
    };
    try testing.expectEqual(want.len, root.len);
    for (want, root) |w, got| {
        try testing.expectEqualStrings(w[0], got.name);
        try testing.expectEqualStrings(w[1], got.commit.summary);
    }

    try expectLastCommitsMatchGit(&f, &repo, head, "");
    try expectLastCommitsMatchGit(&f, &repo, head, "docs");
    try expectLastCommitsMatchGit(&f, &repo, head, "docs/deep/");

    const docs = try repo.lastCommits(gpa, io, head, "docs");
    defer freePathCommits(gpa, docs);
    try testing.expectEqualStrings("root", docs[2].commit.summary);
    try testing.expectEqualStrings("touch inner x", docs[1].commit.summary);

    const older = try repo.lastCommits(gpa, io, try f.rev(f.repo_path, "HEAD~1"), "");
    defer freePathCommits(gpa, older);
    try testing.expectEqual(@as(usize, 4), older.len);

    try testing.expectError(error.PathNotFound, repo.lastCommits(gpa, io, head, "nope"));
    try testing.expectError(error.NotDir, repo.lastCommits(gpa, io, head, "a.txt"));
}
