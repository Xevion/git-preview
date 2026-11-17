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

/// Serializes `node` and its subtree, appending to `out`.
pub fn serialize(gpa: std.mem.Allocator, node: *Node, out: *std.ArrayList(u8)) !void {
    // The string lives in the document's arena and is freed with the document.
    var s = std.mem.zeroes(c.lexbor_str_t);
    if (c.lxb_html_serialize_tree_str(node, &s) != c.LXB_STATUS_OK) return error.HtmlSerialize;
    try out.appendSlice(gpa, s.data[0..s.length]);
}
