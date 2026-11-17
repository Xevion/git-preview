const std = @import("std");

const Query = struct { dep: []const u8, path: []const u8 };

const Language = struct {
    /// `-Dlanguages` key; also the grammar's `tree_sitter_<name>` symbol.
    name: []const u8,
    dep: []const u8,
    /// Grammar root inside the dependency when it is not the repo root.
    dir: []const u8 = "",
    /// Concatenated in order; later patterns win ties, so base languages come first.
    queries: []const Query,
    /// Linguist's TextMate scope as GitHub names it; becomes the `highlight-*` class.
    scope: []const u8 = "",
    aliases: []const []const u8 = &.{},
    /// GitHub colors operator symbols as constants in these languages and as keywords elsewhere.
    operators_constant: bool = false,
    /// Grammar run over this one's `inline` nodes (markdown).
    inline_lang: []const u8 = "",
    /// Only built as part of another language.
    internal: bool = false,
};

fn hl(comptime dep: []const u8) Query {
    return .{ .dep = dep, .path = "queries/highlights.scm" };
}

/// Adding a language is one `zig fetch --save=ts_<x>` (marked `.lazy = true`) plus one row here.
const table = [_]Language{
    .{ .name = "zig", .dep = "ts_zig", .queries = &.{hl("ts_zig")}, .scope = "source.zig" },
    .{ .name = "rust", .dep = "ts_rust", .queries = &.{hl("ts_rust")}, .scope = "source.rust", .aliases = &.{"rs"} },
    .{ .name = "python", .dep = "ts_python", .queries = &.{hl("ts_python")}, .scope = "source.python", .aliases = &.{ "py", "python3" } },
    .{
        .name = "javascript",
        .dep = "ts_javascript",
        .queries = &.{ hl("ts_javascript"), .{ .dep = "ts_javascript", .path = "queries/highlights-jsx.scm" } },
        .scope = "source.js",
        .aliases = &.{ "js", "jsx" },
    },
    .{
        .name = "typescript",
        .dep = "ts_typescript",
        .dir = "typescript",
        .queries = &.{ hl("ts_typescript"), hl("ts_javascript") },
        .scope = "source.ts",
        .aliases = &.{"ts"},
        .operators_constant = true,
    },
    .{
        .name = "tsx",
        .dep = "ts_typescript",
        .dir = "tsx",
        .queries = &.{ hl("ts_typescript"), .{ .dep = "ts_javascript", .path = "queries/highlights-jsx.scm" }, hl("ts_javascript") },
        .scope = "source.tsx",
        .operators_constant = true,
    },
    .{ .name = "bash", .dep = "ts_bash", .queries = &.{hl("ts_bash")}, .scope = "source.shell", .aliases = &.{ "sh", "shell", "shell-script", "zsh" } },
    .{ .name = "c", .dep = "ts_c", .queries = &.{hl("ts_c")}, .scope = "source.c", .operators_constant = true },
    .{ .name = "cpp", .dep = "ts_cpp", .queries = &.{ hl("ts_cpp"), hl("ts_c") }, .scope = "source.c++", .aliases = &.{ "c++", "cxx" }, .operators_constant = true },
    .{ .name = "go", .dep = "ts_go", .queries = &.{hl("ts_go")}, .scope = "source.go", .aliases = &.{"golang"}, .operators_constant = true },
    .{ .name = "java", .dep = "ts_java", .queries = &.{hl("ts_java")}, .scope = "source.java" },
    .{ .name = "json", .dep = "ts_json", .queries = &.{hl("ts_json")}, .scope = "source.json" },
    .{ .name = "toml", .dep = "ts_toml", .queries = &.{hl("ts_toml")}, .scope = "source.toml" },
    .{ .name = "yaml", .dep = "ts_yaml", .queries = &.{hl("ts_yaml")}, .scope = "source.yaml", .aliases = &.{"yml"} },
    .{ .name = "html", .dep = "ts_html", .queries = &.{hl("ts_html")}, .scope = "text.html.basic", .aliases = &.{"xhtml"} },
    .{ .name = "css", .dep = "ts_css", .queries = &.{hl("ts_css")}, .scope = "source.css" },
    .{ .name = "diff", .dep = "ts_diff", .queries = &.{hl("ts_diff")}, .scope = "source.diff", .aliases = &.{ "patch", "udiff" } },
    .{
        .name = "markdown",
        .dep = "ts_markdown",
        .dir = "tree-sitter-markdown",
        .queries = &.{.{ .dep = "ts_markdown", .path = "tree-sitter-markdown/queries/highlights.scm" }},
        .scope = "text.md",
        .aliases = &.{ "md", "pandoc" },
        .inline_lang = "markdown_inline",
    },
    .{
        .name = "markdown_inline",
        .dep = "ts_markdown",
        .dir = "tree-sitter-markdown-inline",
        .queries = &.{.{ .dep = "ts_markdown", .path = "tree-sitter-markdown-inline/queries/highlights.scm" }},
        .internal = true,
    },
};

const default_languages = blk: {
    var names: []const u8 = "";
    for (table) |lang| {
        if (lang.internal) continue;
        names = names ++ (if (names.len == 0) "" else ",") ++ lang.name;
    }
    break :blk names;
};

const QueryImport = struct { name: []const u8, source: std.Build.LazyPath };

/// tree-sitter, the selected grammars, and the generated config `src/highlight` reads.
pub const Treesitter = struct {
    libs: []const *std.Build.Step.Compile,
    module: *std.Build.Module,
    options: *std.Build.Step.Options,
    queries: []const QueryImport,

    /// Exposes `@import("ts")` (the C API), `@import("highlight_config")` and the query sources.
    pub fn addTo(self: Treesitter, mod: *std.Build.Module) void {
        mod.addImport("ts", self.module);
        mod.addOptions("highlight_config", self.options);
        for (self.libs) |lib| mod.linkLibrary(lib);
        for (self.queries) |q| mod.addAnonymousImport(q.name, .{ .root_source_file = q.source });
    }
};

fn find(name: []const u8) ?Language {
    for (table) |lang| if (std.mem.eql(u8, lang.name, name)) return lang;
    return null;
}

/// The `-Dlanguages` selection plus whatever the selected grammars embed.
fn select(b: *std.Build) []const Language {
    const names = b.option(
        []const u8,
        "languages",
        "Comma-separated highlight grammars, or 'all' (default: the validated core set)",
    ) orelse default_languages;
    var out: std.ArrayList(Language) = .empty;
    var it = std.mem.tokenizeScalar(u8, names, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        if (std.mem.eql(u8, name, "all")) {
            for (table) |lang| appendUnique(b, &out, lang);
            continue;
        }
        const lang = find(name) orelse std.debug.panic("unknown highlight language '{s}'", .{name});
        appendUnique(b, &out, lang);
    }
    var i: usize = 0;
    while (i < out.items.len) : (i += 1) {
        const inner = out.items[i].inline_lang;
        if (inner.len > 0) appendUnique(b, &out, find(inner).?);
    }
    return out.items;
}

fn appendUnique(b: *std.Build, list: *std.ArrayList(Language), lang: Language) void {
    for (list.items) |have| if (std.mem.eql(u8, have.name, lang.name)) return;
    list.append(b.allocator, lang) catch @panic("OOM");
}

fn exists(dep: *std.Build.Dependency, sub_path: []const u8) bool {
    dep.builder.root.access(dep.builder.graph.io, sub_path, .{ .read = true }) catch return false;
    return true;
}

/// Compiles tree-sitter and the selected grammars from pinned tarballs.
pub fn build(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Treesitter {
    const langs = select(b);

    // Grammar tarballs are lazy, so a first configure may only discover what to fetch.
    var deps: std.StringHashMapUnmanaged(*std.Build.Dependency) = .empty;
    var missing = false;
    for (langs) |lang| {
        fetchLazy(b, &deps, lang.dep, &missing);
        for (lang.queries) |q| fetchLazy(b, &deps, q.dep, &missing);
    }

    const core = b.dependency("tree_sitter", .{ .target = target, .optimize = optimize, .amalgamated = true });
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/highlight/ts.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(core.path("lib/include"));

    const options = b.addOptions();
    var libs: std.ArrayList(*std.Build.Step.Compile) = .empty;
    libs.append(b.allocator, core.artifact("tree-sitter")) catch @panic("OOM");
    var rows: std.ArrayList(u8) = .empty;
    var queries: std.ArrayList(QueryImport) = .empty;

    if (!missing) for (langs) |lang| {
        const dep = deps.get(lang.dep).?;
        libs.append(b.allocator, grammarLib(b, dep, lang, target, optimize)) catch @panic("OOM");
        // One line per language: name;scope;aliases,comma-separated;query count;inline language;operators constant
        rows.print(b.allocator, "{s};{s};{s};{d};{s};{d}\n", .{
            lang.name,
            lang.scope,
            std.mem.join(b.allocator, ",", lang.aliases) catch @panic("OOM"),
            lang.queries.len,
            lang.inline_lang,
            @intFromBool(lang.operators_constant),
        }) catch @panic("OOM");
        for (lang.queries, 0..) |q, i| {
            queries.append(b.allocator, .{
                .name = b.fmt("hlq_{s}_{d}", .{ lang.name, i }),
                .source = deps.get(q.dep).?.path(q.path),
            }) catch @panic("OOM");
        }
    };
    options.addOption([]const u8, "languages", rows.items);

    return .{ .libs = libs.items, .module = translate.createModule(), .options = options, .queries = queries.items };
}

fn fetchLazy(b: *std.Build, deps: *std.StringHashMapUnmanaged(*std.Build.Dependency), name: []const u8, missing: *bool) void {
    if (deps.contains(name)) return;
    const dep = b.lazyDependency(name, .{}) orelse {
        missing.* = true;
        return;
    };
    deps.put(b.allocator, name, dep) catch @panic("OOM");
}

fn grammarLib(
    b: *std.Build,
    dep: *std.Build.Dependency,
    lang: Language,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const src_dir = if (lang.dir.len == 0) "src" else b.fmt("{s}/src", .{lang.dir});
    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    mod.addIncludePath(dep.path(src_dir));

    var c_files: std.ArrayList([]const u8) = .empty;
    c_files.append(b.allocator, "parser.c") catch @panic("OOM");
    if (exists(dep, b.fmt("{s}/scanner.c", .{src_dir}))) c_files.append(b.allocator, "scanner.c") catch @panic("OOM");
    mod.addCSourceFiles(.{
        .root = dep.path(src_dir),
        .files = c_files.items,
        .flags = &.{ "-std=c11", "-fno-sanitize=undefined" },
    });
    if (exists(dep, b.fmt("{s}/scanner.cc", .{src_dir}))) {
        mod.link_libcpp = true;
        mod.addCSourceFiles(.{ .root = dep.path(src_dir), .files = &.{"scanner.cc"}, .flags = &.{"-fno-sanitize=undefined"} });
    }
    return b.addLibrary(.{ .name = b.fmt("ts-{s}", .{lang.name}), .linkage = .static, .root_module = mod });
}
