//! The small regex subset that highlight predicates (`#match?`, `#lua-match?`) use:
//! literals, `.`, sets, `\d \w \s` and Lua `%d %a`, anchors, `* + ? -`, and one level of `(a|b)`.

const std = @import("std");

pub const Result = enum { match, no_match, unsupported };

/// Unanchored search unless the pattern starts with `^`.
pub fn search(pat: []const u8, text: []const u8) Result {
    if (std.mem.indexOfScalar(u8, pat, '(')) |open| {
        const close = std.mem.indexOfScalarPos(u8, pat, open, ')') orelse return .unsupported;
        if (close + 1 < pat.len and std.mem.indexOfScalar(u8, "*+?", pat[close + 1]) != null) return .unsupported;
        var buf: [256]u8 = undefined;
        const tail = pat[close + 1 ..];
        var alts = std.mem.splitScalar(u8, pat[open + 1 .. close], '|');
        while (alts.next()) |alt| {
            const n = open + alt.len + tail.len;
            if (n > buf.len) return .unsupported;
            @memcpy(buf[0..open], pat[0..open]);
            @memcpy(buf[open..][0..alt.len], alt);
            @memcpy(buf[open + alt.len ..][0..tail.len], tail);
            switch (search(buf[0..n], text)) {
                .match => return .match,
                .unsupported => return .unsupported,
                .no_match => {},
            }
        }
        return .no_match;
    }
    if (std.mem.indexOfScalar(u8, pat, '|') != null) return .unsupported;
    if (pat.len > 0 and pat[0] == '^') return if (matchHere(pat[1..], text, 0)) .match else .no_match;
    for (0..text.len + 1) |start| {
        if (matchHere(pat, text, start)) return .match;
    }
    return .no_match;
}

fn classMatch(esc: u8, c: u8) bool {
    return switch (esc) {
        'd' => std.ascii.isDigit(c),
        'D' => !std.ascii.isDigit(c),
        'w' => std.ascii.isAlphanumeric(c) or c == '_',
        'W' => !(std.ascii.isAlphanumeric(c) or c == '_'),
        's' => std.ascii.isWhitespace(c),
        'S' => !std.ascii.isWhitespace(c),
        'a' => std.ascii.isAlphabetic(c),
        'l' => std.ascii.isLower(c),
        'u' => std.ascii.isUpper(c),
        'x' => std.ascii.isHex(c),
        'p' => std.ascii.isPrint(c) and !std.ascii.isAlphanumeric(c) and c != ' ',
        else => c == esc,
    };
}

fn isClassLetter(esc: u8) bool {
    return std.mem.indexOfScalar(u8, "dDwWsSalux", esc) != null or esc == 'p';
}

fn atomLen(p: []const u8) usize {
    if (p[0] == '\\' or p[0] == '%') return @min(2, p.len);
    if (p[0] != '[') return 1;
    var i: usize = 1;
    if (i < p.len and p[i] == '^') i += 1;
    if (i < p.len and p[i] == ']') i += 1;
    while (i < p.len and p[i] != ']') : (i += 1) {
        if (p[i] == '\\' or p[i] == '%') i += 1;
    }
    return @min(i + 1, p.len);
}

fn atomMatches(atom: []const u8, c: u8) bool {
    switch (atom[0]) {
        '.' => return true,
        '\\', '%' => return atom.len > 1 and classMatch(atom[1], c),
        '[' => {
            const end = atom.len - 1;
            var i: usize = 1;
            const negated = atom[i] == '^';
            if (negated) i += 1;
            var hit = false;
            while (i < end) : (i += 1) {
                const ch = atom[i];
                if ((ch == '\\' or ch == '%') and i + 1 < end) {
                    i += 1;
                    if (if (isClassLetter(atom[i])) classMatch(atom[i], c) else atom[i] == c) hit = true;
                } else if (i + 2 < end and atom[i + 1] == '-') {
                    if (c >= ch and c <= atom[i + 2]) hit = true;
                    i += 2;
                } else if (ch == c) hit = true;
            }
            return hit != negated;
        },
        else => return atom[0] == c,
    }
}

fn matchHere(p: []const u8, t: []const u8, pos: usize) bool {
    if (p.len == 0) return true;
    if (p[0] == '$' and p.len == 1) return pos == t.len;
    const n = atomLen(p);
    const atom = p[0..n];
    const rest = p[n..];
    const quant: u8 = if (rest.len > 0) rest[0] else 0;
    if (std.mem.indexOfScalar(u8, "*+-?", quant) == null or quant == 0) {
        return pos < t.len and atomMatches(atom, t[pos]) and matchHere(rest, t, pos + 1);
    }
    const after = rest[1..];
    if (quant == '-') {
        var k: usize = 0;
        while (true) : (k += 1) {
            if (matchHere(after, t, pos + k)) return true;
            if (pos + k >= t.len or !atomMatches(atom, t[pos + k])) return false;
        }
    }
    const min: usize = if (quant == '+') 1 else 0;
    const max: usize = if (quant == '?') 1 else std.math.maxInt(usize);
    var k: usize = 0;
    while (k < max and pos + k < t.len and atomMatches(atom, t[pos + k])) k += 1;
    while (true) {
        if (k >= min and matchHere(after, t, pos + k)) return true;
        if (k == 0) return false;
        k -= 1;
    }
}

test "anchors, sets and quantifiers" {
    try std.testing.expectEqual(Result.match, search("^[A-Z]", "Foo"));
    try std.testing.expectEqual(Result.no_match, search("^[A-Z]", "foo"));
    try std.testing.expectEqual(Result.match, search("^[A-Z][A-Z_0-9]+$", "MAX_SIZE"));
    try std.testing.expectEqual(Result.no_match, search("^[A-Z][A-Z_0-9]+$", "Max"));
    try std.testing.expectEqual(Result.match, search("ab+c", "xxabbbc"));
    try std.testing.expectEqual(Result.no_match, search("^ab?c$", "abbc"));
    try std.testing.expectEqual(Result.match, search("^-", "-euo"));
}

test "regex and Lua escapes" {
    try std.testing.expectEqual(Result.match, search("^[A-Z_][A-Z\\d_]+$", "A_1"));
    try std.testing.expectEqual(Result.match, search("^[A-Z][A-Z%d_]*$", "A1_"));
    try std.testing.expectEqual(Result.no_match, search("^[^a-z]+$", "AbC"));
    try std.testing.expectEqual(Result.match, search("^%d+%.%d+$", "3.14"));
    try std.testing.expectEqual(Result.match, search("^//!", "//! doc"));
}

test "alternation" {
    try std.testing.expectEqual(Result.match, search("^(arguments|module|console)$", "console"));
    try std.testing.expectEqual(Result.no_match, search("^(arguments|module|console)$", "consoles"));
    try std.testing.expectEqual(Result.match, search("x(a|b)y", "zxby"));
}

test "unsupported constructs are reported, not guessed" {
    try std.testing.expectEqual(Result.unsupported, search("(ab)+", "abab"));
    try std.testing.expectEqual(Result.unsupported, search("a|b", "a"));
}
