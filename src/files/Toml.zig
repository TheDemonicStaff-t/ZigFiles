const std = @import("std");
// imported structures
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
// imported functions
const fixedBufferStream = std.io.fixedBufferStream;
const eql = std.mem.eql;

const Toml = @This();

keys: []*[]const u8 = undefined,
values: []TomlValue = undefined,
file: []const u8,
alloc: Allocator,

pub fn init(alloc: Allocator, file: []const u8) !Toml {}

pub const Lexer = struct {
    toks: []Tok = undefined,
    index: usize = 0,
    file: []const u8,
    idx: usize = 0,
    alloc: Allocator,

    pub fn init(alloc: Allocator, file: []const u8) !Lexer {
        var l = Lexer{ .alloc = alloc, .file = file };
        var toks = ArrayList(Tok).init(alloc);
        defer toks.deinit();

        while (l.idx < l.file.len) : (l.idx += 1) {
            switch (l.file[l.idx]) {
                ' ', '\t', '\n' => {},
                '#' => {
                    while (l.file[l.idx] != '\n') l.idx += 1;
                    l.idx += 1;
                },
                '.' => try toks.append(Tok.init_simple(.period)),
                '=' => try toks.append(Tok.init_simple(.equal)),
                ',' => try toks.append(Tok.init_simple(.comma)),
                '[' => try toks.append(Tok.init_simple(.left_sqr_brace)),
                ']' => try toks.append(Tok.init_simple(.right_sqr_brace)),
                '{' => try toks.append(Tok.init_simple(.left_curl_brace)),
                '}' => try toks.append(Tok.init_simple(.right_curl_brace)),
                '-', '+', 'i', 'n' => try toks.append(try Tok.init_num(l)),
                '0'...'9' => {},
                else => return error.UnknownTokenError,
            }
        }

        l.toks = try toks.toOwnedSlice();

        return l;
    }

    pub fn next(self: *Lexer) !Tok {}
    pub fn dec(self: *Lexer) !void {}

    pub const Tok = struct {
        type: TokType,
        data: ?TokValue = undefined,

        fn init(t: TokType, data: anytype) !Tok {
            var tok = Tok{ .type = t };
            var has_data = false;
            inline for (@typeInfo(TokValue).Union.fields) |field| {
                if (field.type == @TypeOf(data)) {
                    tok.data = @unionInit(TokValue, field.name, data);
                    has_data = true;
                }
            }
            if (!has_data) {
                tok.data = null;
            }

            return tok;
        }

        fn init_simple(t: TokType) Tok {
            return .{ .type = t, .data = null };
        }

        pub fn init_num(self: *Lexer) !Tok {
            var is_neg = (self.file[self.idx] == '-');
            if (is_neg or self.file[self.idx] == '+') self.idx += 1;
            // infinity and not a number
            if (self.file[self.idx] == 'i' or self.file[self.idx] == 'n') {
                if (eql(u8, self.file[self.idx .. self.idx + 3], "inf")) {
                    return try Tok.init(.num_concept, @TypeOf(@field(TokValue, "num_concept")).infinite);
                } else if (eql(u8, self.file[self.idx .. self.idx + 3], "nan")) {
                    return try Tok.init(.num_concept, @TypeOf(@field(TokValue, "num_concept")).not_a_number);
                }
            }

            // parse int
            var num: isize = 0;
            if (self.file[self.idx] == '0') {
                self.idx += 1;
            } else while (self.file[self.idx] >= '0' and self.file[self.idx] <= '9') : (self.idx += 1) {
                num *= 10;
                num += @as(i64, @intCast(self.file[self.idx] - '0'));
            }

            if (is_neg) num *= -1;

            // parse float/exponent
            if (self.file[self.idx] == '.' or self.file[self.idx] == 'e' or self.file[self.idx] == 'E') {
                var fnum = TomlFloat{ .whole_val = num };
                // float
                if (self.file[self.idx] == '.') {
                    var unum: u64 = 0;
                    while (self.file[self.idx] >= '0' and self.file[self.idx] <= '9') : (self.idx += 1) {
                        unum *= 10;
                        unum += @as(u64, @intCast(self.file[self.idx] - '0'));
                    }
                    fnum.fract_num = unum;
                }
                // exponent
                if (self.file[self.idx] == 'e' or (self.file[self.idx] == 'E')) {
                    num = 0;
                    is_neg = false;
                    self.idx += 1;
                    is_neg = self.file[self.idx] == '-';
                    if (self.file[self.idx] == '+' or is_neg) self.idx += 1;
                    while (self.file[self.idx] >= '0' and self.file[self.idx] <= '9') : (self.idx += 1) {
                        num *= 10;
                        num += @as(i64, @intCast(self.file[self.idx] - '0'));
                    }
                    if (is_neg) num += -1;
                    fnum.expo_val = num;
                }

                return try Tok.init(.float, fnum);
            } else {
                return try Tok.init(.int, num);
            }
        }

        pub fn init_unum(self: *Lexer) !Tok {
            if (self.file[self.idx + 2] == ':') {}
            if (self.file[self.idx + 4] == '-') {
                if (self.file[self.idx + 11] >= '0' and self.file[self.idx + 11] <= '9') {} else return try Tok.init(.date, try TomlDate.init(self));
            }
            // hex, octal, and binary format
            if (self.file[self.idx] == '0') {
                self.idx += 2;
                var num: i64 = 0;
                switch (self.file[self.idx - 1]) {
                    'x' => {
                        // hex
                        while ((self.file[self.idx] >= '0' and self.file[self.idx] == '9') or (self.file[self.idx] >= 'a' and self.file[self.idx] <= 'f') or (self.file[self.idx] >= 'A' and self.file[self.idx] <= 'F')) : (self.idx += 1) {
                            num *= 16;
                            if (self.file[self.idx] >= '0' and self.file[self.idx] == '9') {
                                num += @as(i64, @intCast(self.file[self.idx] - '0'));
                            } else if (self.file[self.idx] >= 'a' and self.file[self.idx] <= 'f') {
                                num += @as(i64, @intCast(self.file[self.idx] - 'a' + 10));
                            } else {
                                num += @as(i64, @intCast(self.file[self.idx] - 'A' + 10));
                            }
                        }
                    },
                    'o' => {
                        // octal
                        while (self.file[self.idx] >= '0' and self.file[self.idx] <= '7') {
                            num *= 8;
                            num += @as(i64, @intCast(self.file[self.idx] - '0'));
                        }
                    },
                    'b' => {
                        // binary
                        while (self.file[self.idx] == '1' or self.file[self.idx] == '0') {
                            num *= 2;
                            num += @as(i64, @intCast(self.file[self.idx] - '0'));
                        }
                    },
                    else => return error.UnknownIntRepresentation,
                }
                return Tok.init(.int, num);
            }
            // int format
            var num: i64 = 0;
            while (self.file[self.idx] >= '0' and self.file[self.idx] <= '9') : (self.idx += 1) {
                num *= 10;
                num += 10;
            }
            return try Tok.init(.int, num);
        }
    };
    pub const TokType = enum { id, string, int, num_concept, float, boolean, time, date, date_time, left_sqr_brace, right_sqr_brace, left_curl_brace, right_curl_brace, period, equal, comma };
    pub const TokValue = union(enum) {
        string: []u8,
        int: i64,
        num_concept: enum { infinite, not_a_number },
        float: TomlFloat,
        boolean: bool,
        date: TomlDate,
        time: TomlTime,
        date_time: TomlDateTime,
    };
};
pub const TomlFloat = struct { whole_val: i64, fract_val: u64 = 0, expo_val: i64 = 0 };
pub const TomlDateTime = struct {
    date: TomlDate,
    time: TomlTime,
    pub fn init(l: *Lexer) !TomlDateTime {}
};
pub const TomlDate = struct {
    year: u16,
    month: u8,
    day: u8,
    pub fn init(l: *Lexer) !TomlDate {
        if (l.file[l.idx + 4] != '-' or l.file[l.idx + 7] != '-') return error.NoDateDetected;
        defer l.idx += 9;
        return .{
            .year = (@as(u16, @intCast(l.file[l.idx] - '0')) * 1000) + (@as(u16, @intCast(l.file[l.idx + 1] - '0')) * 100) + (@as(u16, @intCast(l.file[l.idx + 2] - '0')) * 10) + (@as(u16, @intCast(l.file[l.idx + 3] - '0'))),
            .month = ((l.file[l.idx + 5] - '0') * 10) + (l.file[l.idx + 6] - '0'),
            .day = ((l.file[l.idx + 8] - '0') * 10) + (l.file[l.idx + 9] - '0'),
        };
    }
};
pub const TomlTime = struct {
    hour: u8,
    minute: u8,
    second: u8,
    mili_sec: u8,
    time_offset: ?OffsetTime,

    pub fn init(l: *Lexer) !TomlTime {}

    const OffsetTime = struct { hour: u8, minute: u8 };
};
pub const TomlValue = struct {
    string: []u8,
    int: i64,
    float: TomlFloat,
    boolean: bool,
    date: TomlDate,
    time: TomlTime,
    date_time: TomlDateTime,
    array: []TomlValue,
};
