//! Pipe implements a termio backend that doesn't own subprocess creation
//! or a PTY. Writes are forwarded to a callback and reads are expected to
//! be fed externally via Termio.processOutput.
const Pipe = @This();

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");

pub const Config = struct {
    userdata: ?*anyopaque = null,

    /// Called when terminal input should be written to the external transport.
    write: ?*const fn (?*anyopaque, []const u8) void = null,

    /// Called when the terminal grid/screen size changes.
    resize: ?*const fn (?*anyopaque, renderer.GridSize, renderer.ScreenSize) void = null,
};

config: Config,

pub fn init(cfg: Config) Pipe {
    return .{ .config = cfg };
}

pub fn deinit(self: *Pipe) void {
    _ = self;
}

pub fn initTerminal(self: *Pipe, term: *terminal.Terminal) void {
    // Match Exec behavior and propagate initial terminal dimensions.
    self.resize(.{
        .columns = term.cols,
        .rows = term.rows,
    }, .{
        .width = term.width_px,
        .height = term.height_px,
    }) catch unreachable;
}

pub fn threadEnter(
    self: *Pipe,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = self;
    _ = alloc;
    _ = io;
    td.backend = .{ .pipe = .{} };
}

pub fn threadExit(self: *Pipe, td: *termio.Termio.ThreadData) void {
    _ = self;
    assert(td.backend == .pipe);
}

pub fn focusGained(
    self: *Pipe,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
}

pub fn resize(
    self: *Pipe,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    const cb = self.config.resize orelse return;
    cb(self.config.userdata, grid_size, screen_size);
}

pub fn queueWrite(
    self: *Pipe,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = alloc;
    _ = td;

    const cb = self.config.write orelse return;

    if (!linefeed or std.mem.indexOfScalar(u8, data, '\r') == null) {
        cb(self.config.userdata, data);
        return;
    }

    // Match Exec behavior for linefeed mode by translating CR -> CRLF.
    var buf: [512]u8 = undefined;
    var i: usize = 0;
    for (data) |ch| {
        if (ch != '\r') {
            if (i == buf.len) {
                cb(self.config.userdata, buf[0..i]);
                i = 0;
            }

            buf[i] = ch;
            i += 1;
            continue;
        }

        if (i + 2 > buf.len) {
            cb(self.config.userdata, buf[0..i]);
            i = 0;
        }

        buf[i] = '\r';
        buf[i + 1] = '\n';
        i += 2;
    }

    if (i > 0) cb(self.config.userdata, buf[0..i]);
}

pub fn childExitedAbnormally(
    self: *Pipe,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};

test "queueWrite preserves bytes without linefeed" {
    const Ctx = struct {
        buf: [64]u8 = undefined,
        len: usize = 0,
    };

    const callbacks = struct {
        fn write(userdata: ?*anyopaque, data: []const u8) void {
            const ctx: *Ctx = @ptrCast(@alignCast(userdata orelse return));
            assert(ctx.len + data.len <= ctx.buf.len);
            @memcpy(ctx.buf[ctx.len..][0..data.len], data);
            ctx.len += data.len;
        }
    };

    var ctx: Ctx = .{};
    var pipe = init(.{
        .userdata = @ptrCast(&ctx),
        .write = callbacks.write,
    });
    var td: termio.Termio.ThreadData = undefined;

    try pipe.queueWrite(
        std.testing.allocator,
        &td,
        "hello\rworld",
        false,
    );
    try std.testing.expectEqualStrings("hello\rworld", ctx.buf[0..ctx.len]);
}

test "queueWrite translates CR to CRLF in linefeed mode" {
    const Ctx = struct {
        buf: [64]u8 = undefined,
        len: usize = 0,
    };

    const callbacks = struct {
        fn write(userdata: ?*anyopaque, data: []const u8) void {
            const ctx: *Ctx = @ptrCast(@alignCast(userdata orelse return));
            assert(ctx.len + data.len <= ctx.buf.len);
            @memcpy(ctx.buf[ctx.len..][0..data.len], data);
            ctx.len += data.len;
        }
    };

    var ctx: Ctx = .{};
    var pipe = init(.{
        .userdata = @ptrCast(&ctx),
        .write = callbacks.write,
    });
    var td: termio.Termio.ThreadData = undefined;

    try pipe.queueWrite(
        std.testing.allocator,
        &td,
        "a\rb\rc",
        true,
    );
    try std.testing.expectEqualStrings("a\r\nb\r\nc", ctx.buf[0..ctx.len]);
}
