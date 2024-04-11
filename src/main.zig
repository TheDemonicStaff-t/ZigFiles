const std = @import("std");
const testing = std.testing;

test "Toml Functionality Test" {
    const Toml = @import("files/Toml.zig");
    const test_file = @embedFile("tests/test.toml");
}
