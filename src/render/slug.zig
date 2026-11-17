const std = @import("std");
const LetterCasing = @import("LetterCasing");
const GeneralCategories = @import("GeneralCategories");

/// Produces GitHub-style heading slugs, deduplicating repeats with `-N` suffixes per document.
pub const Slugger = struct {
    gpa: std.mem.Allocator,
    used: std.StringHashMapUnmanaged(void) = .empty,
    counts: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn init(gpa: std.mem.Allocator) Slugger {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Slugger) void {
        var it = self.used.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.used.deinit(self.gpa);
        self.counts.deinit(self.gpa);
    }

    /// Returns a slug for `text` that is unique within this Slugger; it stays owned by the Slugger.
    pub fn slug(self: *Slugger, text: []const u8) ![]const u8 {
        const base = try slugify(self.gpa, text);
        if (!self.used.contains(base)) {
            try self.used.put(self.gpa, base, {});
            return base;
        }
        defer self.gpa.free(base);
        const base_key = self.used.getKey(base).?;
        const count = try self.counts.getOrPutValue(self.gpa, base_key, 0);
        while (true) {
            count.value_ptr.* += 1;
            const candidate = try std.fmt.allocPrint(self.gpa, "{s}-{d}", .{ base, count.value_ptr.* });
            if (self.used.contains(candidate)) {
                self.gpa.free(candidate);
                continue;
            }
            try self.used.put(self.gpa, candidate, {});
            return candidate;
        }
    }
};

/// Lowercases, keeps word characters, hyphens and spaces, then turns spaces into hyphens.
pub fn slugify(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const lower = LetterCasing.toLowerAlloc(gpa, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer gpa.free(lower);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var view = std.unicode.Utf8View.init(lower) catch return gpa.dupe(u8, lower);
    var it = view.iterator();
    while (it.nextCodepointSlice()) |bytes| {
        const cp = std.unicode.utf8Decode(bytes) catch continue;
        if (cp == ' ') {
            try out.append(gpa, '-');
        } else if (cp == '-' or isWord(cp)) {
            try out.appendSlice(gpa, bytes);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Onigmo's \p{Word}, which GitHub's Ruby slugger uses: letters, marks, decimal digits, connectors, joiners.
fn isWord(cp: u21) bool {
    if (cp == 0x200C or cp == 0x200D) return true;
    return switch (GeneralCategories.gc(cp)) {
        .Lu, .Ll, .Lt, .Lm, .Lo, .Nl, .Mn, .Mc, .Me, .Nd, .Pc => true,
        else => false,
    };
}

test "slugify matches GitHub for punctuation and unicode" {
    const gpa = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "Hello World", "hello-world" },
        .{ "code & Em \u{2014} \u{dc}n\u{ef}code!", "code--em--\u{fc}n\u{ef}code" },
        .{ "snake_case-and.dots", "snake_case-anddots" },
        .{ "\u{1f680} Launch", "-launch" },
        .{ "\u{3a9}MEGA \u{39a}\u{3b1}\u{3c3}\u{39f}\u{3a3}", "\u{3c9}mega-\u{3ba}\u{3b1}\u{3c3}\u{3bf}\u{3c2}" },
        .{ "\u{4e2d}\u{6587} x\u{b2}", "\u{4e2d}\u{6587}-x" },
    };
    for (cases) |case| {
        const got = try slugify(gpa, case[0]);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

test "dedupe suffixes collide the way GitHub's do" {
    var s = Slugger.init(std.testing.allocator);
    defer s.deinit();
    try std.testing.expectEqualStrings("dup", try s.slug("Dup"));
    try std.testing.expectEqualStrings("dup-1", try s.slug("Dup"));
    try std.testing.expectEqualStrings("dup-1-1", try s.slug("Dup-1"));
}
