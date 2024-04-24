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

/// Initializes Toml from recieved text. Result must have deinit() called before end of execution. (INCOMPLETE)
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
/// of initialization. (INCOMPLETE)
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

/// FOR INTERNAL USE ONLY (WORKING)
pub fn parsePrefix(self: *Toml) !void {
    if (self.active_prefix) |prefix| self.alloc.free(prefix);
    var fin_prefix = ArrayList(u8).init(self.alloc);
    errdefer fin_prefix.deinit();
    const prefix = fin_prefix.writer();

    if (self.text[self.idx] == '[') {
        // parse table array
        self.idx += 1;
        while (self.idx < self.text.len and self.text[self.idx] != ']') {
            // find next entry
            var next_segment = try self.parseNestedPrefix();
            try prefix.writeAll(next_segment);
            self.alloc.free(next_segment);

            // add index if entry is table
            var entry = try self.fetchArrayPrefix(fin_prefix.items);
            if (entry) |ent| {
                if (self.text[self.idx] != ']') ent.value_ptr.* -= 1;
                try prefix.print("[{d}]", .{ent.value_ptr.*});
                ent.value_ptr.* += 1;
            }
            // check for last segment
            if (self.text[self.idx] == '.') {
                try prefix.writeByte('.');
                self.idx += 1;
            }
        }
        if (self.idx >= self.text.len) return error.StringOverflow;
        self.idx += 1;
        // create or find table array index
        var table_entry = try self.fetchOrGenArrayPrefix(fin_prefix.items);
        try prefix.print("[{d}]", .{table_entry.value_ptr.*});
        table_entry.value_ptr.* += 1;
        self.active_prefix = try fin_prefix.toOwnedSlice();
    } else {
        while (self.idx < self.text.len and self.text[self.idx] != ']') {
            // parse regular table
            var next_segment = try self.parseNestedPrefix();
            defer self.alloc.free(next_segment);
            try prefix.writeAll(next_segment);

            // add index if entry is array
            var entry = try self.fetchArrayPrefix(fin_prefix.items);
            if (entry) |ent| {
                if (self.text[self.idx] != ']') ent.value_ptr.* -= 1;
                try prefix.print("[{d}]", .{ent.value_ptr.*});
                ent.value_ptr.* += 1;
            }
            // check for last segment
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
/// FOR INTERNAL USE ONLY (WORKING)
pub fn parseIdString(self: *Toml) !?[]const u8 {
    var start: usize = 0;
    var fin_string = ArrayList(u8).init(self.alloc);
    errdefer fin_string.deinit();
    const string = fin_string.writer();

    if (self.text[self.idx] == '\'') {
        // parse lit string
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
        // parse base string
        self.idx += 1;
        if (self.text[self.idx] == '\"') return error.MultilineIdStringNotSupported;
        start = self.idx;

        while (self.idx < self.text.len and self.text[self.idx] != '\"') : (self.idx += 1) {
            if (self.text[self.idx] == '\\') {
                // parse escape key
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
/// FOR INTERNAL USE ONLY (WORKING)
pub fn parseNestedPrefix(self: *Toml) ![]const u8 {
    var id_segment = ArrayList(u8).init(self.alloc);
    errdefer id_segment.deinit();
    const segment = id_segment.writer();
    var start: usize = self.idx;

    // find next dotted value
    while (self.idx < self.text.len and self.text[self.idx] != ']' and self.text[self.idx] != '.') : (self.idx += 1) {
        if (self.text[self.idx] == ' ' or self.text[self.idx] == '\t') {
            // skip whitespace
            if (self.idx > start) try segment.writeAll(self.text[start..self.idx]);
            try self.skipWhitespace();
            start = self.idx;
            self.idx -= 1;
        } else if (self.text[self.idx] == '\'' or self.text[self.idx] == '\"') {
            // parse string
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
/// FOR INTERNAL USE ONLY (INCOMPLETE)
pub fn parseId(self: *Toml) ![]const u8 {
    while (self.text.len > self.idx and self.text[self.idx] != ' ' and self.text[self.idx] != '\t' and self.text[self.idx] != '\n') : (self.idx += 1) {}
    if (self.text.len == self.idx or self.text[self.idx] == '\n') return error.InvalidKeyValuePair;
}
/// FOR INTERNAL USE ONLY (WORKING)
pub fn parseValue(self: *Toml) !TableValue {
    switch (self.text[self.idx]) {
        '\'', '\"' => {
            // gen string
            var start = self.idx;
            self.idx += 1;
            if (self.text[self.idx] == '\'') {
                // if literal just go until next '
                var multiline = self.text.len > self.idx + 2 and self.text[self.idx + 1] == '\'' and self.text[self.idx + 2] == '\'';
                if (multiline) self.idx += 3;
                while (self.idx < self.text.len and self.text[self.idx] != '\'') self.idx += 1;
                // verify valid multiling
                if (multiline) {
                    if (self.text.len > self.idx + 2 and self.text[self.idx + 1] == '\'' and self.text[self.idx + 2] == '\'') self.idx += 2 else return error.InvalidMultilineString;
                }
                return if (self.idx < self.text.len) .{ .tag = .String, .loc = .{ .start = start, .end = self.idx } } else return error.StringOverflow;
            } else {
                // if base skip \" otherwise go until next "
                var multiline = self.text.len > self.idx + 2 and self.text[self.idx + 1] == '\"' and self.text[self.idx + 2] == '\"';
                if (multiline) self.idx += 2;
                while (self.idx < self.text.len and self.text[self.idx] != '\"') : (self.idx += 1) {
                    if (self.text[self.idx] == '\\' and self.text[self.idx + 1] == '\"') self.idx += 1;
                }
                // verify valid multiline
                if (multiline) {
                    if (self.text.len > self.idx + 2 and self.text[self.idx + 1] == '\"' and self.text[self.idx + 2] == '\"') self.idx += 2 else return error.InvalidMultilineString;
                }
                return if (self.idx < self.text.len) .{ .tag = .String, .loc = .{ .start = start, .end = self.idx } } else return error.StringOverflow;
            }
        },
        '+', '-', '0'...'9', 'i', 'n' => {
            // generate int, float, concept, time, date, datetime, and offsetdatetime
            var start = self.idx;
            var is_float = false;
            // signed check
            if (self.text[self.idx] == '+' or self.text[self.idx] == '-') self.idx += 1;
            if (self.text[self.idx] == 'i' or self.text[self.idx] == 'n') {
                // if concept parse concept
                if (self.text.len <= self.idx + 2) return error.UnknownConcept;
                self.idx += 1;
                if (self.text[self.idx] == 'n' and self.text[self.idx + 1] == 'f') {
                    self.idx += 2;
                    return .{ .tag = .Concept, .loc = .{ .start = start, .end = self.idx } };
                } else if (self.text[self.idx] == 'a' and self.text[self.idx + 1] == 'n') {
                    self.idx += 2;
                    return .{ .tag = .Concept, .loc = .{ .start = start, .end = self.idx } };
                } else return error.UnknownConcept;
            } else if (self.text.len > self.idx + 9 and self.text[self.idx + 4] == '-' and self.text[self.idx + 7] == '-') {
                // parse date
                self.idx += 10;
                if (self.text.len > self.idx and self.text[self.idx] == 'T') {
                    // parse date time
                    self.idx += 1;
                    if (self.text.len > self.idx + 7 and self.text[self.idx + 2] == ':' and self.text[self.idx + 5] == ':') {
                        self.idx += 8;
                        if (self.text.len > self.idx and self.text[self.idx] == '.') {
                            self.idx += 1;
                            while (self.text.len > self.idx and self.text[self.idx] > 47 and self.text[self.idx] < 58) self.idx += 1;
                        }
                        if (self.text.len > self.idx + 5 and (self.text[self.idx] == '+' or self.text[self.idx] == '-') and self.text[self.idx + 3] == ':') {
                            // parse offset date time
                            self.idx += 6;
                            return .{ .tag = .OffsetDateTime, .loc = .{ .start = start, .end = self.idx } };
                        } else if (self.text.len > self.idx and self.text[self.idx] == 'Z') {
                            self.idx += 1;
                            return .{ .tag = .OffsetDateTime, .loc = .{ .start = start, .end = self.idx } };
                        } else return .{ .tag = .LocalDateTime, .loc = .{ .start = start, .end = self.idx } };
                    } else return error.InvalidTimeInDateTime;
                } else return .{ .tag = .Date, .loc = .{ .start = start, .end = self.idx } };
            } else if (self.text.len > self.idx + 7 and self.text[self.idx + 2] == ':' and self.text[self.idx + 5] == ':') {
                // parse time
                self.idx += 8;
                if (self.text.len > self.idx and self.text[self.idx] == '.') {
                    self.idx += 1;
                    while (self.text.len > self.idx and (self.text[self.idx] > 47 and self.text[self.idx] < 58)) self.idx += 1;
                }
                return .{ .tag = .Time, .loc = .{ .start = start, .end = self.idx } };
            }
            if (self.text[self.idx] == '0') {
                self.idx += 1;
                switch (self.text[self.idx]) {
                    'x', 'X' => {
                        // parse hex int
                        self.idx += 1;
                        while (self.idx < self.text.len and ((self.text[self.idx] > 47 and self.text[self.idx] < 58) or (self.text[self.idx] > 64 and self.text[self.idx] < 71) or (self.text[self.idx] > 96 and self.text[self.idx] < 103) or self.text[self.idx] == '_')) self.idx += 1;
                    },
                    'o', 'O' => {
                        // parse octal int
                        self.idx += 1;
                        while (self.idx < self.text.len and ((self.text[self.idx] > 47 and self.text[self.idx] < 56) or self.text[self.idx] == '_')) self.idx += 1;
                    },
                    'b', 'B' => {
                        // parse binary int
                        self.idx += 1;
                        while (self.idx < self.text.len and ((self.text[self.idx] > 47 and self.text[self.idx] < 50) or self.text[self.idx] == '_')) self.idx += 1;
                    },
                    else => {
                        // parse base 10 int
                        while (self.idx < self.text.len and ((self.text[self.idx] > 47 and self.text[self.idx] < 58) or self.text[self.idx] == '_')) self.idx += 1;
                    },
                }
            } else while (self.idx < self.text.len and ((self.text[self.idx] > 47 and self.text[self.idx] < 58) or self.text[self.idx] == '_')) self.idx += 1;
            // parse float
            if (self.idx < self.text.len and self.text[self.idx] == '.') {
                self.idx += 1;
                while (self.idx < self.text.len and ((self.text[self.idx] > 47 and self.text[self.idx] < 58) or self.text[self.idx] == '_')) self.idx += 1;
                is_float = true;
            }
            // parse exponent
            if (self.idx < self.text.len and (self.text[self.idx] == 'e' or self.text[self.idx] == 'E')) {
                self.idx += 1;
                is_float = true;
                if (self.text[self.idx] == '+' or self.text[self.idx] == '-') self.idx += 1;
                while (self.idx < self.text.len and self.text[self.idx] > 47 and self.text[self.idx] < 58) self.idx += 1;
            }
            if (is_float) return .{ .tag = .Float, .loc = .{ .start = start, .end = self.idx } };
            return if (self.idx <= self.text.len) TableValue{ .tag = .Integer, .loc = .{ .start = start, .end = self.idx } } else return error.IntegerOverflow;
        },
        't', 'f' => {
            // parse a bool value
            var start = self.idx;
            if (self.text.len >= self.idx + 3 and self.text[self.idx + 1] == 'r' and self.text[self.idx + 2] == 'u' and self.text[self.idx + 3] == 'e') {
                self.idx += 4;
                return .{ .tag = .Boolean, .loc = .{ .start = start, .end = self.idx } };
            } else if (self.text.len > self.idx + 4 and self.text[self.idx + 1] == 'a' and self.text[self.idx + 2] == 'l' and self.text[self.idx + 3] == 's' and self.text[self.idx + 4] == 'e') {
                self.idx += 5;
                return .{ .tag = .Boolean, .loc = .{ .start = start, .end = self.idx } };
            } else return error.InvalidBoolean;
        },
        '[' => {
            // lazy parse an array value
            var start = self.idx;
            while (self.text.len > self.idx and self.text[self.idx] != ']') self.idx += 1;
            if (self.text.len <= self.idx) return error.InvalidArrayProvided;
            self.idx += 1;
            return .{ .tag = .Array, .loc = .{ .start = start, .end = self.idx } };
        },
        else => return error.InvalidValueProvided,
    }
}

/// FOF INTERNAL USE ONLY (UNTESTED)
pub fn parseString(self: *Toml, start: usize, end: usize) ![]const u8 {
    if (self.text[start] == '\'') {
        // if literal return string copy
        return try self.alloc.dupe(self.text[start + 1 .. end]);
    } else if (self.text[start] == '\"') {
        var string = ArrayList(u8).init(self.alloc);
        errdefer string.deinit();
        const str = string.writer();
        self.idx = start + 1;
        var s_start = self.idx;
        var multiline_enable = false;
        // check for multiline
        if (self.text.len > self.idx + 2 and self.text[self.idx] == '\"' and self.text[self.idx + 1] == '\"') {
            multiline_enable = true;
            self.idx += 2;
        }
        // parse string, including escape characters
        while (self.text.len > self.idx and self.text[self.idx] != '\"') : (self.idx += 1) {
            if (self.text[self.idx] == '\\') {
                if (self.idx > s_start) try str.writeAll(self.text[s_start..self.idx]);
                self.idx += 1;
                try self.genEscapeKey(std);
                s_start = self.idx;
                self.idx -= 1;
            } else if (multiline_enable and self.text[self.idx] == '\n') return error.MultilineStringInSingleString;
        }
        if (self.idx > s_start) try str.writeAll(self.text[s_start..self.idx]);
        // verify valid multiline
        if (multiline_enable and self.text > self.idx + 2 and self.text[self.idx + 1] == '\"' and self.text[self.idx + 2] == '\"') self.idx += 2;
        return try string.toOwnedSlice();
    } else return error.UnkownStringType;
}

/// FOR INTERNAL USE ONLY (UNTESTED)
pub fn parseInt(self: *Toml, start: usize, end: usize) !i64 {
    var signed = false;
    // check if signed
    self.text[start] == '-';
    var int: i64 = 0;
    if (self.text[start] == '-' or self.text[self.idx] == '+') self.idx += 1;
    if (self.idx < end) {
        if (self.text[self.idx] == '0' and self.end > self.idx + 2) {
            self.idx += 1;
            switch (self.text[self.idx]) {
                'x', 'X' => {
                    // parse hex
                    self.idx += 1;
                    while (self.idx < end and ((self.text[self.idx] > 47 and self.text[self.idx] < 58) or (self.text[self.idx] > 64 and self.text[self.idx] < 71) or (self.text[self.idx] > 96 and self.text[self.idx] < 103) or self.text[self.idx] == '_')) : (self.idx += 1) {
                        int *= 16;
                        int += if (self.text[self.idx] > 47 and self.text[self.idx] < 58) @as(i64, @intCast(self.text[self.idx])) - 48 else if (self.text[self.idx] > 64 and self.text[self.idx] < 71) @as(i64, self.text[self.idx]) - 55 else if (self.text[self.idx] > 96 and self.text[self.idx] < 103) @as(i64, @intCast(self.text[self.idx])) - 87 else if (self.text[self.idx] == '_') 0 else return error.UnkownDigitRecieved;
                        if (self.text[self.idx] == '_') int /= 16;
                    }
                    if (signed) int *= -1;
                    return int;
                },
                'o', 'O' => {
                    // parse octal
                    self.idx += 1;
                    while (self.idx < end and ((self.text[self.idx] > 47 and self.text[self.idx] < 56) or self.text[self.idx] == '_')) : (self.idx += 1) {
                        int *= 8;
                        if (self.text[self.idx] != '_') {
                            int += @as(u64, @intCast(self.text[self.idx])) - 48;
                        } else int /= 8;
                    }
                    if (signed) int *= -1;
                    return int;
                },
                'b', 'B' => {
                    // parse binary
                    self.idx += 1;
                    while (self.idx < end and ((self.text[self.idx] > 47 and self.text[self.idx] < 50) or self.text[self.idx] == '_')) : (self.idx += 1) {
                        int *= 2;
                        if (self.text[self.idx] != '_') {
                            int += @as(u64, @intCast(self.text[self.idx])) - 48;
                        } else int /= 2;
                    }
                    if (signed) int *= -1;
                    return int;
                },
                else => {},
            }
        }
        // parse base 10
        while (end > self.idx and self.text[self.idx] > 47 and self.text[self.idx] < 56) : (self.idx += 1) {
            int *= 10;
            if (self.text[self.idx] != '_') {
                int += @as(i64, @intCast(self.text[self.idx])) - 48;
            } else int /= 10;
        }
        if (signed) int *= -1;
        return int;
    } else return error.InvalidIntegerDetected;
}

/// FOR INTERNAL USE ONLY (UNTESTED)
pub fn parseFloat(self: *Toml, start: usize, end: usize) !TomlFloat {
    self.idx = start;
    // find signing
    var signed = false;
    if (self.text[self.idx] == '-') signed = true;
    if (self.text[self.idx] == '+' or signed) self.idx += 1;
    var float = TomlFloat{ .whole = 0, .part = 0, .exp = 0 };
    // find whole part of float
    while (self.idx < end and self.text[self.idx] != '.' and self.text[self.idx] != 'e' and self.text[self.idx] != 'E') : (self.idx += 1) {
        float.whole *= 10;
        if (self.text[self.idx] > 47 and self.text[self.idx] < 58) {
            float.whole += @as(i64, @intCast(self.text[self.idx])) - 48;
        } else if (self.text[self.idx] == '_') {
            float.whole /= 10;
        } else return error.InvalidFloatCharacter;
    }
    if (signed) float.whole *= -1;
    signed = false;

    // find fraction of float
    if (self.text[self.idx] == '.') {
        self.idx += 1;
        while (self.idx < end and self.text[self.idx] != '.' and self.text[self.idx] != 'e' and self.text[self.idx] != 'E') : (self.idx += 1) {
            float.part *= 10;
            // add or skip _
            if (self.text[self.idx] > 47 and self.text[self.idx] < 58) {
                float.part += @as(i64, @intCast(self.text[self.idx])) - 48;
            } else if (self.text[self.idx] == '_') {
                float.part /= 10;
            } else return error.InvalidFloatCharacter;
        }
    }

    // find exponent of fraction
    if (self.text[self.idx] == 'e' or self.text[self.idx] == 'E') {
        self.idx += 1;
        // signing
        if (self.text[self.idx] == '-') signed = true;
        if (self.text[self.idx] == '+' or signed) self.idx += 1;
        while (self.idx < end and self.text[self.idx] != '.' and self.text[self.idx] != 'e' and self.text[self.idx] != 'E') : (self.idx += 1) {
            float.part *= 10;
            // add or skip _
            if (self.text[self.idx] > 47 and self.text[self.idx] < 58) {
                float.exp += @as(i64, @intCast(self.text[self.idx])) - 48;
            } else if (self.text[self.idx] == '_') {
                float.exp /= 10;
            } else return error.InvalidFloatCharacter;
        }
        if (signed) float.exp *= -1;
    }

    return float;
}

/// FOR INTERNAL USE ONLY (UNTESTED)
pub fn parseBoolean(self: *Toml, start: usize, end: usize) !bool {
    if (start - end == 4) {
        if (eql(u8, "true", self.text[start..end])) return true else return error.InvalidBoolProvided;
    } else if (start - end == 5) {
        if (eql(u8, "false", self.text[start..end])) return false else return error.InvalidBoolProvided;
    } else return error.InvalidBoolProvided;
}

/// FOR INTERNAL USE ONLY (UNTESTED)
pub fn parseConcept(self: *Toml, start: usize, end: usize) !TomlConcept {
    self.idx = start;
    // check for sign (ignored)
    if (self.text[start] == '+' or self.text[start] == '-') self.idx += 1;
    // find concept
    if (eql(u8, "nan", self.text[self.idx..end])) {
        return .NOT_A_NUMBER;
    } else if (eql(u8, "inf", self.text[self.idx..end])) {
        return .INFINITY;
    } else return error.UnknownConceptProvided;
}

/// FOR INTERNAL USE ONLY (UNTESTED)
pub fn parseTime(self: *Toml, start: usize) !TomlTime {
    self.idx = start;
    var time = TomlTime{ .hour = 0, .min = 0, .sec = 0, .micro = 0 };
    // parse hour
    time.hour += @as(u5, @intCast(self.text[self.idx] - 48)) * 10;
    time.hour += @as(u5, @intCast(self.text[self.idx + 1] - 48));
    self.idx += 2;
    // parse minute
    if (self.text[self.idx] != ':') return error.InvalidTime;
    self.idx += 1;
    time.min += @as(u5, @intCast(self.text[self.idx] - 48)) * 10;
    time.min += @as(u5, @intCast(self.text[self.idx + 1] - 48));
    self.idx += 2;
    // parse second
    if (self.text[self.idx] != ':') return error.InvalidTime;
    self.idx += 1;
    time.sec += @as(u5, @intCast(self.text[self.idx] - 48)) * 10;
    time.sec += @as(u5, @intCast(self.text[self.idx + 1] - 48));
    self.idx += 2;
    // parse fraction
    if (self.text[self.idx] == '.') {
        while (self.text[self.idx] > 47 and self.text[self.idx] < 56) {
            time.micro *= 10;
            time.micro += @as(u5, @intCast(self.text[self.idx + 1] - 48));
        }
    }
    return time;
}

/// FOR INTERNAL USE ONLY (UNTESTED)
pub fn parseDate(self: *Toml, start: usize) !TomlDate {
    self.idx = start;
    var date = TomlDate{ .year = 0, .month = 0, .day = 0 };
    // parse year
    date.year += @as(u14, @intCast(self.text[self.idx] - 48)) * 1000;
    date.year += @as(u14, @intCast(self.text[self.idx + 1] - 48)) * 100;
    date.year += @as(u14, @intCast(self.text[self.idx + 2] - 48)) * 10;
    date.year += @as(u14, @intCast(self.text[self.idx + 3] - 48));
    self.idx += 4;
    // parse month
    if (self.text[self.idx] != '-') return error.InvalidDateProvided;
    self.idx += 1;
    date.month += @as(u4, @intCast(self.text[self.idx] - 48)) * 10;
    date.month += @as(u4, @intCast(self.text[self.idx + 1] - 48));
    self.idx += 2;
    // parse day
    if (self.text[self.idx] != '-') return error.InvalidDateProvided;
    self.idx += 1;
    date.day += @as(u5, @intCast(self.text[self.idx] - 48)) * 10;
    date.day += @as(u5, @intCast(self.text[self.idx + 1] - 48));
    self.idx += 2;
    return date;
}

/// FOR INTERNAL USE ONLY (UNTESTED)
pub fn parseLocalDateTime(self: *Toml, start: usize) !TomlLocalDateTime {
    // parse date and time
    self.idx = start;
    var date = try self.parseDate(start);
    if (self.text[self.idx] != 'T') return error.InvalidLocalDateTime;
    self.idx += 1;
    var time = try self.parseTime(self.idx);
    return TomlLocalDateTime{ .date = date, .time = time };
}

/// FOR INTERNAL USE ONLY (UNTESTED)
pub fn parseOffsetDateTime(self: *Toml, start: usize) !TomlOffsetDateTime {
    // parse date and time of value
    self.idx = start;
    var date_time = try self.parseLocalDateTime(start);
    // parse offset
    if (self.text[self.idx] == 'Z') return .{ .time = date_time.time, .date = date_time.date, .offset = .{ .hour = 0, .min = 0 } };
    var signed = self.text[self.idx] == '-';
    if (self.text[self.idx] == '+' or signed) self.idx += 1;
    // offset hour
    var offset = TomlTimezone{ .hour = 0, .min = 0 };
    offset.hour += @as(i5, @intCast(self.text[self.idx] - 48)) * 10;
    offset.hour += @as(i5, @intCast(self.text[self.idx + 1] - 48));
    if (signed) offset.hour *= -1;
    self.idx += 2;
    // offset minute
    if (self.text[self.idx] != ':') return error.InvalidOffsetProvided;
    self.idx += 1;
    offset.min += @as(u6, @intCast(self.text[self.idx] - 48)) * 10;
    offset.min += @as(u6, @intCast(self.text[self.idx + 1] - 48));
    self.idx += 2;
    return .{ .date = date_time.date, .time = date_time.time, .offset = offset };
}

/// FOR INTERNAL USE ONLY (INCOMPLETE)
pub fn parseArray(self: *Toml, start: usize) ![]TomlValue {
    self.idx = start;
    if (self.text[self.idx] != '[') return error.InvalidArrayProvided;
    var values = ArrayList(TomlValue).init(self.alloc);
    errdefer values.deinit();

    while (self.text.len > self.idx and self.text[self.idx] != ']') : (self.idx += 1) {
        switch (self.text[self.idx]) {}
    }
}

// fetching functions (internal)
/// FOR INTERNAL USE ONLY (WORKING)
pub fn fetchArrayPrefix(self: *Toml, key: []const u8) !?ArrayEntry {
    // check for table array value return it if exists
    return self.array_counts.getEntry(key);
}

/// FOR INTERNAL USE ONLY (WORKING)
pub fn fetchOrGenArrayPrefix(self: *Toml, key: []const u8) !ArrayEntry {
    // generate table array if it doesnt exist or return current array
    var entry = try self.array_counts.getOrPutValue(key, 0);
    if (entry.value_ptr.* == 0) {
        entry.key_ptr.* = try self.alloc.dupe(u8, key);
    }
    return entry;
}

// fetching functions (external)

// insertion functions

// generating functions

/// FOR INTERNAL USE ONLY (UNTESTED)
pub fn genTomlValue(self: *Toml, value: TableValue) !TomlValue {
    // generate appropriate TomlValue based on tag
    switch (value.tag) {
        .String => return @unionInit(TomlValue, "String", try self.parseString(value.loc.start, value.loc.end)),
        .Integer => return @unionInit(TomlValue, "Integer", try self.parseInt(value.loc.start, value.loc.end)),
        .Float => return @unionInit(TomlValue, "Float", try self.parseFloat(value.loc.start, value.loc.end)),
        .Boolean => return @unionInit(TomlValue, "Boolean", try self.parseBoolean(value.loc.start, value.loc.end)),
        .Concept => return @unionInit(TomlValue, "Boolean", try self.parseConcept(value.loc.start, value.loc.end)),
        .Date => return @unionInit(TomlValue, "Date", try self.parseDate(value.loc.start)),
        .Time => return @unionInit(TomlValue, "Time", try self.parseTime(value.loc.start)),
        .LocalDateTime => return @unionInit(TomlValue, "LocalDateTime", try self.parseLocalDateTime(value.loc.start)),
        .OffsetDateTime => return @unionInit(TomlValue, "OffsetDateTime", try self.parseOffsetDateTime(value.loc.start)),
        .Array => {},
        else => @compileError("Values Of Type " ++ @tagName(value.tag) ++ " Is not yet parsable"),
    }
}

/// FOR INTERNAL USE ONLY (WORKING)
pub fn genEscapeKey(self: *Toml, writer: anytype) !void {
    // generate escape key character code
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

/// FOR INTERNAL USE ONLY (WORKING)
pub fn genHexCode(self: *Toml, writer: anytype) !void {
    if (self.text[self.idx] == 'x') {
        // parse two digit hex number
        var byte: u8 = 0;
        for (0..2) |_| {
            self.idx += 1;
            byte *= 16;
            byte += try getHexByte(self.text[self.idx]);
        }
        try writer.writeByte(byte);
    } else if (self.text[self.idx] == 'u') {
        // parse four digit hex number
        var word: u16 = 0;
        for (0..4) |_| {
            self.idx += 1;
            word *= 16;
            word += try getHexByte(self.text[self.idx]);
        }
        try writer.writeInt(u16, word, .Little);
    } else if (self.text[self.idx] == 'U') {
        // parse eight digit hex number
        var dword: u32 = 0;
        for (0..8) |_| {
            self.idx += 1;
            dword *= 16;
            dword += try getHexByte(self.text[self.idx]);
        }
        try writer.writeInt(u32, dword, .Little);
    } else return error.UnknownHexLength;
}

/// Feel free to use as you will (WORKING)
pub fn getHexByte(char: u8) !u8 {
    // conver a hex digit to numeric value
    switch (char) {
        '0'...'9' => return char - 48,
        'a'...'f' => return char - 87,
        'A'...'F' => return char - 55,
        else => return error.UnknownHexChar,
    }
}

/// FOR INTERNAL USE ONLY (WORKING)
pub fn skipWhitespace(self: *Toml) !void {
    // itterate over whitespace until new char, errors at newline
    while (self.text.len > self.idx and (self.text[self.idx] == ' ' or self.text[self.idx] == '\t')) : (self.idx += 1) if (self.text[self.idx] == '\n') return error.InvalidNewlineRecieved;
}

/// FOR INTERNAL USE ONLY (WORKING)
pub fn skipNlWhitespace(self: *Toml) void {
    // itterate over whitespace until new character
    while (self.text.len > self.idx and (self.text[self.idx] == ' ' or self.text[self.idx] == '\t' or self.text[self.idx] == '\n')) self.idx += 1;
}

/// FOR INTERNAL USE ONLY (WORKING)
pub fn skipComment(self: *Toml) void {
    // itterate over comment until passed newline
    while (self.text.len > self.idx and self.text[self.idx] != '\n') self.idx += 1;
    self.idx += 1;
}

/// This must be called at the end of execution or the end of file life. It frees all of the keys
/// that have been created. (PARTIALY TESTED)
pub fn deinit(self: *Toml) void {
    // free array indexes for array table parsing
    var array_iter = self.array_counts.iterator();
    while (array_iter.next()) |entry| self.alloc.free(entry.key_ptr.*);
    self.array_counts.deinit();
    // free prefix for parsing
    if (self.active_prefix) |prefix| self.alloc.free(prefix);
    // free actual table values
    var hash_iter = self.table.iterator();
    while (hash_iter.next()) |entry| self.alloc.free(entry.key_ptr.*);
    self.table.deinit();
}

// structures
/// for use in table
/// holds start and end of value
pub const Loc = struct { start: usize, end: usize };
/// for value use
/// differentiates between different supported data types
pub const Tag = enum {
    String,
    Integer,
    Concept,
    Float,
    Boolean,
    OffsetDateTime,
    LocalDateTime,
    Date,
    Time,
    Array,
};
/// for use in table
/// holds type and location data of value
pub const TableValue = struct { tag: Tag, loc: Loc };
/// for external use
/// holds type and data of value
pub const TomlValue = union(Tag) {
    String: []const u8,
    Integer: i64,
    Concept: TomlConcept,
    Float: TomlFloat,
    Boolean: bool,
    OffsetDateTime: TomlOffsetDateTime,
    LocalDateTime: TomlLocalDateTime,
    Date: TomlDate,
    Time: TomlTime,
    Array: []TomlValue,
};
/// for external use
/// contains number concepts like infinity and not a number
pub const TomlConcept = enum { INFINITY, NOT_A_NUMBER };
/// for external use
/// holds float with precision that is lost in float format
pub const TomlFloat = struct { whole: i64 = 0, part: u64 = 0, exp: i64 = 0 };
/// for external use
/// holds a date, time, and timezone
pub const TomlOffsetDateTime = struct { date: TomlDate, time: TomlTime, offset: TomlTimezone };
/// for external use
/// holds a date and time
pub const TomlLocalDateTime = struct { date: TomlDate, time: TomlTime };
/// for external use
/// date info and constants
pub const TomlDate = struct {
    day: u5,
    month: u4,
    year: u14,
    pub const MAX_DAY = 31;
    pub const MAX_MONTH = 12;
};
/// for external use
/// time info and constants
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
/// for external use
/// timezone info and constants
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

    // test skiping whitespace and erroring on nl
    try toml.skipWhitespace();
    try std.testing.expect(eql(u8, passed, toml.text[toml.idx..]));

    // test skiping whitespace
    toml.text = test_nl_whitespace;
    toml.idx = 0;
    toml.skipNlWhitespace();
    try std.testing.expect(eql(u8, passed, toml.text[toml.idx..]));

    // test skipping commets
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
        // test all possible escape characters
        toml.idx = 0;
        toml.text = input;
        var output = ArrayList(u8).init(toml.alloc);
        errdefer output.deinit();
        const wout = output.writer();
        try toml.genEscapeKey(wout);
        var out = try output.toOwnedSlice();
        try std.testing.expect(eql(u8, results[i], out));
        toml.alloc.free(out);
    }
}

test "Toml Table Name Test" {
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

    // test normal prefix with lit string
    try toml.parsePrefix();
    try std.testing.expect(eql(u8, "p.ass.ed", toml.active_prefix.?));
    toml.alloc.free(toml.active_prefix.?);
    toml.active_prefix = null;

    // test normal prefix with base string
    toml.text = tbl_name_2;
    toml.idx = 0;
    try toml.parsePrefix();
    try std.testing.expect(eql(u8, "p.ass.ed", toml.active_prefix.?));
    toml.alloc.free(toml.active_prefix.?);
    toml.active_prefix = null;

    // test array table generation
    toml.text = nest_tbl_1;
    toml.idx = 0;
    try toml.parsePrefix();
    try std.testing.expect(eql(u8, "p.ass[0]", toml.active_prefix.?));
    toml.alloc.free(toml.active_prefix.?);
    toml.active_prefix = null;

    // test nested array table generation
    toml.text = nest_tbl_2;
    toml.idx = 0;
    try toml.parsePrefix();
    try std.testing.expect(eql(u8, "p.ass[0].ed[0]", toml.active_prefix.?));
    toml.alloc.free(toml.active_prefix.?);
    toml.active_prefix = null;
}

test "Toml Value Parse Test" {
    const tests = [_][]const u8{
        "\"\\\"passed\\\"\"",
        "69420",
        "-69420",
        "69_420",
        "0xCAFEBABE",
        "0o377",
        "0b10111011",
        "3.14159",
        "6.022e-23",
        "-inf",
        "-nan",
        "true",
        "false",
        "2024-04-10T12:56:49-05:00",
        "2024-04-10T01:00:12",
        "2024-04-10",
        "01:00:58",
        "[\"test\", \"passed\"]",
        "['p', 1, 'u', 2, 'b', 3, 'l', 4, 'i', 5, 'c', 6]",
    };
    const table_results = [_]TableValue{
        .{ .tag = .String, .loc = .{ .start = 0, .end = 11 } },
        .{ .tag = .Integer, .loc = .{ .start = 0, .end = 5 } },
        .{ .tag = .Integer, .loc = .{ .start = 0, .end = 6 } },
        .{ .tag = .Integer, .loc = .{ .start = 0, .end = 6 } },
        .{ .tag = .Integer, .loc = .{ .start = 0, .end = 10 } },
        .{ .tag = .Integer, .loc = .{ .start = 0, .end = 5 } },
        .{ .tag = .Integer, .loc = .{ .start = 0, .end = 10 } },
        .{ .tag = .Float, .loc = .{ .start = 0, .end = 7 } },
        .{ .tag = .Float, .loc = .{ .start = 0, .end = 9 } },
        .{ .tag = .Concept, .loc = .{ .start = 0, .end = 4 } },
        .{ .tag = .Concept, .loc = .{ .start = 0, .end = 4 } },
        .{ .tag = .Boolean, .loc = .{ .start = 0, .end = 4 } },
        .{ .tag = .Boolean, .loc = .{ .start = 0, .end = 5 } },
        .{ .tag = .OffsetDateTime, .loc = .{ .start = 0, .end = 25 } },
        .{ .tag = .LocalDateTime, .loc = .{ .start = 0, .end = 19 } },
        .{ .tag = .Date, .loc = .{ .start = 0, .end = 10 } },
        .{ .tag = .Time, .loc = .{ .start = 0, .end = 8 } },
        .{ .tag = .Array, .loc = .{ .start = 0, .end = 18 } },
        .{ .tag = .Array, .loc = .{ .start = 0, .end = 48 } },
    };
    const toml_results = [_]TomlValue{
        @unionInit(TomlValue, "String", "\"passed\""),
        @unionInit(TomlValue, "Integer", 69420),
        @unionInit(TomlValue, "Integer", -69420),
        @unionInit(TomlValue, "Integer", 69420),
        @unionInit(TomlValue, "Integer", 0xcafebabe),
        @unionInit(TomlValue, "Integer", 0o377),
        @unionInit(TomlValue, "Integer", 0b10111011),
        @unionInit(TomlValue, "Floats", TomlFloat{ .whole = 3, .part = 14159 }),
        @unionInit(TomlValue, "Floats", TomlFloat{ .whole = 6, .part = 22, .exp = -23 }),
        @unionInit(TomlValue, "Concept", TomlConcept.INFINITY),
        @unionInit(TomlValue, "Concept", TomlConcept.NOT_A_NUMBER),
        @unionInit(TomlValue, "Boolean", true),
        @unionInit(TomlValue, "Boolean", false),
        @unionInit(TomlValue, "OffsetDateTime", TomlOffsetDateTime{ .date = .{ .day = 10, .month = 4, .year = 2024 }, .time = .{ .hour = 12, .min = 56, .sec = 49, .micro = 0 }, .offset = .{ .hour = -5, .min = 0 } }),
        @unionInit(TomlValue, "LocalDateTime", TomlLocalDateTime{ .date = .{ .day = 10, .month = 4, .year = 2024 }, .time = .{ .hour = 1, .min = 0, .sec = 12, .micro = 0 } }),
        @unionInit(TomlValue, "Date", TomlDate{ .day = 10, .month = 4, .year = 2024 }),
        @unionInit(TomlValue, "Time", TomlTime{ .hour = 1, .min = 0, .sec = 58, .micro = 0 }),
        @unionInit(TomlValue, "Array", [_]TomlValue{
            @unionInit(TomlValue, "String", "test"),
            @unionInit(TomlValue, "String", "passed"),
        }),
        @unionInit(TomlValue, "Array", [_]TomlValue{
            @unionInit(TomlValue, "String", "p"),
            @unionInit(TomlValue, "Integer", 1),
            @unionInit(TomlValue, "String", "u"),
            @unionInit(TomlValue, "Integer", 2),
            @unionInit(TomlValue, "String", "b"),
            @unionInit(TomlValue, "Integer", 3),
            @unionInit(TomlValue, "String", "l"),
            @unionInit(TomlValue, "Integer", 4),
            @unionInit(TomlValue, "String", "i"),
            @unionInit(TomlValue, "Integer", 5),
            @unionInit(TomlValue, "String", "c"),
            @unionInit(TomlValue, "Integer", 6),
        }),
    };

    for (tests, table_results[0..tests.len], toml_results[0..tests.len]) |input, table, tval| {
        var toml = Toml{
            .alloc = std.testing.allocator,
            .table = undefined,
            .text = input,
        };

        // test all possible parseable value types
        var out = try toml.parseValue();
        try std.testing.expect(out.tag == table.tag);
        try std.testing.expect(out.loc.start == table.loc.start);
        try std.testing.expect(out.loc.end == table.loc.end);

        // test all possible parsable return values
        var val = try toml.genTomlValue(out);
        try std.testing.expect(std.meta.activeTag(val) == std.meta.activeTag(tval));
        switch (std.meta.activeTag(tval)) {
            .String => {},
            .Integer => {},
            .Float => {},
            .Boolean => {},
            .Concept => {},
            .Date => {},
            .Time => {},
            .LocalDateTime => {},
            .OffsetDateTime => {},
            .Array => {},
        }
    }
}
