const std = @import("std");
const testing = std.testing;

pub const Toml = @import("files/Toml.zig");

test "Toml Tests" {
    const test_file = @embedFile("tests/test.toml");
    var toml = try Toml.init(test_file, std.testing.allocator);
    toml.deinit();
}
