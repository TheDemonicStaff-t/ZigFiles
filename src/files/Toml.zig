const std = @import("std");
// imported structures
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArrayEntry = std.StringHashMap(u64).Entry;
const TableEntry = std.StringHashMap(TableValue).Entry;
// imported functions
const fixedBufferStream = std.io.fixedBufferStream;
const eql = std.mem.eql;
const format = std.fmt.format;

const Toml = @This();

alloc: Allocator,
table: std.StringHashMap(TableValue),
text: []const u8,
active_prefix: ?[]const u8 = null,
array_counts: std.StringHashMap(u64) = undefined,
idx: usize = 0,

/// Initializes Toml from recieved text. Result must have deinit() called before end of execution.
pub fn init(text: []const u8, alloc: Allocator) !Toml {
    var toml = Toml{
        .alloc = alloc,
        .table = std.StringHashMap(TableValue).init(alloc),
        .text = text,
        .array_counts = std.StringHashMap(u64).init(alloc),
    };
    return toml;
}

// parsing functions
/// This is for internal use when initially parsing the initializing text and should not be called outside
/// of initialization.
pub fn parse(self: *Toml) !void {
    while (self.idx < self.text.len) : (self.idx += 1) {
        //self.skipNlWhitespace();
        // detect prefix or id
        if (self.text[self.idx] == '[') {
            //try self.parsePrefix();
        } else if (self.text[self.idx] == '#') {
            self.skipComment();
        } else {
            // parse key value pair and add to table
            //var key = try self.parseId();
        }
    }
}

/// FOR INTERNAL USE ONLY
pub fn parsePrefix(self: *Toml) !void {
    if (self.active_prefix) |prefix| self.alloc.free(prefix);
    var fin_prefix = ArrayList(u8).init(self.alloc);
    errdefer fin_prefix.deinit();
    const prefix = fin_prefix.writer();

    if (self.text[self.idx] == '[') {
        // TODO: Implement table arrays (pain and death)
        self.idx += 1;
        while (self.idx < self.text.len and self.text[self.idx] != ']') {
            var next_segment = try self.parseNestedPrefix();
            try prefix.writeAll(next_segment);
            self.alloc.free(next_segment);

            var entry = try self.fetchArrayPrefix(fin_prefix.items);
            if (entry) |ent| {
                if (self.text[self.idx] != ']') ent.value_ptr.* -= 1;
                try prefix.print("[{d}]", .{ent.value_ptr.*});
                ent.value_ptr.* += 1;
            }
            if (self.text[self.idx] == '.') {
                try prefix.writeByte('.');
                self.idx += 1;
            }
        }
        if (self.idx >= self.text.len) return error.StringOverflow;
        self.idx += 1;
        var table_entry = try self.fetchOrGenArrayPrefix(fin_prefix.items);
        try prefix.print("[{d}]", .{table_entry.value_ptr.*});
        table_entry.value_ptr.* += 1;
        self.active_prefix = try fin_prefix.toOwnedSlice();
    } else {
        while (self.idx < self.text.len and self.text[self.idx] != ']') {
            var next_segment = try self.parseNestedPrefix();
            defer self.alloc.free(next_segment);
            try prefix.writeAll(next_segment);

            var entry = try self.fetchArrayPrefix(fin_prefix.items);
            if (entry) |ent| {
                if (self.text[self.idx] != ']') ent.value_ptr.* -= 1;
                try prefix.print("[{d}]", .{ent.value_ptr.*});
                ent.value_ptr.* += 1;
            }
            if (self.text[self.idx] == '.') {
                try prefix.writeByte('.');
                self.idx += 1;
            }
        }
        if (self.idx >= self.text.len) return error.StringOverflow;
        self.idx += 1;
        self.active_prefix = try fin_prefix.toOwnedSlice();
    }
}
/// FOR INTERNAL USE ONLY
pub fn parseIdString(self: *Toml) !?[]const u8 {
    var start: usize = 0;
    var fin_string = ArrayList(u8).init(self.alloc);
    errdefer fin_string.deinit();
    const string = fin_string.writer();
    if (self.text[self.idx] == '\'') {
        self.idx += 1;
        start = self.idx;
        if (self.idx >= self.text.len) return error.IncompleteString;
        if (self.text[self.idx] == '\'') return null;
        while (self.idx < self.text.len and self.text[self.idx] != '\'') : (self.idx += 1) {
            if (self.text[self.idx] == '\n') return error.MultilineIdStringNotSupported;
        }
        try string.writeAll(self.text[start..self.idx]);
        return try fin_string.toOwnedSlice();
    } else if (self.text[self.idx] == '\"') {
        self.idx += 1;
        if (self.text[self.idx] == '\"') return error.MultilineIdStringNotSupported;
        start = self.idx;

        while (self.idx < self.text.len and self.text[self.idx] != '\"') : (self.idx += 1) {
            if (self.text[self.idx] == '\\') {
                if (start < self.idx) try string.writeAll(self.text[start..self.idx]);
                self.idx += 1;
                try self.genEscapeKey(string);
                start = self.idx;
                self.idx -= 1;
            } else if (self.text[self.idx] == '\n') return error.MultilineIdStringNotSupported;
        }
        if (self.idx >= self.text.len) return error.StringOverflow;
        try string.writeAll(self.text[start..self.idx]);
        return try fin_string.toOwnedSlice();
    } else return error.InvalidStringTypeProvided;
}
/// FOR INTERNAL USE ONLY
pub fn parseNestedPrefix(self: *Toml) ![]const u8 {
    var id_segment = ArrayList(u8).init(self.alloc);
    errdefer id_segment.deinit();
    const segment = id_segment.writer();
    var start: usize = self.idx;

    while (self.idx < self.text.len and self.text[self.idx] != ']' and self.text[self.idx] != '.') : (self.idx += 1) {
        if (self.text[self.idx] == ' ' or self.text[self.idx] == '\t') {
            if (self.idx > start) try segment.writeAll(self.text[start..self.idx]);
            try self.skipWhitespace();
            start = self.idx;
            self.idx -= 1;
        } else if (self.text[self.idx] == '\'' or self.text[self.idx] == '\"') {
            if (self.idx > start) try segment.writeAll(self.text[start..self.idx]);
            var idStr = try self.parseIdString();
            if (idStr) |str| {
                try segment.writeAll(str);
                self.alloc.free(str);
            }
            start = self.idx + 1;
        } else if (self.text[self.idx] == '\n') return error.InvalidPrefixProvided;
    }
    if (self.idx >= self.text.len) return error.StringOverflow;
    if (self.idx > start) try segment.writeAll(self.text[start..self.idx]);

    return try id_segment.toOwnedSlice();
}
/// FOR INTERNAL USE ONLY
pub fn parseId(self: *Toml) ![]const u8 {
    while (self.text.len > self.idx and self.text[self.idx] != ' ' and self.text[self.idx] != '\t' and self.text[self.idx] != '\n') : (self.idx += 1) {}
    if (self.text.len == self.idx or self.text[self.idx] == '\n') return error.InvalidKeyValuePair;
}
/// FOR INTERNAL USE ONLY
pub fn parseValue(self: *Toml) !TableValue {
    switch (self.text[self.idx]) {
        else => return error.InvalidValueProvided,
    }
    self.idx += 1;
}

// fetching functions (internal)
/// FOR INTERNAL USE ONLY
pub fn fetchArrayPrefix(self: *Toml, key: []const u8) !?ArrayEntry {
    return self.array_counts.getEntry(key);
}

pub fn fetchOrGenArrayPrefix(self: *Toml, key: []const u8) !ArrayEntry {
    var entry = try self.array_counts.getOrPutValue(key, 0);
    if (entry.value_ptr.* == 0) {
        entry.key_ptr.* = try self.alloc.dupe(u8, key);
    }
    return entry;
}

// fetching functions (external)

// insertion functions

// generating functions

/// FOR INTERNAL USE ONLY
pub fn genEscapeKey(self: *Toml, writer: anytype) !void {
    switch (self.text[self.idx]) {
        'b' => try writer.writeByte(8),
        't' => try writer.writeByte(9),
        'n' => try writer.writeByte(10),
        'f' => try writer.writeByte(12),
        'r' => try writer.writeByte(13),
        '\"' => try writer.writeByte('\"'),
        '\\' => try writer.writeByte('\\'),
        'x', 'u', 'U' => try self.genHexCode(writer),
        else => return error.InvalidValueProvided,
    }
    self.idx += 1;
}

pub fn genHexCode(self: *Toml, writer: anytype) !void {
    if (self.text[self.idx] == 'x') {
        var byte: u8 = 0;
        for (0..2) |_| {
            self.idx += 1;
            byte *= 16;
            byte += try getHexByte(self.text[self.idx]);
        }
        try writer.writeByte(byte);
    } else if (self.text[self.idx] == 'u') {
        var word: u16 = 0;
        for (0..4) |_| {
            self.idx += 1;
            word *= 16;
            word += try getHexByte(self.text[self.idx]);
        }
        try writer.writeInt(u16, word, .Little);
    } else if (self.text[self.idx] == 'U') {
        var dword: u32 = 0;
        for (0..8) |_| {
            self.idx += 1;
            dword *= 16;
            dword += try getHexByte(self.text[self.idx]);
        }
        try writer.writeInt(u32, dword, .Little);
    } else return error.UnknownHexLength;
}

/// Feel free to use as you will
pub fn getHexByte(char: u8) !u8 {
    switch (char) {
        '0'...'9' => return char - 48,
        'a'...'f' => return char - 87,
        'A'...'F' => return char - 55,
        else => return error.UnknownHexChar,
    }
}

/// FOR INTERNAL USE ONLY
pub fn skipWhitespace(self: *Toml) !void {
    while (self.text.len > self.idx and (self.text[self.idx] == ' ' or self.text[self.idx] == '\t')) : (self.idx += 1) if (self.text[self.idx] == '\n') return error.InvalidNewlineRecieved;
}

/// FOR INTERNAL USE ONLY
pub fn skipNlWhitespace(self: *Toml) void {
    while (self.text.len > self.idx and (self.text[self.idx] == ' ' or self.text[self.idx] == '\t' or self.text[self.idx] == '\n')) self.idx += 1;
}

/// FOR INTERNAL USE ONLY
pub fn skipComment(self: *Toml) void {
    while (self.text.len > self.idx and self.text[self.idx] != '\n') self.idx += 1;
    self.idx += 1;
}

/// This must be called at the end of execution or the end of file life. It frees all of the keys
/// that have been created.
pub fn deinit(self: *Toml) void {
    var array_iter = self.array_counts.iterator();
    while (array_iter.next()) |entry| self.alloc.free(entry.key_ptr.*);
    self.array_counts.deinit();
    if (self.active_prefix) |prefix| self.alloc.free(prefix);
    var hash_iter = self.table.iterator();
    while (hash_iter.next()) |entry| self.alloc.free(entry.key_ptr.*);
    self.table.deinit();
}

// structures

pub const Loc = struct { start: usize, end: usize };
pub const Tag = enum {
    String,
    Integer,
    Float,
    Boolean,
    OffsetDateTime,
    LocalDateTime,
    Date,
    Time,
};
pub const TableValue = struct { tag: Tag, loc: Loc };
pub const TomlValue = union(Tag) {
    String: []const u8,
    Integer: i64,
    Float: f64,
    Boolean: bool,
    OffsetDateTime: TomlOffsetDateTime,
    LocalDateTime: TomlLocalDateTime,
    Date: TomlDate,
    Time: TomlTime,
};

pub const TomlOffsetDateTime = struct { date: TomlDate, time: TomlTime, offset: TomlTimezone };
pub const TomlLocalDateTime = struct { date: TomlDate, time: TomlTime };
pub const TomlDate = struct {
    day: u5,
    month: u4,
    year: u14,
    pub const MAX_DAY = 31;
    pub const MAX_MONTH = 12;
};
pub const TomlTime = struct {
    hour: u5,
    min: u6,
    sec: u6,
    micro: u20,
    pub const MAX_HOUR = 23;
    pub const MAX_MIN = 59;
    pub const MAX_SEC = 59;
    pub const MAX_MICRO = 999999;
};
pub const TomlTimezone = struct {
    hour: i5,
    min: u6,
    pub const MAX_HOUR = 14;
    pub const MIN_HOUR = -12;
    pub const MAX_MIN = 59;
};

// tests

test "Toml Skip Tests" {
    const passed = "passed";
    const test_whitespace = "    \t  passed";
    const test_nl_whitespace =
        \\
        \\  passed
    ;
    const test_comment = "#this should not be visible\npassed";
    var toml = Toml{
        .alloc = std.testing.allocator,
        .text = test_whitespace,
        .table = undefined,
    };

    try toml.skipWhitespace();
    try std.testing.expect(eql(u8, passed, toml.text[toml.idx..]));

    toml.text = test_nl_whitespace;
    toml.idx = 0;
    toml.skipNlWhitespace();
    try std.testing.expect(eql(u8, passed, toml.text[toml.idx..]));

    toml.text = test_comment;
    toml.idx = 0;
    toml.skipComment();
    try std.testing.expect(eql(u8, passed, toml.text[toml.idx..]));
}

test "Toml Escape Key Test" {
    const results = [_][]const u8{ &[_]u8{8}, "\t", "\n", &[_]u8{12}, "\r", "\"", "\\", &[_]u8{0x69}, &[_]u8{ 0xFE, 0xCA }, &[_]u8{ 0xBE, 0xBA, 0xFE, 0xCA } };
    const inputs = [_][]const u8{ "b", "t", "n", "f", "r", "\"", "\\", "x69", "uCafE", "UCaFeBaBe" };
    var toml = Toml{
        .alloc = std.testing.allocator,
        .text = undefined,
        .table = undefined,
    };

    for (inputs, 0..) |input, i| {
        toml.idx = 0;
        toml.text = input;
        var output = ArrayList(u8).init(toml.alloc);
        errdefer output.deinit();
        const wout = output.writer();
        try toml.genEscapeKey(wout);
        var out = try output.toOwnedSlice();
        std.testing.expect(eql(u8, results[i], out)) catch {
            std.debug.print("Incorrectly parsed \\{c}\n", .{inputs[i][0]});
        };
        toml.alloc.free(out);
    }
}

test "Toml Parse Table Name" {
    const tbl_name_1 = "p.ass.\'ed\']";
    const tbl_name_2 = "p.ass.\"e\\x64\"]";
    const nest_tbl_1 = "[p.ass]]";
    const nest_tbl_2 = "[p.ass.ed]]";

    var toml = Toml{
        .alloc = std.testing.allocator,
        .text = tbl_name_1,
        .table = undefined,
        .array_counts = std.StringHashMap(u64).init(std.testing.allocator),
    };

    defer {
        var array_itter = toml.array_counts.keyIterator();
        while (array_itter.next()) |entry| toml.alloc.free(entry.*);
        toml.array_counts.deinit();
        if (toml.active_prefix) |prefix| toml.alloc.free(prefix);
    }

    try toml.parsePrefix();
    try std.testing.expect(eql(u8, "p.ass.ed", toml.active_prefix.?));
    toml.alloc.free(toml.active_prefix.?);
    toml.active_prefix = null;

    toml.text = tbl_name_2;
    toml.idx = 0;
    try toml.parsePrefix();
    try std.testing.expect(eql(u8, "p.ass.ed", toml.active_prefix.?));
    toml.alloc.free(toml.active_prefix.?);
    toml.active_prefix = null;

    toml.text = nest_tbl_1;
    toml.idx = 0;
    try toml.parsePrefix();
    try std.testing.expect(eql(u8, "p.ass[0]", toml.active_prefix.?));
    toml.alloc.free(toml.active_prefix.?);
    toml.active_prefix = null;

    toml.text = nest_tbl_2;
    toml.idx = 0;
    try toml.parsePrefix();
    try std.testing.expect(eql(u8, "p.ass[0].ed[0]", toml.active_prefix.?));
    toml.alloc.free(toml.active_prefix.?);
    toml.active_prefix = null;
}
