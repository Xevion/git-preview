//! Read-only SHA-1 object database: loose objects and pack files (idx v2).
//! Alternates (`objects/info/alternates`) are not consulted.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

pub const Oid = struct {
    bytes: [20]u8,

    pub const hex_len = 40;

    pub fn parseHex(hex: []const u8) error{InvalidOid}!Oid {
        if (hex.len != hex_len) return error.InvalidOid;
        var oid: Oid = undefined;
        _ = std.fmt.hexToBytes(&oid.bytes, hex) catch return error.InvalidOid;
        return oid;
    }

    pub fn toHex(self: Oid) [hex_len]u8 {
        return std.fmt.bytesToHex(self.bytes, .lower);
    }

    pub fn eql(a: Oid, b: Oid) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    pub fn format(self: Oid, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll(&self.toHex());
    }
};

pub const Kind = enum { commit, tree, blob, tag };

pub const Object = struct {
    kind: Kind,
    data: []u8,

    pub fn deinit(self: Object, gpa: Allocator) void {
        gpa.free(self.data);
    }
};

const max_delta_depth = 10_000;
const max_loose_file_len = 1 << 31;

/// A hex prefix of 1 to 40 digits, compared nibble-wise against object ids.
pub const Prefix = struct {
    bytes: [20]u8 = @splat(0),
    nibbles: u8,

    pub fn parse(hex: []const u8) error{InvalidOid}!Prefix {
        if (hex.len == 0 or hex.len > Oid.hex_len) return error.InvalidOid;
        var p: Prefix = .{ .nibbles = @intCast(hex.len) };
        for (hex, 0..) |c, i| {
            const digit = std.fmt.charToDigit(c, 16) catch return error.InvalidOid;
            p.bytes[i / 2] |= if (i % 2 == 0) digit << 4 else digit;
        }
        return p;
    }

    /// Orders `entry` relative to the prefix; `.eq` means the entry starts with it.
    pub fn order(p: Prefix, entry: *const [20]u8) std.math.Order {
        const full = p.nibbles / 2;
        switch (std.mem.order(u8, entry[0..full], p.bytes[0..full])) {
            .eq => {},
            else => |o| return o,
        }
        if (p.nibbles % 2 == 1) return std.math.order(entry[full] >> 4, p.bytes[full] >> 4);
        return .eq;
    }
};

fn readExact(file: File, io: Io, buf: []u8, offset: u64) !void {
    const n = try file.readPositionalAll(io, buf, offset);
    if (n != buf.len) return error.CorruptObject;
}

const Pack = struct {
    idx: File,
    pack: File,
    fanout: [256]u32,
    count: u32,

    const header_len = 8 + 256 * 4;
    const idx_magic = [4]u8{ 0xff, 0x74, 0x4f, 0x63 };

    fn open(io: Io, dir: Dir, idx_name: []const u8) !Pack {
        const stem = std.mem.cutSuffix(u8, idx_name, ".idx") orelse return error.CorruptIndex;
        var name_buf: [512]u8 = undefined;
        const pack_name = try std.fmt.bufPrint(&name_buf, "{s}.pack", .{stem});

        const idx = try dir.openFile(io, idx_name, .{});
        errdefer idx.close(io);
        const pack = try dir.openFile(io, pack_name, .{});
        errdefer pack.close(io);

        var hdr: [header_len]u8 = undefined;
        readExact(idx, io, &hdr, 0) catch return error.CorruptIndex;
        if (!std.mem.eql(u8, hdr[0..4], &idx_magic)) return error.UnsupportedPackIndex;
        if (std.mem.readInt(u32, hdr[4..8], .big) != 2) return error.UnsupportedPackIndex;

        var fanout: [256]u32 = undefined;
        var prev: u32 = 0;
        for (&fanout, 0..) |*f, i| {
            f.* = std.mem.readInt(u32, hdr[8 + i * 4 ..][0..4], .big);
            if (f.* < prev) return error.CorruptIndex;
            prev = f.*;
        }

        var pack_hdr: [12]u8 = undefined;
        readExact(pack, io, &pack_hdr, 0) catch return error.CorruptObject;
        if (!std.mem.eql(u8, pack_hdr[0..4], "PACK")) return error.CorruptObject;
        const version = std.mem.readInt(u32, pack_hdr[4..8], .big);
        if (version != 2 and version != 3) return error.CorruptObject;
        if (std.mem.readInt(u32, pack_hdr[8..12], .big) != prev) return error.CorruptIndex;

        return .{ .idx = idx, .pack = pack, .fanout = fanout, .count = prev };
    }

    fn close(self: Pack, io: Io) void {
        self.idx.close(io);
        self.pack.close(io);
    }

    fn readSha(self: *const Pack, io: Io, i: u32) ![20]u8 {
        var sha: [20]u8 = undefined;
        readExact(self.idx, io, &sha, header_len + @as(u64, i) * 20) catch return error.CorruptIndex;
        return sha;
    }

    const Bounds = struct { index: u32, end: u32 };

    /// First index in the fanout bucket whose entry is not below `prefix`.
    fn lowerBound(self: *const Pack, io: Io, prefix: Prefix) !Bounds {
        const first = prefix.bytes[0];
        var lo: u32 = if (first == 0) 0 else self.fanout[first - 1];
        const end = self.fanout[first];
        var hi = end;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const sha = try self.readSha(io, mid);
            if (prefix.order(&sha) == .lt) lo = mid + 1 else hi = mid;
        }
        return .{ .index = lo, .end = end };
    }

    fn offsetOf(self: *const Pack, io: Io, i: u32) !u64 {
        const off_table: u64 = header_len + 24 * @as(u64, self.count);
        var word: [4]u8 = undefined;
        readExact(self.idx, io, &word, off_table + 4 * @as(u64, i)) catch return error.CorruptIndex;
        const v = std.mem.readInt(u32, &word, .big);
        if (v & 0x8000_0000 == 0) return v;
        var wide: [8]u8 = undefined;
        const large = off_table + 4 * @as(u64, self.count) + 8 * @as(u64, v & 0x7fff_ffff);
        readExact(self.idx, io, &wide, large) catch return error.CorruptIndex;
        return std.mem.readInt(u64, &wide, .big);
    }

    fn find(self: *const Pack, io: Io, oid: Oid) !?u64 {
        const prefix: Prefix = .{ .bytes = oid.bytes, .nibbles = Oid.hex_len };
        const lb = try self.lowerBound(io, prefix);
        if (lb.index >= lb.end) return null;
        const sha = try self.readSha(io, lb.index);
        if (!std.mem.eql(u8, &sha, &oid.bytes)) return null;
        return try self.offsetOf(io, lb.index);
    }

    const EntryType = enum(u3) {
        commit = 1,
        tree = 2,
        blob = 3,
        tag = 4,
        ofs_delta = 6,
        ref_delta = 7,
        _,
    };

    const EntryHeader = struct {
        kind: EntryType,
        size: usize,
        data_offset: u64,
        base_offset: u64 = 0,
        base_oid: Oid = undefined,
    };

    fn readEntryHeader(self: *const Pack, io: Io, offset: u64) !EntryHeader {
        var buf: [64]u8 = undefined;
        const n = try self.pack.readPositionalAll(io, &buf, offset);
        const b = buf[0..n];
        if (b.len == 0) return error.CorruptObject;

        var c = b[0];
        var i: usize = 1;
        var h: EntryHeader = .{ .kind = @fromBackingInt(@intCast((c >> 4) & 7)), .size = 0, .data_offset = 0 };
        var size: u64 = c & 0xf;
        var shift: u6 = 4;
        while (c & 0x80 != 0) {
            if (i >= b.len or shift > 56) return error.CorruptObject;
            c = b[i];
            i += 1;
            size |= @as(u64, c & 0x7f) << shift;
            shift += 7;
        }
        h.size = std.math.cast(usize, size) orelse return error.ObjectTooLarge;

        switch (h.kind) {
            .commit, .tree, .blob, .tag => {},
            .ofs_delta => {
                if (i >= b.len) return error.CorruptObject;
                c = b[i];
                i += 1;
                var back: u64 = c & 0x7f;
                while (c & 0x80 != 0) {
                    if (i >= b.len or back >= 1 << 56) return error.CorruptObject;
                    c = b[i];
                    i += 1;
                    back = ((back + 1) << 7) | (c & 0x7f);
                }
                if (back == 0 or back > offset) return error.CorruptObject;
                h.base_offset = offset - back;
            },
            .ref_delta => {
                if (b.len - i < 20) return error.CorruptObject;
                h.base_oid = .{ .bytes = b[i..][0..20].* };
                i += 20;
            },
            _ => return error.CorruptObject,
        }
        h.data_offset = offset + i;
        return h;
    }
};

const Located = struct { pack: *const Pack, offset: u64 };

pub const Odb = struct {
    objects_dir: Dir,
    packs: []Pack,

    /// Takes ownership of `objects_dir`; release it with `deinit`.
    pub fn init(gpa: Allocator, io: Io, objects_dir: Dir) !Odb {
        var pack_dir = objects_dir.openDir(io, "pack", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return .{ .objects_dir = objects_dir, .packs = &.{} },
            else => return err,
        };
        defer pack_dir.close(io);

        var packs: std.ArrayList(Pack) = .empty;
        errdefer {
            for (packs.items) |p| p.close(io);
            packs.deinit(gpa);
        }
        var it = pack_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
            const pack = Pack.open(io, pack_dir, entry.name) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            errdefer pack.close(io);
            try packs.append(gpa, pack);
        }
        return .{ .objects_dir = objects_dir, .packs = try packs.toOwnedSlice(gpa) };
    }

    pub fn deinit(self: *Odb, gpa: Allocator, io: Io) void {
        for (self.packs) |p| p.close(io);
        gpa.free(self.packs);
        self.objects_dir.close(io);
        self.* = undefined;
    }

    pub fn read(self: *const Odb, gpa: Allocator, io: Io, oid: Oid) !Object {
        if (try self.findInPacks(io, oid)) |loc| return self.readPacked(gpa, io, loc);
        return (try self.readLoose(gpa, io, oid)) orelse error.ObjectNotFound;
    }

    /// Resolves a unique hex prefix of at least 4 digits over loose and packed objects.
    pub fn resolvePrefix(self: *const Odb, io: Io, hex: []const u8) !Oid {
        if (hex.len < 4) return error.PrefixTooShort;
        const prefix = try Prefix.parse(hex);
        var found: ?Oid = null;

        for (self.packs) |*pack| {
            const lb = try pack.lowerBound(io, prefix);
            var i = lb.index;
            while (i < lb.end) : (i += 1) {
                const sha = try pack.readSha(io, i);
                if (prefix.order(&sha) != .eq) break;
                try consider(&found, .{ .bytes = sha });
            }
        }

        const dir_name = std.fmt.bytesToHex([1]u8{prefix.bytes[0]}, .lower);
        var bucket = self.objects_dir.openDir(io, &dir_name, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return found orelse error.ObjectNotFound,
            else => return err,
        };
        defer bucket.close(io);
        var it = bucket.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or entry.name.len != Oid.hex_len - 2) continue;
            var full: [Oid.hex_len]u8 = undefined;
            @memcpy(full[0..2], &dir_name);
            @memcpy(full[2..], entry.name);
            const oid = Oid.parseHex(&full) catch continue;
            if (prefix.order(&oid.bytes) == .eq) try consider(&found, oid);
        }
        return found orelse error.ObjectNotFound;
    }

    fn consider(found: *?Oid, oid: Oid) !void {
        if (found.*) |f| {
            if (!f.eql(oid)) return error.AmbiguousPrefix;
        } else found.* = oid;
    }

    fn findInPacks(self: *const Odb, io: Io, oid: Oid) !?Located {
        for (self.packs) |*pack| {
            if (try pack.find(io, oid)) |offset| return .{ .pack = pack, .offset = offset };
        }
        return null;
    }

    fn readLoose(self: *const Odb, gpa: Allocator, io: Io, oid: Oid) !?Object {
        const hex = oid.toHex();
        var path: [Oid.hex_len + 1]u8 = undefined;
        @memcpy(path[0..2], hex[0..2]);
        path[2] = '/';
        @memcpy(path[3..], hex[2..]);

        const compressed = self.objects_dir.readFileAlloc(io, &path, gpa, .limited(max_loose_file_len)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer gpa.free(compressed);

        var in: Io.Reader = .fixed(compressed);
        var window: [flate.max_window_len]u8 = undefined;
        var d: flate.Decompress = .init(&in, .zlib, &window);
        const raw = d.reader.allocRemaining(gpa, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.CorruptObject,
        };
        defer gpa.free(raw);

        const nul = std.mem.indexOfScalar(u8, raw, 0) orelse return error.CorruptObject;
        const header = raw[0..nul];
        const space = std.mem.indexOfScalar(u8, header, ' ') orelse return error.CorruptObject;
        const kind = std.meta.stringToEnum(Kind, header[0..space]) orelse return error.CorruptObject;
        const size = std.fmt.parseInt(usize, header[space + 1 ..], 10) catch return error.CorruptObject;
        const body = raw[nul + 1 ..];
        if (body.len != size) return error.CorruptObject;
        return .{ .kind = kind, .data = try gpa.dupe(u8, body) };
    }

    fn readPacked(self: *const Odb, gpa: Allocator, io: Io, start: Located) !Object {
        var deltas: std.ArrayList([]u8) = .empty;
        defer {
            for (deltas.items) |d| gpa.free(d);
            deltas.deinit(gpa);
        }

        var loc = start;
        var base: Object = undefined;
        while (true) {
            if (deltas.items.len > max_delta_depth) return error.DeltaChainTooDeep;
            const h = try loc.pack.readEntryHeader(io, loc.offset);
            switch (h.kind) {
                .commit, .tree, .blob, .tag => {
                    base = .{
                        .kind = switch (h.kind) {
                            .commit => .commit,
                            .tree => .tree,
                            .blob => .blob,
                            else => .tag,
                        },
                        .data = try inflateAt(gpa, io, loc.pack.pack, h.data_offset, h.size),
                    };
                    break;
                },
                .ofs_delta => {
                    const d = try inflateAt(gpa, io, loc.pack.pack, h.data_offset, h.size);
                    errdefer gpa.free(d);
                    try deltas.append(gpa, d);
                    loc.offset = h.base_offset;
                },
                .ref_delta => {
                    const d = try inflateAt(gpa, io, loc.pack.pack, h.data_offset, h.size);
                    errdefer gpa.free(d);
                    try deltas.append(gpa, d);
                    if (try self.findInPacks(io, h.base_oid)) |next| {
                        loc = next;
                    } else {
                        base = (try self.readLoose(gpa, io, h.base_oid)) orelse return error.ObjectNotFound;
                        break;
                    }
                },
                _ => return error.CorruptObject,
            }
        }
        errdefer gpa.free(base.data);

        var i = deltas.items.len;
        while (i > 0) {
            i -= 1;
            const next = try applyDelta(gpa, base.data, deltas.items[i]);
            gpa.free(base.data);
            base.data = next;
        }
        return base;
    }
};

fn inflateAt(gpa: Allocator, io: Io, file: File, offset: u64, size: usize) ![]u8 {
    var in_buf: [4096]u8 = undefined;
    var fr = file.reader(io, &in_buf);
    try fr.seekTo(offset);
    var window: [flate.max_window_len]u8 = undefined;
    var d: flate.Decompress = .init(&fr.interface, .zlib, &window);

    const out = try gpa.alloc(u8, size);
    errdefer gpa.free(out);
    d.reader.readSliceAll(out) catch |err| switch (err) {
        error.EndOfStream => return error.CorruptObject,
        error.ReadFailed => {
            if (d.err) |de| if (de != error.ReadFailed) return error.CorruptObject;
            return fr.err orelse error.CorruptObject;
        },
    };
    return out;
}

fn readVarint(buf: []const u8, pos: *usize) !u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (pos.* >= buf.len or shift > 56) return error.CorruptDelta;
        const c = buf[pos.*];
        pos.* += 1;
        result |= @as(u64, c & 0x7f) << shift;
        if (c & 0x80 == 0) return result;
        shift += 7;
    }
}

/// Applies a git delta (copy/insert instruction stream) to `base`.
pub fn applyDelta(gpa: Allocator, base: []const u8, delta: []const u8) ![]u8 {
    var pos: usize = 0;
    const base_size = try readVarint(delta, &pos);
    const result_size = try readVarint(delta, &pos);
    if (base_size != base.len) return error.CorruptDelta;
    const n = std.math.cast(usize, result_size) orelse return error.CorruptDelta;

    const out = try gpa.alloc(u8, n);
    errdefer gpa.free(out);
    var w: usize = 0;
    while (pos < delta.len) {
        const op = delta[pos];
        pos += 1;
        if (op & 0x80 != 0) {
            var off: usize = 0;
            var size: usize = 0;
            inline for (0..4) |i| {
                if (op & (1 << i) != 0) {
                    if (pos >= delta.len) return error.CorruptDelta;
                    off |= @as(usize, delta[pos]) << (8 * i);
                    pos += 1;
                }
            }
            inline for (0..3) |i| {
                if (op & (0x10 << i) != 0) {
                    if (pos >= delta.len) return error.CorruptDelta;
                    size |= @as(usize, delta[pos]) << (8 * i);
                    pos += 1;
                }
            }
            if (size == 0) size = 0x10000;
            if (off > base.len or size > base.len - off or size > n - w) return error.CorruptDelta;
            @memcpy(out[w..][0..size], base[off..][0..size]);
            w += size;
        } else if (op != 0) {
            if (op > delta.len - pos or op > n - w) return error.CorruptDelta;
            @memcpy(out[w..][0..op], delta[pos..][0..op]);
            pos += op;
            w += op;
        } else {
            return error.CorruptDelta;
        }
    }
    if (w != n) return error.CorruptDelta;
    return out;
}

const testing = std.testing;

test "Oid hex round trip" {
    const hex = "0123456789abcdef0123456789abcdef01234567";
    const oid = try Oid.parseHex(hex);
    try testing.expectEqualStrings(hex, &oid.toHex());
    try testing.expectError(error.InvalidOid, Oid.parseHex("abc"));
    try testing.expectError(error.InvalidOid, Oid.parseHex("zz23456789abcdef0123456789abcdef01234567"));
}

test "Prefix ordering handles odd nibble counts" {
    const p = try Prefix.parse("abc");
    var e: [20]u8 = @splat(0);
    e[0] = 0xab;
    e[1] = 0xcf;
    try testing.expectEqual(std.math.Order.eq, p.order(&e));
    e[1] = 0xbf;
    try testing.expectEqual(std.math.Order.lt, p.order(&e));
    e[0] = 0xac;
    e[1] = 0x00;
    try testing.expectEqual(std.math.Order.gt, p.order(&e));
}

test "applyDelta copies and inserts" {
    const gpa = testing.allocator;
    const base = "hello world, hello zig\n";
    // base size 23, result size 23: copy(0,18) insert("git\n") ... "hello world, hello " is 19 bytes
    const delta = [_]u8{ 23, 23, 0x90, 19, 4, 'g', 'i', 't', '\n' };
    const out = try applyDelta(gpa, base, &delta);
    defer gpa.free(out);
    try testing.expectEqualStrings("hello world, hello git\n", out);
}

test "applyDelta rejects bad input" {
    const gpa = testing.allocator;
    try testing.expectError(error.CorruptDelta, applyDelta(gpa, "abc", &.{ 4, 1, 1, 'x' }));
    try testing.expectError(error.CorruptDelta, applyDelta(gpa, "abc", &.{ 3, 2, 0x90, 3 }));
    try testing.expectError(error.CorruptDelta, applyDelta(gpa, "abc", &.{ 3, 1, 0 }));
    try testing.expectError(error.CorruptDelta, applyDelta(gpa, "abc", &.{ 3, 5, 0x91, 2, 0x10 }));
}

fn zlibStored(gpa: Allocator, data: []const u8) ![]u8 {
    std.debug.assert(data.len <= 0xffff);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &.{ 0x78, 0x01, 0x01 });
    const len: u16 = @intCast(data.len);
    try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, len)));
    try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, ~len)));
    try out.appendSlice(gpa, data);
    try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, std.hash.Adler32.hash(data))));
    return out.toOwnedSlice(gpa);
}

fn blobOid(data: []const u8) Oid {
    var h = std.crypto.hash.Sha1.init(.{});
    var hdr: [32]u8 = undefined;
    h.update(std.fmt.bufPrint(&hdr, "blob {d}\x00", .{data.len}) catch unreachable);
    h.update(data);
    var oid: Oid = undefined;
    h.final(&oid.bytes);
    return oid;
}

fn appendEntryHeader(list: *std.ArrayList(u8), gpa: Allocator, kind: u3, size: usize) !void {
    var s = size;
    var first: u8 = (@as(u8, kind) << 4) | @as(u8, @intCast(s & 0xf));
    s >>= 4;
    while (s != 0) {
        try list.append(gpa, first | 0x80);
        first = @intCast(s & 0x7f);
        s >>= 7;
    }
    try list.append(gpa, first);
}

const zeros4: [4]u8 = @splat(0);
const zeros20: [20]u8 = @splat(0);
const zeros40: [40]u8 = @splat(0);

test "reads base, OFS_DELTA and REF_DELTA entries from a hand-built pack" {
    const gpa = testing.allocator;
    const io = testing.io;

    const base = "hello world, hello zig\n";
    const via_ofs = "hello world, hello git\n";
    const via_ref = "hello world, hello pack\n";
    const delta_ofs = [_]u8{ 23, 23, 0x90, 19, 4, 'g', 'i', 't', '\n' };
    const delta_ref = [_]u8{ 23, 24, 0x90, 19, 5, 'p', 'a', 'c', 'k', '\n' };

    const base_oid = blobOid(base);
    const ofs_oid = blobOid(via_ofs);
    const ref_oid = blobOid(via_ref);

    var pack: std.ArrayList(u8) = .empty;
    defer pack.deinit(gpa);
    try pack.appendSlice(gpa, "PACK");
    try pack.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, 2)));
    try pack.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, 3)));

    const base_off: u64 = pack.items.len;
    try appendEntryHeader(&pack, gpa, 3, base.len);
    const z0 = try zlibStored(gpa, base);
    defer gpa.free(z0);
    try pack.appendSlice(gpa, z0);

    const ofs_off: u64 = pack.items.len;
    try appendEntryHeader(&pack, gpa, 6, delta_ofs.len);
    const back = ofs_off - base_off;
    try testing.expect(back < 0x80);
    try pack.append(gpa, @intCast(back));
    const z1 = try zlibStored(gpa, &delta_ofs);
    defer gpa.free(z1);
    try pack.appendSlice(gpa, z1);

    const ref_off: u64 = pack.items.len;
    try appendEntryHeader(&pack, gpa, 7, delta_ref.len);
    try pack.appendSlice(gpa, &base_oid.bytes);
    const z2 = try zlibStored(gpa, &delta_ref);
    defer gpa.free(z2);
    try pack.appendSlice(gpa, z2);
    try pack.appendSlice(gpa, &zeros20);

    const Item = struct { oid: Oid, off: u64 };
    var items = [_]Item{
        .{ .oid = base_oid, .off = base_off },
        .{ .oid = ofs_oid, .off = ofs_off },
        .{ .oid = ref_oid, .off = ref_off },
    };
    std.mem.sort(Item, &items, {}, struct {
        fn lt(_: void, a: Item, b: Item) bool {
            return std.mem.lessThan(u8, &a.oid.bytes, &b.oid.bytes);
        }
    }.lt);

    var idx: std.ArrayList(u8) = .empty;
    defer idx.deinit(gpa);
    try idx.appendSlice(gpa, &Pack.idx_magic);
    try idx.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, 2)));
    for (0..256) |b| {
        var n: u32 = 0;
        for (items) |it| n += @intFromBool(it.oid.bytes[0] <= b);
        try idx.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, n)));
    }
    for (items) |it| try idx.appendSlice(gpa, &it.oid.bytes);
    for (items) |_| try idx.appendSlice(gpa, &zeros4);
    for (items) |it| try idx.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(it.off))));
    try idx.appendSlice(gpa, &zeros40);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "objects/pack");
    try tmp.dir.writeFile(io, .{ .sub_path = "objects/pack/pack-test.pack", .data = pack.items });
    try tmp.dir.writeFile(io, .{ .sub_path = "objects/pack/pack-test.idx", .data = idx.items });

    var db: Odb = try .init(gpa, io, try tmp.dir.openDir(io, "objects", .{ .iterate = true }));
    defer db.deinit(gpa, io);

    for ([_]struct { Oid, []const u8 }{ .{ base_oid, base }, .{ ofs_oid, via_ofs }, .{ ref_oid, via_ref } }) |c| {
        const obj = try db.read(gpa, io, c[0]);
        defer obj.deinit(gpa);
        try testing.expectEqual(Kind.blob, obj.kind);
        try testing.expectEqualStrings(c[1], obj.data);
    }

    try testing.expectError(error.ObjectNotFound, db.read(gpa, io, blobOid("missing")));

    const hex = ofs_oid.toHex();
    try testing.expect((try db.resolvePrefix(io, hex[0..10])).eql(ofs_oid));
    try testing.expectError(error.PrefixTooShort, db.resolvePrefix(io, hex[0..3]));
    try testing.expectError(error.ObjectNotFound, db.resolvePrefix(io, "0000000"));
}
