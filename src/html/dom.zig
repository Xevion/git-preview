//! Thin helpers over lexbor's DOM.

const std = @import("std");
const c = @import("lexbor");
pub const Node = c.lxb_dom_node_t;
pub const Element = c.lxb_dom_element_t;

pub fn localName(node: *Node) []const u8 {
    var len: usize = 0;
    const p = c.lxb_dom_element_local_name(@ptrCast(node), &len);
    return p[0..len];
}

pub fn getAttr(el: *Element, name: []const u8) ?[]const u8 {
    var len: usize = 0;
    const p = c.lxb_dom_element_get_attribute(el, name.ptr, name.len, &len) orelse return null;
    return p[0..len];
}

pub fn hasAttr(el: *Element, name: []const u8) bool {
    return c.lxb_dom_element_has_attribute(el, name.ptr, name.len);
}

pub fn setAttr(el: *Element, name: []const u8, value: []const u8) void {
    _ = c.lxb_dom_element_set_attribute(el, name.ptr, name.len, value.ptr, value.len);
}

pub fn removeAttr(el: *Element, name: []const u8) void {
    _ = c.lxb_dom_element_remove_attribute(el, name.ptr, name.len);
}

pub fn remove(node: *Node) void {
    c.lxb_dom_node_remove(node);
    _ = c.lxb_dom_node_destroy_deep(node);
}

/// Replaces an element with its children.
pub fn unwrap(node: *Node) void {
    while (@as(?*Node, node.first_child)) |child| {
        c.lxb_dom_node_remove(child);
        c.lxb_dom_node_insert_before(node, child);
    }
    remove(node);
}

/// Calls `visit` on every element below `root` in document order; `visit` may remove the element it gets.
pub fn eachElement(root: *Node, ctx: anytype, comptime visit: fn (@TypeOf(ctx), *Node) anyerror!void) anyerror!void {
    var cur: ?*Node = root.first_child;
    while (cur) |node| {
        cur = node.next;
        if (node.type != c.LXB_DOM_NODE_TYPE_ELEMENT) continue;
        try eachElement(node, ctx, visit);
        try visit(ctx, node);
    }
}

/// First element below `root` matching `pred`, in document order.
pub fn find(root: *Node, ctx: anytype, comptime pred: fn (@TypeOf(ctx), *Node) bool) ?*Node {
    var cur: ?*Node = root.first_child;
    while (cur) |node| : (cur = node.next) {
        if (node.type != c.LXB_DOM_NODE_TYPE_ELEMENT) continue;
        if (pred(ctx, node)) return node;
        if (find(node, ctx, pred)) |hit| return hit;
    }
    return null;
}

/// Every element below `root` matching `pred`, in document order.
pub fn findAll(gpa: std.mem.Allocator, root: *Node, ctx: anytype, comptime pred: fn (@TypeOf(ctx), *Node) bool) ![]*Node {
    var out: std.ArrayList(*Node) = .empty;
    errdefer out.deinit(gpa);
    try collect(gpa, root, ctx, pred, &out);
    return out.toOwnedSlice(gpa);
}

fn collect(gpa: std.mem.Allocator, root: *Node, ctx: anytype, comptime pred: fn (@TypeOf(ctx), *Node) bool, out: *std.ArrayList(*Node)) !void {
    var cur: ?*Node = root.first_child;
    while (cur) |node| : (cur = node.next) {
        if (node.type != c.LXB_DOM_NODE_TYPE_ELEMENT) continue;
        if (pred(ctx, node)) try out.append(gpa, node);
        try collect(gpa, node, ctx, pred, out);
    }
}

/// Whether any class of the element starts with `prefix` (hashed classes: `RefSelectorText__`).
pub fn hasClassPrefix(node: *Node, prefix: []const u8) bool {
    if (node.type != c.LXB_DOM_NODE_TYPE_ELEMENT) return false;
    const cls = getAttr(@ptrCast(node), "class") orelse return false;
    var it = std.mem.tokenizeScalar(u8, cls, ' ');
    while (it.next()) |t| if (std.mem.startsWith(u8, t, prefix)) return true;
    return false;
}

/// The first non-blank text below `node`, trimmed.
pub fn firstText(node: *Node) ?[]const u8 {
    var cur: ?*Node = node.first_child;
    while (cur) |n| : (cur = n.next) {
        if (n.type == c.LXB_DOM_NODE_TYPE_TEXT) {
            const cd: *c.lxb_dom_character_data_t = @ptrCast(n);
            const t = std.mem.trim(u8, cd.data.data[0..cd.data.length], " \t\r\n");
            if (t.len > 0) return t;
        } else if (n.type == c.LXB_DOM_NODE_TYPE_ELEMENT) {
            if (firstText(n)) |t| return t;
        }
    }
    return null;
}

/// Serializes `node` and its subtree, appending to `out`.
pub fn serialize(gpa: std.mem.Allocator, node: *Node, out: *std.ArrayList(u8)) !void {
    // The string lives in the document's arena and is freed with the document.
    var s = std.mem.zeroes(c.lexbor_str_t);
    if (c.lxb_html_serialize_tree_str(node, &s) != c.LXB_STATUS_OK) return error.HtmlSerialize;
    try out.appendSlice(gpa, s.data[0..s.length]);
}
