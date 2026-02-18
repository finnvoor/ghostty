//! Pipe implements a termio backend that uses OS pipes for I/O instead
//! of a pty + subprocess. This is useful for environments where exec()
//! is unavailable (e.g. iOS sandbox) or where the terminal data comes
//! from an external source (e.g. SSH connection managed by the embedder).
//!
//! The embedder writes terminal output data to the write end of the
//! output pipe (which the read thread reads from), and reads terminal
//! input data from the read end of the input pipe (which queueWrite
//! writes to).
const Pipe = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const xev = @import("../global.zig").xev;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const fastmem = @import("../fastmem.zig");
const internal_os = @import("../os/main.zig");
const SegmentedPool = @import("../datastruct/main.zig").SegmentedPool;

const log = std.log.scoped(.io_pipe);

/// File descriptors for the pipe backend. These are the ends that
/// the backend uses internally.
///
/// For the output pipe (data flowing INTO the terminal):
///   - output_read: backend reads from this (read thread)
///   - output_write: embedder writes to this
///
/// For the input pipe (data flowing FROM the terminal):
///   - input_read: embedder reads from this
///   - input_write: backend writes to this (queueWrite)
output_read: posix.fd_t,
output_write: posix.fd_t,
input_read: posix.fd_t,
input_write: posix.fd_t,

/// Tracked size for resize notifications
grid_size: renderer.GridSize = .{},
screen_size: renderer.ScreenSize = .{ .width = 1, .height = 1 },

/// Optional callback for resize notifications since we have no pty
/// to send SIGWINCH through.
resize_cb: ?*const fn (columns: u16, rows: u16, width: u16, height: u16, userdata: ?*anyopaque) callconv(.C) void = null,
resize_cb_userdata: ?*anyopaque = null,

pub fn init(cfg: Config) !Pipe {
    // Create the output pipe: embedder writes, backend reads
    const output_pipe = try internal_os.pipe();
    errdefer {
        posix.close(output_pipe[0]);
        posix.close(output_pipe[1]);
    }

    // Create the input pipe: backend writes, embedder reads
    const input_pipe = try internal_os.pipe();
    errdefer {
        posix.close(input_pipe[0]);
        posix.close(input_pipe[1]);
    }

    return .{
        .output_read = output_pipe[0],
        .output_write = output_pipe[1],
        .input_read = input_pipe[0],
        .input_write = input_pipe[1],
        .resize_cb = cfg.resize_cb,
        .resize_cb_userdata = cfg.resize_cb_userdata,
    };
}

pub fn deinit(self: *Pipe) void {
    posix.close(self.output_read);
    posix.close(self.output_write);
    posix.close(self.input_read);
    posix.close(self.input_write);
    self.* = undefined;
}

pub fn initTerminal(self: *Pipe, term: *terminal.Terminal) void {
    self.resize(.{
        .columns = term.cols,
        .rows = term.rows,
    }, .{
        .width = term.width_px,
        .height = term.height_px,
    }) catch {};
}

pub fn threadEnter(
    self: *Pipe,
    _: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    // Create a quit pipe for signalling the read thread to stop.
    const quit_pipe = try internal_os.pipe();
    errdefer {
        posix.close(quit_pipe[0]);
        posix.close(quit_pipe[1]);
    }

    // Setup our stream for writing to the input pipe
    var stream = xev.Stream.initFd(self.input_write);
    errdefer stream.deinit();

    // Start our read thread
    const read_thread = try std.Thread.spawn(
        .{},
        ReadThread.threadMainPosix,
        .{ self.output_read, io, quit_pipe[0] },
    );
    read_thread.setName("io-reader") catch {};

    td.backend = .{ .pipe = .{
        .write_stream = stream,
        .read_thread = read_thread,
        .read_thread_pipe = quit_pipe[1],
    } };
}

pub fn threadExit(self: *Pipe, td: *termio.Termio.ThreadData) void {
    _ = self;
    std.debug.assert(td.backend == .pipe);
    const pipedata = &td.backend.pipe;

    // Signal the read thread to quit
    _ = posix.write(pipedata.read_thread_pipe, "x") catch |err| switch (err) {
        error.BrokenPipe => {},
        else => log.warn("error writing to read thread quit pipe err={}", .{err}),
    };

    pipedata.read_thread.join();
}

pub fn focusGained(
    self: *Pipe,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
    // No termios state to track for pipes
}

pub fn resize(
    self: *Pipe,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    self.grid_size = grid_size;
    self.screen_size = screen_size;

    // Notify the embedder of the resize via callback
    if (self.resize_cb) |cb| {
        cb(
            std.math.cast(u16, grid_size.columns) orelse std.math.maxInt(u16),
            std.math.cast(u16, grid_size.rows) orelse std.math.maxInt(u16),
            std.math.cast(u16, screen_size.width) orelse std.math.maxInt(u16),
            std.math.cast(u16, screen_size.height) orelse std.math.maxInt(u16),
            self.resize_cb_userdata,
        );
    }
}

pub fn queueWrite(
    self: *Pipe,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = self;
    const pipedata = &td.backend.pipe;

    var i: usize = 0;
    while (i < data.len) {
        const req = try pipedata.write_req_pool.getGrow(alloc);
        const buf = try pipedata.write_buf_pool.getGrow(alloc);
        const slice = slice: {
            const max = @min(data.len, i + buf.len);

            if (!linefeed) {
                fastmem.copy(u8, buf, data[i..max]);
                const len = max - i;
                i = max;
                break :slice buf[0..len];
            }

            // Slow path: replace \r with \r\n
            var buf_i: usize = 0;
            while (i < data.len and buf_i < buf.len - 1) {
                const ch = data[i];
                i += 1;

                if (ch != '\r') {
                    buf[buf_i] = ch;
                    buf_i += 1;
                    continue;
                }

                buf[buf_i] = '\r';
                buf[buf_i + 1] = '\n';
                buf_i += 2;
            }

            break :slice buf[0..buf_i];
        };

        pipedata.write_stream.queueWrite(
            td.loop,
            &pipedata.write_queue,
            req,
            .{ .slice = slice },
            ThreadData,
            pipedata,
            pipeWrite,
        );
    }
}

fn pipeWrite(
    td_: ?*ThreadData,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.Stream,
    _: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    const td = td_.?;
    td.write_req_pool.put();
    td.write_buf_pool.put();

    _ = r catch |err| {
        log.err("pipe write error: {}", .{err});
        return .disarm;
    };

    return .disarm;
}

pub const ThreadData = struct {
    const WRITE_REQ_PREALLOC = std.math.pow(usize, 2, 5);

    write_stream: xev.Stream,

    write_req_pool: SegmentedPool(xev.WriteRequest, WRITE_REQ_PREALLOC) = .{},
    write_buf_pool: SegmentedPool([64]u8, WRITE_REQ_PREALLOC) = .{},
    write_queue: xev.WriteQueue = .{},

    read_thread: std.Thread,
    read_thread_pipe: posix.fd_t,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        posix.close(self.read_thread_pipe);
        self.write_req_pool.deinit(alloc);
        self.write_buf_pool.deinit(alloc);
        self.write_stream.deinit();
    }
};

pub const Config = struct {
    /// Optional callback invoked when the terminal is resized.
    resize_cb: ?*const fn (columns: u16, rows: u16, width: u16, height: u16, userdata: ?*anyopaque) callconv(.C) void = null,
    resize_cb_userdata: ?*anyopaque = null,
};

/// The read thread reads data from the output pipe (data that should be
/// displayed in the terminal) and feeds it to processOutput.
pub const ReadThread = struct {
    fn threadMainPosix(fd: posix.fd_t, io: *termio.Termio, quit: posix.fd_t) void {
        defer posix.close(quit);

        if (builtin.os.tag.isDarwin()) {
            internal_os.macos.pthread_setname_np(&"io-reader".*);
        }

        // Set non-blocking for the tight read loop
        if (posix.fcntl(fd, posix.F.GETFL, 0)) |flags| {
            _ = posix.fcntl(
                fd,
                posix.F.SETFL,
                flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
            ) catch {};
        } else |_| {}

        var pollfds: [2]posix.pollfd = .{
            .{ .fd = fd, .events = posix.POLL.IN, .revents = undefined },
            .{ .fd = quit, .events = posix.POLL.IN, .revents = undefined },
        };

        var buf: [1024]u8 = undefined;
        while (true) {
            while (true) {
                const n = posix.read(fd, &buf) catch |err| {
                    switch (err) {
                        error.NotOpenForReading,
                        error.InputOutput,
                        => {
                            log.info("pipe reader exiting", .{});
                            return;
                        },
                        error.WouldBlock => break,
                        else => {
                            log.err("pipe reader error err={}", .{err});
                            return;
                        },
                    }
                };

                if (n == 0) break;

                @call(.always_inline, termio.Termio.processOutput, .{ io, buf[0..n] });
            }

            _ = posix.poll(&pollfds, -1) catch |err| {
                log.warn("poll failed on pipe read thread err={}", .{err});
                return;
            };

            if (pollfds[1].revents & posix.POLL.IN != 0) {
                log.info("pipe read thread got quit signal", .{});
                return;
            }

            if (pollfds[0].revents & posix.POLL.HUP != 0) {
                log.info("pipe fd closed, read thread exiting", .{});
                return;
            }
        }
    }
};
