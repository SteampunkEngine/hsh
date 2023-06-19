const std = @import("std");
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const os = std.os;
const mem = std.mem;
const fs = std.fs;
const File = fs.File;
const io = std.io;
const Reader = fs.File.Reader;
const Writer = fs.File.Writer;
const Cord = @import("draw.zig").Cord;
const custom_syscalls = @import("syscalls.zig");
const pid_t = std.os.linux.pid_t;
const fd_t = std.os.fd_t;
const log = @import("log");

pub const OpCodes = enum {
    EraseInLine,
    CurPosGet,
    CurPosSet,
    CurMvUp,
    CurMvDn,
    CurMvLe,
    CurMvRi,
    CurHorzAbs,
};

pub var current_tty: ?TTY = undefined;

pub const TTY = struct {
    alloc: Allocator,
    tty: i32,
    in: Reader,
    out: Writer,
    attrs: ArrayList(os.termios),

    /// Calling init multiple times is UB
    pub fn init(a: Allocator) !TTY {
        // TODO figure out how to handle multiple calls to current_tty?
        const tty = os.open("/dev/tty", os.linux.O.RDWR, 0) catch unreachable;

        var self = TTY{
            .alloc = a,
            .tty = tty,
            .in = std.io.getStdIn().reader(),
            .out = std.io.getStdOut().writer(),
            .attrs = ArrayList(os.termios).init(a),
        };

        const current = self.getAttr();
        try self.pushTTY(current);
        try self.pushRaw();
        current_tty = self;

        // Cursor focus

        return self;
    }

    fn getAttr(self: *TTY) os.termios {
        return os.tcgetattr(self.tty) catch unreachable;
    }

    fn makeRaw(orig: os.termios) os.termios {
        var next = orig;
        next.iflag &= ~(os.linux.IXON |
            os.linux.BRKINT | os.linux.INPCK | os.linux.ISTRIP);
        next.iflag |= os.linux.ICRNL;
        //next.lflag &= ~(os.linux.ECHO | os.linux.ICANON | os.linux.ISIG | os.linux.IEXTEN);
        next.lflag &= ~(os.linux.ECHO | os.linux.ECHONL | os.linux.ICANON | os.linux.IEXTEN);
        next.cc[os.system.V.TIME] = 1; // 0.1 sec resolution
        next.cc[os.system.V.MIN] = 0;
        return next;
    }

    pub fn pushOrig(self: *TTY) !void {
        try self.pushTTY(self.attrs.items[0]);
        _ = try self.out.write("\x1B[?1004l");
    }

    pub fn pushRaw(self: *TTY) !void {
        try self.pushTTY(makeRaw(self.attrs.items[0]));
        _ = try self.out.write("\x1B[?1004h");
    }

    pub fn pushTTY(self: *TTY, tios: os.termios) !void {
        try self.attrs.append(self.getAttr());
        try os.tcsetattr(self.tty, .DRAIN, tios);
    }

    pub fn popTTY(self: *TTY) !os.termios {
        // Not using assert, because this is *always* an dangerously invalid state!
        if (self.attrs.items.len <= 1) @panic("popTTY");
        const old = try os.tcgetattr(self.tty);
        const tail = self.attrs.pop();
        os.tcsetattr(self.tty, .DRAIN, tail) catch |err| {
            log.err("TTY ERROR encountered, {} when popping.\n", .{err});
            return err;
        };
        return old;
    }

    pub fn setOwner(self: *TTY, pgrp: std.os.pid_t) !void {
        _ = try std.os.tcsetpgrp(self.tty, pgrp);
    }

    pub fn pwnTTY(self: *TTY) void {
        const pid = std.os.linux.getpid();
        const ssid = custom_syscalls.getsid(0);
        log.debug("pwning {} and {} \n", .{ pid, ssid });
        if (ssid != pid) {
            _ = custom_syscalls.setpgid(pid, pid);
        }
        log.debug("pwning tc \n", .{});
        //_ = custom_syscalls.tcsetpgrp(self.tty, &pid);
        //var res = custom_syscalls.tcsetpgrp(self.tty, &pid);
        const res = std.os.tcsetpgrp(self.tty, pid) catch |err| {
            log.err("Unable to tcsetpgrp to {}, error was: {}\n", .{ pid, err });
            log.err("Will attempt to tcgetpgrp\n", .{});
            const get = std.os.tcgetpgrp(self.tty) catch |err2| {
                log.err("tcgetpgrp err {}\n", .{err2});
                return;
            };
            log.err("tcgetpgrp reports {}\n", .{get});
            unreachable;
        };
        log.debug("tc pwnd {}\n", .{res});
        //_ = custom_syscalls.tcgetpgrp(self.tty, &pgrp);
        const pgrp = std.os.tcgetpgrp(self.tty) catch unreachable;
        log.debug("get new pgrp {}\n", .{pgrp});
    }

    pub fn waitForFg(self: *TTY) void {
        var pgid = custom_syscalls.getpgid(0);
        var fg = std.os.tcgetpgrp(self.tty) catch |err| {
            log.err("died waiting for fg {}\n", .{err});
            @panic("panic carefully!");
        };
        while (pgid != fg) {
            std.os.kill(-pgid, std.os.SIG.TTIN) catch {
                @panic("unable to send TTIN");
            };
            pgid = custom_syscalls.getpgid(0);
            std.os.tcsetpgrp(self.tty, pgid) catch {
                @panic("died in loop");
            };
            fg = std.os.tcgetpgrp(self.tty) catch {
                @panic("died in loop");
            };
        }
    }

    pub fn print(tty: TTY, comptime fmt: []const u8, args: anytype) !void {
        try tty.out.print(fmt, args);
    }

    pub fn opcode(tty: TTY, comptime code: OpCodes, args: anytype) !void {
        // TODO fetch info back out :/
        _ = args;
        switch (code) {
            OpCodes.EraseInLine => try tty.writeAll("\x1B[K"),
            OpCodes.CurPosGet => try tty.print("\x1B[6n"),
            OpCodes.CurMvUp => try tty.writeAll("\x1B[A"),
            OpCodes.CurMvDn => try tty.writeAll("\x1B[B"),
            OpCodes.CurMvLe => try tty.writeAll("\x1B[D"),
            OpCodes.CurMvRi => try tty.writeAll("\x1B[C"),
            OpCodes.CurHorzAbs => try tty.writeAll("\x1B[G"),
            else => unreachable,
        }
    }

    pub fn cpos(tty: i32) !Cord {
        std.debug.print("\x1B[6n", .{});
        var buffer: [10]u8 = undefined;
        const len = try os.read(tty, &buffer);
        var splits = mem.split(u8, buffer[2..], ";");
        var x: usize = std.fmt.parseInt(usize, splits.next().?, 10) catch 0;
        var y: usize = 0;
        if (splits.next()) |thing| {
            y = std.fmt.parseInt(usize, thing[0 .. len - 3], 10) catch 0;
        }
        return .{
            .x = x,
            .y = y,
        };
    }

    pub fn geom(self: *TTY) !Cord {
        var size: os.linux.winsize = mem.zeroes(os.linux.winsize);
        const err = os.system.ioctl(self.tty, os.linux.T.IOCGWINSZ, @ptrToInt(&size));
        if (os.errno(err) != .SUCCESS) {
            return os.unexpectedErrno(@intToEnum(os.system.E, err));
        }
        return .{
            .x = size.ws_col,
            .y = size.ws_row,
        };
    }

    pub fn raze(self: *TTY) void {
        while (self.attrs.items.len > 1) {
            _ = self.popTTY() catch continue;
        }
        const last = self.attrs.pop();
        os.tcsetattr(self.tty, .NOW, last) catch |err| {
            std.debug.print(
                "\r\n\nTTY ERROR RAZE encountered, {} when attempting to raze.\r\n\n",
                .{err},
            );
        };
    }
};

const expect = std.testing.expect;
test "split" {
    var s = "\x1B[86;1R";
    var splits = std.mem.split(u8, s[2..], ";");
    var x: usize = std.fmt.parseInt(usize, splits.next().?, 10) catch 0;
    var y: usize = 0;
    if (splits.next()) |thing| {
        y = std.fmt.parseInt(usize, thing[0 .. thing.len - 1], 10) catch unreachable;
    }
    try expect(x == 86);
    try expect(y == 1);
}
