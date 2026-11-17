const std = @import("std");

pub const Kind = enum {
    github,
    forgejo,
    gitlab,

    /// Hosts whose forge is known without probing.
    pub fn fromHost(host: []const u8) ?Kind {
        const known = [_]struct { []const u8, Kind }{
            .{ "github.com", .github },
            .{ "codeberg.org", .forgejo },
            .{ "gitlab.com", .gitlab },
        };
        for (known) |k| if (std.ascii.eqlIgnoreCase(host, k[0])) return k[1];
        return null;
    }
};

/// Where a repository is hosted, parsed from its remote URL.
pub const Remote = struct {
    host: []const u8,
    /// `owner/name` (GitLab may nest groups: `group/sub/name`), without a `.git` suffix.
    path: []const u8,

    /// Accepts `https://host/o/r(.git)`, `ssh://[user@]host[:port]/o/r`, and scp-style `[user@]host:o/r`.
    pub fn parse(url: []const u8) ?Remote {
        var rest: []const u8 = undefined;
        var host: []const u8 = undefined;
        if (std.mem.indexOf(u8, url, "://")) |scheme_end| {
            const after = url[scheme_end + 3 ..];
            const slash = std.mem.indexOfScalar(u8, after, '/') orelse return null;
            var authority = after[0..slash];
            if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
            if (std.mem.indexOfScalar(u8, authority, ':')) |colon| authority = authority[0..colon];
            host = authority;
            rest = after[slash + 1 ..];
        } else {
            const colon = std.mem.indexOfScalar(u8, url, ':') orelse return null;
            var authority = url[0..colon];
            if (std.mem.indexOfScalar(u8, authority, '/') != null) return null;
            if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
            host = authority;
            rest = url[colon + 1 ..];
        }
        rest = std.mem.trim(u8, rest, "/");
        if (std.mem.endsWith(u8, rest, ".git")) rest = rest[0 .. rest.len - 4];
        if (host.len == 0 or std.mem.indexOfScalar(u8, rest, '/') == null) return null;
        return .{ .host = host, .path = rest };
    }

    /// The repository's last path segment.
    pub fn name(self: Remote) []const u8 {
        const slash = std.mem.lastIndexOfScalar(u8, self.path, '/').?;
        return self.path[slash + 1 ..];
    }
};

test "parses the common remote URL shapes" {
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "https://github.com/github/cmark-gfm.git", "github.com", "github/cmark-gfm" },
        .{ "git@github.com:Xevion/git-preview.git", "github.com", "Xevion/git-preview" },
        .{ "ssh://git@codeberg.org:2222/forgejo/forgejo", "codeberg.org", "forgejo/forgejo" },
        .{ "https://user:token@gitlab.com/group/sub/proj/", "gitlab.com", "group/sub/proj" },
    };
    for (cases) |case| {
        const r = Remote.parse(case[0]).?;
        try std.testing.expectEqualStrings(case[1], r.host);
        try std.testing.expectEqualStrings(case[2], r.path);
    }
    try std.testing.expect(Remote.parse("/local/path/repo") == null);
    try std.testing.expectEqualStrings("proj", Remote.parse("https://gitlab.com/group/sub/proj").?.name());
}
