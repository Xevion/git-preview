//! Finds a token for a forge host, consulted only after an unauthenticated request was refused.
//! Order: GH_TOKEN / GITHUB_TOKEN, gh's hosts.yml, `gh auth token`, `git credential fill`.

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.net);

/// Returns an owned token, or null when every source came up empty.
pub fn find(gpa: std.mem.Allocator, io: Io, env: *std.process.Environ.Map, host: []const u8) !?[]u8 {
    if (std.ascii.eqlIgnoreCase(host, "github.com")) {
        for ([_][]const u8{ "GH_TOKEN", "GITHUB_TOKEN" }) |name| {
            if (env.get(name)) |t| if (t.len > 0) return try gpa.dupe(u8, t);
        }
    }
    if (try ghHostsFile(gpa, io, env, host)) |t| return t;
    if (try ghAuthToken(gpa, io, host)) |t| return t;
    return gitCredential(gpa, io, env, host);
}

fn ghHostsFile(gpa: std.mem.Allocator, io: Io, env: *std.process.Environ.Map, host: []const u8) !?[]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = if (env.get("GH_CONFIG_DIR")) |d|
        try std.fmt.bufPrint(&buf, "{s}/hosts.yml", .{d})
    else if (env.get("XDG_CONFIG_HOME")) |x|
        try std.fmt.bufPrint(&buf, "{s}/gh/hosts.yml", .{x})
    else if (env.get("HOME")) |h|
        try std.fmt.bufPrint(&buf, "{s}/.config/gh/hosts.yml", .{h})
    else
        return null;
    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return null;
    defer gpa.free(text);
    return if (hostsToken(text, host)) |t| try gpa.dupe(u8, t) else null;
}

/// The `oauth_token` under a top-level `<host>:` key; gh omits it when the token lives in the keyring.
fn hostsToken(text: []const u8, host: []const u8) ?[]const u8 {
    var in_host = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \r");
        if (line.len == 0) continue;
        if (line[0] != ' ') {
            in_host = std.mem.endsWith(u8, line, ":") and std.ascii.eqlIgnoreCase(line[0 .. line.len - 1], host);
            continue;
        }
        if (!in_host) continue;
        const trimmed = std.mem.trimStart(u8, line, " ");
        const key = "oauth_token:";
        if (std.mem.startsWith(u8, trimmed, key)) {
            const value = std.mem.trim(u8, trimmed[key.len..], " \"'");
            if (value.len > 0) return value;
        }
    }
    return null;
}

fn ghAuthToken(gpa: std.mem.Allocator, io: Io, host: []const u8) !?[]u8 {
    const res = std.process.run(gpa, io, .{ .argv = &.{ "gh", "auth", "token", "--hostname", host } }) catch |err| {
        log.debug("gh auth token unavailable: {s}", .{@errorName(err)});
        return null;
    };
    defer gpa.free(res.stderr);
    defer gpa.free(res.stdout);
    if (!res.term.success()) return null;
    const token = std.mem.trim(u8, res.stdout, " \r\n");
    return if (token.len > 0) try gpa.dupe(u8, token) else null;
}

/// Asks git's configured credential helpers, never prompting the terminal.
fn gitCredential(gpa: std.mem.Allocator, io: Io, env: *std.process.Environ.Map, host: []const u8) !?[]u8 {
    try env.put("GIT_TERMINAL_PROMPT", "0");
    var child = std.process.spawn(io, .{
        .argv = &.{ "git", "credential", "fill" },
        .environ_map = env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |err| {
        log.debug("git credential unavailable: {s}", .{@errorName(err)});
        return null;
    };
    defer child.kill(io);

    var req_buf: [512]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "protocol=https\nhost={s}\n\n", .{host});
    try child.stdin.?.writeStreamingAll(io, req);
    child.stdin.?.close(io);
    child.stdin = null;

    var read_buf: [1024]u8 = undefined;
    var reader = child.stdout.?.reader(io, &read_buf);
    const out = try reader.interface.allocRemaining(gpa, .limited(64 << 10));
    defer gpa.free(out);
    const term = try child.wait(io);
    if (!term.success()) return null;

    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "password=")) return try gpa.dupe(u8, line["password=".len..]);
    }
    return null;
}

test "reads oauth_token only from the matching host block" {
    const text =
        \\gitlab.com:
        \\    oauth_token: wrong
        \\github.com:
        \\    git_protocol: https
        \\    oauth_token: "gho_abc"
        \\    user: someone
        \\
    ;
    try std.testing.expectEqualStrings("gho_abc", hostsToken(text, "github.com").?);
    try std.testing.expect(hostsToken("github.com:\n    users:\n        x:\n", "github.com") == null);
}
