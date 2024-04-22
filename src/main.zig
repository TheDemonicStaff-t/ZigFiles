const std = @import("std");
const testing = std.testing;

pub const Toml = @import("files/Toml.zig");

test {
    const test_toml = @embedFile("tests/test.toml");
    var toml = try Toml.init(test_toml, std.testing.allocator);
    toml.deinit();
}
