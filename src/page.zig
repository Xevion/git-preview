//! Wraps a rendered fragment into a standalone page with the forge's stylesheet inlined.

const std = @import("std");

const css = @embedFile("github-markdown.css");
const css_license = @embedFile("github-markdown-css.LICENSE");
const octicons_license = @embedFile("octicons.LICENSE");

/// Layout around `.markdown-body`, following github-markdown-css's suggested container.
const layout =
    \\:root { color-scheme: light dark; }
    \\body { margin: 0; background-color: #ffffff; }
    \\@media (prefers-color-scheme: dark) { body { background-color: #0d1117; } }
    \\.markdown-body { box-sizing: border-box; min-width: 200px; max-width: 980px; margin: 0 auto; padding: 45px; }
    \\@media (max-width: 767px) { .markdown-body { padding: 15px; } }
    \\
;

pub fn write(w: *std.Io.Writer, title: []const u8, body: []const u8) !void {
    try w.writeAll("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>");
    try writeEscaped(w, title);
    try w.writeAll("</title>\n<style>\n/*\ngithub-markdown-css\n");
    try writeComment(w, css_license);
    try w.writeAll("\nOcticons\n");
    try writeComment(w, octicons_license);
    try w.writeAll("\n*/\n");
    try w.writeAll(css);
    try w.writeAll(layout);
    try w.writeAll("</style>\n</head>\n<body>\n<article class=\"markdown-body entry-content container-lg\" itemprop=\"text\">\n");
    try w.writeAll(body);
    try w.writeAll("</article>\n</body>\n</html>\n");
}

fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(ch),
    };
}

/// License text inside a CSS comment, with any comment terminator defused.
fn writeComment(w: *std.Io.Writer, s: []const u8) !void {
    var rest = s;
    while (std.mem.indexOf(u8, rest, "*/")) |i| {
        try w.writeAll(rest[0..i]);
        try w.writeAll("* /");
        rest = rest[i + 2 ..];
    }
    try w.writeAll(rest);
}
