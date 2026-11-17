//! HTTP GET with an on-disk cache under `$XDG_CACHE_HOME/git-preview/http`.
//! Network failures fall back to any cached copy, however stale, so rendering degrades instead of failing.

const Fetcher = @This();

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.net);

gpa: std.mem.Allocator,
io: Io,
client: std.http.Client,
cache: ?Io.Dir,
/// Never touch the network; serve only what is cached.
offline: bool,

pub fn init(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, offline: bool) Fetcher {
    return .{
        .gpa = gpa,
        .io = io,
        .client = .{ .allocator = gpa, .io = io },
        .cache = openCache(io, env) catch |err| blk: {
            log.warn("http cache unavailable: {s}", .{@errorName(err)});
            break :blk null;
        },
        .offline = offline,
    };
}

pub fn deinit(self: *Fetcher) void {
    self.client.deinit();
    if (self.cache) |d| d.close(self.io);
}

fn openCache(io: Io, env: *const std.process.Environ.Map) !Io.Dir {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = if (env.get("XDG_CACHE_HOME")) |x|
        try std.fmt.bufPrint(&buf, "{s}/git-preview/http", .{x})
    else if (env.get("HOME")) |h|
        try std.fmt.bufPrint(&buf, "{s}/.cache/git-preview/http", .{h})
    else
        return error.NoCacheDir;
    return Io.Dir.cwd().createDirPathOpen(io, path, .{});
}

pub const Request = struct {
    url: []const u8,
    /// Seconds a cached copy stays fresh; null caches forever (content-addressed assets).
    ttl: ?i64,
    accept: ?[]const u8 = null,
    /// Full `Authorization` header value; it never affects the cache key.
    authorization: ?[]const u8 = null,
};

pub const Response = struct {
    status: std.http.Status,
    body: []u8,
    /// Served from the cache without contacting the network.
    cached: bool,
};

/// Returns the body for 2xx responses, cached or fresh. Other statuses are returned uncached
/// with an empty body so callers can retry with credentials.
pub fn get(self: *Fetcher, req: Request) !Response {
    var key_buf: [64]u8 = undefined;
    const key = cacheKey(req, &key_buf);

    if (self.readCached(key, req.ttl, false)) |body| return .{ .status = .ok, .body = body, .cached = true };
    if (self.offline) {
        if (self.readCached(key, null, true)) |body| return .{ .status = .ok, .body = body, .cached = true };
        return error.Offline;
    }

    var out: Io.Writer.Allocating = .init(self.gpa);
    defer out.deinit();
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(self.gpa);
    if (req.accept) |a| try headers.append(self.gpa, .{ .name = "accept", .value = a });
    var privileged: std.ArrayList(std.http.Header) = .empty;
    defer privileged.deinit(self.gpa);
    if (req.authorization) |a| try privileged.append(self.gpa, .{ .name = "authorization", .value = a });

    const result = self.client.fetch(.{
        .location = .{ .url = req.url },
        .response_writer = &out.writer,
        .extra_headers = headers.items,
        .privileged_headers = privileged.items,
    }) catch |err| {
        log.warn("GET {s} failed: {s}", .{ req.url, @errorName(err) });
        if (self.readCached(key, null, true)) |body| return .{ .status = .ok, .body = body, .cached = true };
        return err;
    };
    log.debug("GET {s} -> {d}", .{ req.url, @backingInt(result.status) });

    if (result.status.class() != .success) return .{ .status = result.status, .body = &.{}, .cached = false };
    const body = try out.toOwnedSlice();
    if (self.cache) |dir| dir.writeFile(self.io, .{ .sub_path = key, .data = body }) catch |err| {
        log.warn("cannot cache {s}: {s}", .{ req.url, @errorName(err) });
    };
    return .{ .status = result.status, .body = body, .cached = false };
}

fn cacheKey(req: Request, buf: *[64]u8) []const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(req.url);
    h.update("\x00");
    h.update(req.accept orelse "");
    var digest: [32]u8 = undefined;
    h.final(&digest);
    buf.* = std.fmt.bytesToHex(digest, .lower);
    return buf;
}

fn readCached(self: *Fetcher, key: []const u8, ttl: ?i64, ignore_age: bool) ?[]u8 {
    const dir = self.cache orelse return null;
    if (!ignore_age) {
        if (ttl) |max_age| {
            const st = dir.statFile(self.io, key, .{}) catch return null;
            const age = Io.Clock.real.now(self.io).toSeconds() - st.mtime.toSeconds();
            if (age > max_age) return null;
        }
    }
    return dir.readFileAlloc(self.io, key, self.gpa, .limited(64 << 20)) catch null;
}
