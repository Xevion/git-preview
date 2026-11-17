const std = @import("std");

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
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var view = std.unicode.Utf8View.init(text) catch return gpa.dupe(u8, text);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == ' ') {
            try out.append(gpa, '-');
        } else if (cp == '-' or cp == '_' or isWord(cp)) {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(toLower(cp), &buf) catch continue;
            try out.appendSlice(gpa, buf[0..n]);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Approximates Unicode \p{Word}: ASCII alphanumerics, plus non-ASCII outside the punctuation, symbol and emoji blocks.
fn isWord(cp: u21) bool {
    if (cp < 0x80) return std.ascii.isAlphanumeric(@intCast(cp));
    return switch (cp) {
        0xA0...0xBF, 0xD7, 0xF7 => false,
        0x2000...0x2BFF => false,
        0x3000...0x303F => false,
        0xFE00...0xFE0F => false,
        0x1F000...0x1FAFF => false,
        else => true,
    };
}

/// Lowercases ASCII, Latin-1, Latin Extended-A, Greek and Cyrillic; other scripts pass through.
fn toLower(cp: u21) u21 {
    return switch (cp) {
        'A'...'Z', 0xC0...0xD6, 0xD8...0xDE, 0x391...0x3A1, 0x3A3...0x3AB, 0x410...0x42F => cp + 0x20,
        0x400...0x40F => cp + 0x50,
        0x100...0x137, 0x14A...0x177 => if (cp % 2 == 0) cp + 1 else cp,
        0x139...0x148, 0x179...0x17E => if (cp % 2 == 1) cp + 1 else cp,
        else => cp,
    };
}

test "slugify matches GitHub for punctuation and unicode" {
    const gpa = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "Hello World", "hello-world" },
        .{ "code & Em \u{2014} \u{dc}n\u{ef}code!", "code--em--\u{fc}n\u{ef}code" },
        .{ "snake_case-and.dots", "snake_case-anddots" },
        .{ "\u{1f680} Launch", "-launch" },
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
