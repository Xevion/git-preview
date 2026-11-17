//! Reads repository data from GitHub: the JSON endpoints its repository page hydrates from
//! (public, signed-out, exactly what the page renders), and the REST API as a fallback.

const std = @import("std");
const Fetcher = @import("Fetcher.zig");
const credentials = @import("credentials.zig");
const log = std.log.scoped(.net);

/// Sidebar data changes slowly; the latest commit's check status does not.
const sidebar_ttl = 6 * 60 * 60;
const status_ttl = 10 * 60;

pub const Sidebar = struct {
    releases: ?Releases = null,
    contributors: ?Contributors = null,
    languages: ?Languages = null,
    sponsors: ?Sponsors = null,
    usedBy: ?UsedBy = null,
};

pub const Releases = struct {
    latestRelease: ?Release = null,
    releasesPath: []const u8,
    tagsPath: []const u8,
};

pub const Release = struct {
    name: []const u8,
    path: []const u8,
    publishedAt: ?[]const u8 = null,
};

pub const Contributors = struct {
    contributorCount: u64,
    contributors: []const Person,
    contributorsPath: []const u8,
};

pub const Person = struct {
    login: []const u8,
    profileName: ?[]const u8 = null,
    profilePath: []const u8,
    avatarUrl: []const u8,
};

pub const Languages = struct {
    languages: []const Language,
    isFork: bool = false,
    ownerLogin: []const u8,
    repoName: []const u8,
};

pub const Language = struct {
    name: ?[]const u8 = null,
    percentage: f64,
    color: ?[]const u8 = null,
    searchAlias: ?[]const u8 = null,
};

pub const Sponsors = struct {
    sponsorables: []const Sponsorable = &.{},
    externalFundingLinks: []const FundingLink = &.{},
    sponsorsPath: []const u8,
    sponsorsLearnMorePath: ?[]const u8 = null,
    sponsorableCount: ?u64 = null,
};

pub const Sponsorable = struct {
    login: []const u8,
    displayName: ?[]const u8 = null,
    profilePath: []const u8,
    avatarUrl: []const u8,
};

pub const FundingLink = struct {
    platform: []const u8,
    url: []const u8,
    iconUrl: ?[]const u8 = null,
    label: ?[]const u8 = null,
};

pub const UsedBy = struct {
    dependentCount: u64,
    dependents: []const Dependent,
    dependentsPath: []const u8,
};

pub const Dependent = struct {
    ownerLogin: []const u8,
    avatarUrl: []const u8,
};

pub const RefCounts = struct {
    branches: u64,
    tags: u64,
};

pub const BranchInfo = struct {
    refComparison: ?RefComparison = null,
    pullRequestNumber: ?u64 = null,
};

pub const RefComparison = struct {
    ahead: u64,
    behind: u64,
    /// `owner/repo:branch` as shown.
    baseBranch: []const u8,
    /// `owner:repo:branch` for compare URLs.
    baseBranchRange: []const u8,
    currentRef: []const u8,
};

pub const LatestCommit = struct {
    author: ?Author = null,
    /// `success`, `pending`, `failure` or `error`; null without checks.
    status: ?[]const u8 = null,
};

pub const Author = struct {
    displayName: []const u8 = "",
    login: ?[]const u8 = null,
    /// Profile path such as `/octocat`; null for authors without a GitHub account.
    path: ?[]const u8 = null,
    avatarUrl: []const u8,
};

/// The JSON endpoints under `https://github.com/{owner}/{repo}/`.
pub const Web = struct {
    fetcher: *Fetcher,
    /// Owns everything the getters return.
    arena: std.mem.Allocator,
    /// `owner/name`.
    repo_path: []const u8,

    pub fn sidebar(self: *const Web) Result(Sidebar) {
        return self.json(Sidebar, "_sidebar", sidebar_ttl);
    }

    pub fn refCounts(self: *const Web) Result(RefCounts) {
        return self.json(RefCounts, "branch-and-tag-count", sidebar_ttl);
    }

    /// How a fork's branch compares with its upstream.
    pub fn branchInfo(self: *const Web, branch: []const u8) Result(BranchInfo) {
        var buf: [300]u8 = undefined;
        var fixed: std.Io.Writer = .fixed(&buf);
        fixed.writeAll("branch-infobar/") catch return .failed;
        std.Uri.Component.percentEncode(&fixed, branch, isUnreserved) catch return .failed;
        return self.json(BranchInfo, fixed.buffered(), sidebar_ttl);
    }

    /// The commit as GitHub knows it: `.missing` when it was never pushed.
    pub fn latestCommit(self: *const Web, sha: []const u8) Result(LatestCommit) {
        var buf: [128]u8 = undefined;
        const rel = std.fmt.bufPrint(&buf, "latest-commit/{s}", .{sha}) catch return .failed;
        return self.json(LatestCommit, rel, status_ttl);
    }

    fn json(self: *const Web, comptime T: type, rel: []const u8, ttl: i64) Result(T) {
        const url = std.fmt.allocPrint(self.arena, "https://github.com/{s}/{s}", .{ self.repo_path, rel }) catch return .failed;
        const res = self.fetcher.get(.{ .url = url, .ttl = ttl, .accept = "application/json" }) catch |err| {
            log.warn("{s} unavailable: {s}", .{ url, @errorName(err) });
            return .failed;
        };
        if (res.status == .not_found) return .missing;
        if (res.status.class() != .success) {
            log.warn("{s}: HTTP {d}", .{ url, @backingInt(res.status) });
            return .failed;
        }
        const value = std.json.parseFromSliceLeaky(T, self.arena, res.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
            log.warn("{s}: unexpected JSON ({s})", .{ url, @errorName(err) });
            return .failed;
        };
        return .{ .ok = value };
    }
};

fn isUnreserved(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-._~", ch) != null;
}

pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        /// The forge does not know it (404).
        missing,
        /// Network, HTTP or format failure, already logged.
        failed,

        pub fn get(self: @This()) ?T {
            return switch (self) {
                .ok => |v| v,
                else => null,
            };
        }
    };
}

/// GitHub REST API reads, unauthenticated unless the API refuses.
pub const Api = struct {
    fetcher: *Fetcher,
    env: *std.process.Environ.Map,
    /// Looked up lazily on the first refused request, then reused.
    token: ?[]u8 = null,
    token_tried: bool = false,

    /// GETs `https://api.github.com{path}`; null for 404 even with credentials (missing or invisible).
    pub fn get(self: *Api, path: []const u8, ttl: i64) !?[]u8 {
        const gpa = self.fetcher.gpa;
        const url = try std.fmt.allocPrint(gpa, "https://api.github.com{s}", .{path});
        defer gpa.free(url);
        const accept = "application/vnd.github+json";

        var res = try self.fetcher.get(.{ .url = url, .ttl = ttl, .accept = accept, .authorization = try self.authHeader() });
        if (res.status == .unauthorized or res.status == .forbidden or res.status == .not_found) {
            if (self.token == null and !self.token_tried) {
                self.token_tried = true;
                self.token = try credentials.find(gpa, self.fetcher.io, self.env, "github.com");
                if (self.token != null) {
                    log.debug("retrying {s} with credentials", .{path});
                    res = try self.fetcher.get(.{ .url = url, .ttl = ttl, .accept = accept, .authorization = try self.authHeader() });
                }
            }
        }
        if (res.status == .not_found) return null;
        if (res.status.class() != .success) {
            log.warn("GitHub API {s}: HTTP {d}", .{ path, @backingInt(res.status) });
            return error.ApiRefused;
        }
        return res.body;
    }

    fn authHeader(self: *Api) !?[]const u8 {
        const t = self.token orelse return null;
        return try std.fmt.allocPrint(self.fetcher.gpa, "Bearer {s}", .{t});
    }

    /// The GitHub account behind a commit's author, as the repository page would show it.
    pub fn commitAuthor(self: *Api, arena: std.mem.Allocator, repo_path: []const u8, sha: []const u8) !?Author {
        const path = try std.fmt.allocPrint(arena, "/repos/{s}/commits/{s}", .{ repo_path, sha });
        const body = try self.get(path, 30 * 24 * 60 * 60) orelse return null;
        const Rest = struct {
            author: ?struct { login: []const u8, avatar_url: []const u8 } = null,
            commit: struct { author: struct { name: []const u8 } },
        };
        const c = try std.json.parseFromSliceLeaky(Rest, arena, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        const a = c.author orelse return .{ .displayName = c.commit.author.name, .avatarUrl = "" };
        return .{
            .displayName = a.login,
            .login = a.login,
            .path = try std.fmt.allocPrint(arena, "/{s}", .{a.login}),
            .avatarUrl = try std.fmt.allocPrint(arena, "{s}&size=40", .{a.avatar_url}),
        };
    }
};

test "decodes the repository page's sidebar JSON" {
    const body =
        \\{"releases":{"releasesPath":"/o/r/releases","tagsPath":"/o/r/tags","canWrite":false},
        \\"contributors":{"contributorCount":2,"contributors":[{"login":"a","profileName":"A","profilePath":"/a","avatarUrl":"u"},
        \\{"login":"b[bot]","profilePath":"/b[bot]","avatarUrl":"https://avatars.githubusercontent.com/in/1?s=64"}],"contributorsPath":"/o/r/graphs/contributors"},
        \\"languages":{"languages":[{"name":"Rust","percentage":86.7,"color":"#dea584","searchAlias":"rust"},{"name":"Other","percentage":0.4,"color":"#ededed"}],
        \\"isFork":false,"ownerLogin":"o","repoName":"r"},"sponsors":null,"deployments":null,"packages":null,"usedBy":null}
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const s = try std.json.parseFromSliceLeaky(Sidebar, arena.allocator(), body, .{ .ignore_unknown_fields = true });
    try std.testing.expect(s.releases.?.latestRelease == null);
    try std.testing.expectEqual(@as(u64, 2), s.contributors.?.contributorCount);
    try std.testing.expect(s.contributors.?.contributors[1].profileName == null);
    try std.testing.expectEqual(@as(f64, 86.7), s.languages.?.languages[0].percentage);
    try std.testing.expect(s.languages.?.languages[1].searchAlias == null);
    try std.testing.expect(s.usedBy == null and s.sponsors == null);
}
