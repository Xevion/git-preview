const std = @import("std");
const clap = @import("clap");
const Repo = @import("repo/Repo.zig");
const forge = @import("forge.zig");
const markdown = @import("render/markdown.zig");
const page = @import("page.zig");
const source_mod = @import("source.zig");
const Source = source_mod.Source;
const Resolver = @import("urls.zig").Resolver;
const Fetcher = @import("net/Fetcher.zig");
const template = @import("chrome/template.zig");
const home = @import("chrome/home.zig");
const Zone = @import("chrome/Zone.zig");

const params = clap.parseParamsComptime(
    \\-h, --help            Show this help and exit.
    \\-V, --version         Print the version and exit.
    \\-o, --output <str>    Write the page here instead of a stable path under $TMPDIR/git-preview.
    \\-r, --rev <str>       Render committed content at this revision instead of the working tree.
    \\    --remote <str>    Remote whose host decides the forge (default: origin, else the only remote).
    \\    --forge <str>     Override forge detection: github, forgejo, gitlab.
    \\    --open            Open the page in the default browser.
    \\    --readme-only     Write only the rendered README instead of the full repository page.
    \\    --offline         Never use the network; render from cached pages and data only.
    \\<str>                 File to render (default: the README the forge would show).
    \\
);

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    var diag: clap.Diagnostic = .{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = arena,
    }) catch |err| {
        try diag.report(stderr, err);
        return 2;
    };
    defer res.deinit();

    if (res.args.version != 0) {
        var out_buf: [64]u8 = undefined;
        var out: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
        try out.interface.print("git-preview {s}\n", .{@import("build_options").version});
        try out.interface.flush();
        return 0;
    }
    if (res.args.help != 0) {
        try stderr.writeAll("Usage: git-preview [options] [FILE]\n\n");
        try clap.help(stderr, clap.Help, &params, .{});
        return 0;
    }

    run(arena, io, init.environ_map, res.args, res.positionals[0], stderr) catch |err| {
        try stderr.print("git-preview: {s}\n", .{describe(err)});
        return 1;
    };
    return 0;
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.NotARepository => "not inside a git repository",
        error.RevisionNotFound => "revision not found",
        error.AmbiguousRevision => "revision is ambiguous",
        error.NoReadme => "no Markdown README found (looked in .github/, the root, and docs/)",
        error.FileNotFound, error.PathNotFound => "file not found",
        error.OutsideRepository => "file is outside the repository",
        error.NotMarkdown => "only Markdown files can be previewed so far",
        error.BareWithoutRev => "bare repository: pass --rev to choose a revision",
        error.UnknownForge => "unknown --forge value (expected github, forgejo or gitlab)",
        else => @errorName(err),
    };
}

fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args: anytype,
    file_arg: ?[]const u8,
    stderr: *std.Io.Writer,
) !void {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena);
    const arg_abs: ?[]const u8 = if (file_arg) |f| try std.fs.path.resolveAlloc(arena, &.{ cwd, f }) else null;
    // A directory argument names the repository to preview rather than a file in it.
    const arg_is_dir = if (arg_abs) |a| blk: {
        const st = std.Io.Dir.cwd().statFile(io, a, .{}) catch break :blk false;
        break :blk st.kind == .directory;
    } else false;
    const file_abs: ?[]const u8 = if (arg_is_dir) null else arg_abs;
    const start = if (arg_is_dir) arg_abs.? else if (file_abs) |f| std.fs.path.dirname(f) orelse cwd else cwd;

    var repo = Repo.discover(arena, io, start) catch |err| switch (err) {
        error.FileNotFound => try Repo.discover(arena, io, cwd),
        else => return err,
    };
    defer repo.deinit(arena);

    var worktree_dir: ?std.Io.Dir = null;
    defer if (worktree_dir) |d| d.close(io);
    const head_oid: ?Repo.Oid = repo.resolveRev(arena, io, args.rev orelse "HEAD") catch |err| switch (err) {
        error.RevisionNotFound => if (args.rev == null) null else return err,
        else => return err,
    };
    const source: Source = if (args.rev != null)
        .{ .commit = .{ .repo = &repo, .oid = head_oid.? } }
    else blk: {
        const root = repo.work_tree orelse return error.BareWithoutRev;
        worktree_dir = try std.Io.Dir.openDirAbsolute(io, root, .{});
        break :blk .{ .worktree = worktree_dir.? };
    };

    const doc_path: []const u8 = if (file_abs) |f| blk: {
        const root = repo.work_tree orelse cwd;
        const rel = try std.fs.path.relativeAlloc(arena, cwd, env, root, f);
        if (std.mem.startsWith(u8, rel, "..") or std.fs.path.isAbsolute(rel)) return error.OutsideRepository;
        break :blk rel;
    } else try source_mod.findReadme(arena, io, source) orelse return error.NoReadme;
    if (!source_mod.isMarkdown(doc_path)) return error.NotMarkdown;
    const text = try source.read(arena, io, doc_path) orelse return error.FileNotFound;

    const remote_url = try repo.remoteUrl(arena, io, args.remote);
    const remote: ?forge.Remote = if (remote_url) |u| forge.Remote.parse(u) else null;
    const kind: forge.Kind = if (args.forge) |f|
        std.meta.stringToEnum(forge.Kind, f) orelse return error.UnknownForge
    else if (remote) |r| forge.Kind.fromHost(r.host) orelse blk: {
        try stderr.print("git-preview: unknown forge host {s}, rendering as GitHub (use --forge to choose)\n", .{r.host});
        break :blk .github;
    } else .github;
    if (kind != .github) try stderr.print("git-preview: {s} rendering is not implemented yet, rendering as GitHub\n", .{@tagName(kind)});

    var resolver: Resolver = .{
        .arena = arena,
        .io = io,
        .source = source,
        .doc_dir = std.fs.path.dirname(doc_path) orelse "",
        .blob_base = try blobBase(arena, kind, remote, head_oid),
    };
    const fragment = try markdown.toHtml(arena, text, .{
        .own_host = if (remote) |r| r.host else "github.com",
        .rewriter = resolver.rewriter(),
    });

    const repo_name = if (remote) |r| r.name() else std.fs.path.basename(repo.work_tree orelse repo.git_dir);
    const title = try std.fmt.allocPrint(arena, "{s}/{s}", .{ repo_name, doc_path });
    var fetcher: Fetcher = .init(arena, io, env, args.offline != 0);
    defer fetcher.deinit();
    const full_page = args.@"readme-only" == 0 and file_abs == null and kind == .github and remote != null;
    const html = blk: {
        if (full_page) {
            if (repoPage(arena, io, env, &fetcher, &repo, args.rev, head_oid, remote.?, fragment)) |p| break :blk p else |err| {
                try stderr.print("git-preview: repository page unavailable ({s}), writing the README alone\n", .{@errorName(err)});
            }
        }
        var out: std.Io.Writer.Allocating = .init(arena);
        try page.write(&out.writer, title, fragment);
        break :blk out.written();
    };

    const out_path = args.output orelse try defaultOutputPath(arena, env, repo_name, doc_path);
    if (std.fs.path.dirname(out_path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = html });

    var stdout_buf: [512]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    try stdout_writer.interface.print("{s}\n", .{out_path});
    try stdout_writer.interface.flush();

    if (args.open != 0) try openInBrowser(io, out_path);
}

/// The repo home page from github.com with our README swapped into its README box.
fn repoPage(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, fetcher: *Fetcher, repo: *const Repo, rev: ?[]const u8, head: ?Repo.Oid, remote: forge.Remote, readme: []const u8) ![]u8 {
    const url = try std.fmt.allocPrint(arena, "https://{s}/{s}", .{ remote.host, remote.path });
    var tpl = try template.load(arena, fetcher, url);
    defer tpl.deinit();
    const article = template.readmeArticle(&tpl) orelse return error.TemplateWithoutReadme;
    try tpl.setInnerHtml(article, "gp-readme", readme);
    if (head) |oid| try home.fill(arena, &tpl, try homeData(arena, io, env, repo, rev, oid, remote));
    return tpl.serialize(arena);
}

fn homeData(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, repo: *const Repo, rev: ?[]const u8, oid: Repo.Oid, remote: forge.Remote) !home.Data {
    var hex: [Repo.Oid.max_hex_len]u8 = undefined;
    const ref = rev orelse try repo.headBranch(arena, io) orelse try arena.dupe(u8, oid.hex(&hex)[0..7]);
    const tree = try repo.listTree(arena, io, oid, "");
    const commits = try repo.lastCommits(arena, io, oid, "");
    const entries = try arena.alloc(home.Entry, tree.len);
    for (tree, entries) |t, *e| {
        const found = for (commits) |pc| {
            if (std.mem.eql(u8, pc.name, t.name)) break pc.commit;
        } else return error.MissingLastCommit;
        e.* = .{ .name = t.name, .kind = t.kind, .commit = found };
    }
    const zone = try arena.create(Zone);
    zone.* = Zone.load(arena, io, env);
    return .{
        .repo_path = remote.path,
        .ref = ref,
        .commit_count = try repo.commitCount(arena, io, oid),
        .head = try repo.commitInfo(arena, io, oid),
        .entries = entries,
        .now = std.Io.Clock.real.now(io).toSeconds(),
        .zone = zone,
    };
}

/// Forge URL prefix for repo files at the rendered commit; relative links point there.
fn blobBase(arena: std.mem.Allocator, kind: forge.Kind, remote: ?forge.Remote, oid: ?Repo.Oid) !?[]const u8 {
    const r = remote orelse return null;
    const commit = oid orelse return null;
    var hex_buf: [Repo.Oid.max_hex_len]u8 = undefined;
    const hex = commit.hex(&hex_buf);
    return switch (kind) {
        .github => try std.fmt.allocPrint(arena, "https://{s}/{s}/blob/{s}/", .{ r.host, r.path, hex }),
        .forgejo => try std.fmt.allocPrint(arena, "https://{s}/{s}/src/commit/{s}/", .{ r.host, r.path, hex }),
        .gitlab => try std.fmt.allocPrint(arena, "https://{s}/{s}/-/blob/{s}/", .{ r.host, r.path, hex }),
    };
}

/// A stable path per repo and file, so re-running refreshes the page already open in the browser.
fn defaultOutputPath(arena: std.mem.Allocator, env: *std.process.Environ.Map, repo_name: []const u8, doc_path: []const u8) ![]const u8 {
    const tmp = env.get("TMPDIR") orelse "/tmp";
    const flat = try arena.dupe(u8, doc_path);
    std.mem.replaceScalar(u8, flat, '/', '_');
    return std.fmt.allocPrint(arena, "{s}/git-preview/{s}/{s}.html", .{ tmp, repo_name, flat });
}

fn openInBrowser(io: std.Io, path: []const u8) !void {
    const opener = switch (@import("builtin").os.tag) {
        .macos => "open",
        .windows => "explorer",
        else => "xdg-open",
    };
    var child = try std.process.spawn(io, .{
        .argv = &.{ opener, path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    _ = try child.wait(io);
}

test {
    _ = @import("render/markdown.zig");
    _ = @import("render/slug.zig");
    _ = @import("html/filter.zig");
    _ = @import("html/emoji.zig");
    _ = @import("render/octicons.zig");
    _ = @import("repo/Repo.zig");
    _ = @import("forge.zig");
    _ = @import("source.zig");
    _ = @import("urls.zig");
    _ = @import("chrome/template.zig");
    _ = @import("chrome/home.zig");
    _ = @import("chrome/time.zig");
    _ = @import("chrome/Classes.zig");
    _ = @import("highlight/highlight.zig");
}
