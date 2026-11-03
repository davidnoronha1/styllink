//! Buffers allocated by the caller's allocator; ownership stays with the caller.
const std = @import("std");
pub fn free(allocator: std.mem.Allocator, bytes: *[]u8) void {
    if (bytes.len > 0) allocator.free(bytes.*);
    bytes.* = &.{};
}
