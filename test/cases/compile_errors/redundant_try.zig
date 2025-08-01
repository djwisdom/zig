const S = struct { x: u32 = 0 };
const T = struct { []const u8 };

fn test0() !void {
    const x: u8 = try 1;
    _ = x;
}

fn test1() !void {
    const x: S = try .{};
    _ = x;
}

fn test2() !void {
    const x: S = try S{ .x = 123 };
    _ = x;
}

fn test3() !void {
    const x: S = try try S{ .x = 123 };
    _ = x;
}

fn test4() !void {
    const x: T = try .{"hello"};
    _ = x;
}

fn test5() !void {
    const x: error{Foo}!u32 = 123;
    _ = try try x;
}

comptime {
    _ = &test0;
    _ = &test1;
    _ = &test2;
    _ = &test3;
    _ = &test4;
    _ = &test5;
}

// error
//
// :5:23: error: expected error union type, found 'comptime_int'
// :5:23: note: consider omitting 'try'
// :10:23: error: expected error union type, found '@TypeOf(.{})'
// :10:23: note: consider omitting 'try'
// :15:23: error: expected error union type, found 'tmp.S'
// :1:11: note: struct declared here
// :15:23: note: consider omitting 'try'
// :20:27: error: expected error union type, found 'tmp.S'
// :1:11: note: struct declared here
// :20:27: note: consider omitting 'try'
// :25:23: error: expected error union type, found 'struct { comptime *const [5:0]u8 = "hello" }'
// :25:23: note: consider omitting 'try'
// :31:13: error: expected error union type, found 'u32'
// :31:13: note: consider omitting 'try'
