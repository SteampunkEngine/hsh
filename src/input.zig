const std = @import("std");
const log = @import("log");
const HSH = @import("hsh.zig").HSH;
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;
const complete = @import("completion.zig");
const Keys = @import("keys.zig");
const printAfter = Draw.printAfter;
const Draw = @import("draw.zig");
const Token = @import("token.zig");
const TokenErr = Token.Error;
const parser = @import("parse.zig");
const Parser = parser.Parser;

const Input = @This();

pub const Event = enum(u8) {
    None,
    HSHIntern,
    Update,
    EnvState,
    Prompt,
    Advice,
    Redraw,
    Exec,
    Signaled,
    // ...
    ExitHSH,
    ExpectedError,
};

const Mode = enum {
    TYPING,
    COMPLETING,
    COMPENDING, // Just completed a token, may or may not need more
    EXEDIT,
};

const InputState = struct {
    mode: Mode = .TYPING,
    edinput: bool = false,
    next: ?Event = null,
};

var state = InputState{};

fn read(fd: std.os.fd_t, buf: []u8) !usize {
    const rc = std.os.linux.read(fd, buf.ptr, buf.len);
    switch (std.os.linux.getErrno(rc)) {
        .SUCCESS => return @intCast(rc),
        .INTR => return error.Interupted,
        .AGAIN => return error.WouldBlock,
        .BADF => return error.NotOpenForReading, // Can be a race condition.
        .IO => return error.InputOutput,
        .ISDIR => return error.IsDir,
        .NOBUFS => return error.SystemResources,
        .NOMEM => return error.SystemResources,
        .CONNRESET => return error.ConnectionResetByPeer,
        .TIMEDOUT => return error.ConnectionTimedOut,
        else => |err| {
            std.debug.print("unexpected read err {}\n", .{err});
            @panic("unknown read error\n");
        },
    }
}

fn doComplete(hsh: *HSH, tkn: *Tokenizer, comp: *complete.CompSet) !Mode {
    if (comp.known()) |only| {
        // original and single, complete now
        try tkn.maybeReplace(only);
        try tkn.maybeCommit(only);

        if (only.kind != null and only.kind.? == .file_system and only.kind.?.file_system == .dir) {
            try complete.complete(comp, hsh, tkn);
            return .COMPENDING;
        } else {
            comp.raze();
            try Draw.drawAfter(&hsh.draw, Draw.LexTree{
                .lex = Draw.Lexeme{ .char = "[ found ]", .style = .{ .attr = .bold, .fg = .green } },
            });
            return .TYPING;
        }
    }

    if (comp.countFiltered() == 0) {
        try Draw.drawAfter(&hsh.draw, Draw.LexTree{
            .lex = Draw.Lexeme{ .char = "[ nothing found ]", .style = .{ .attr = .bold, .fg = .red } },
        });
        if (comp.count() == 0) {
            comp.raze();
        }
        return .TYPING;
    }

    if (comp.countFiltered() > 1) {
        var target = comp.next();
        try tkn.maybeReplace(target);
        comp.drawAll(&hsh.draw, hsh.draw.term_size) catch |err| {
            if (err == Draw.Layout.Error.ItemCount) return .COMPLETING else return err;
        };
    }

    return .COMPLETING;
}

fn completing(hsh: *HSH, tkn: *Tokenizer, ks: Keys.KeyMod, comp: *complete.CompSet) !Event {
    if (state.mode == .TYPING) {
        try complete.complete(comp, hsh, tkn);
        state.mode = .COMPLETING;
        return completing(hsh, tkn, ks, comp);
    }

    switch (ks.evt) {
        .ascii => |c| {
            switch (c) {
                0x09 => {
                    // tab \t
                    if (ks.mods.shift) {
                        comp.revr();
                        comp.revr();
                    }
                    state.mode = try doComplete(hsh, tkn, comp);
                    return .Redraw;
                },
                0x0A => {
                    // newline \n
                    if (state.mode == .COMPENDING) {
                        state.mode = .TYPING;
                        return .Exec;
                    }
                    if (comp.count() > 0) {
                        try tkn.maybeReplace(comp.current());
                        try tkn.maybeCommit(comp.current());
                        state.mode = .COMPENDING;
                    }
                    return .Redraw;
                },
                0x7f => { // backspace
                    if (state.mode == .COMPENDING) {
                        state.mode = .TYPING;
                        return .Redraw;
                    }
                    comp.searchPop() catch {
                        state.mode = .TYPING;
                        comp.raze();
                        tkn.raw_maybe = null;
                        return .Redraw;
                    };
                    state.mode = try doComplete(hsh, tkn, comp);
                    try tkn.maybeDrop();
                    try tkn.maybeAdd(comp.search.items);
                    return .Redraw;
                },
                ' ' => {
                    state.mode = .TYPING;
                    return .Redraw;
                },
                '/' => |chr| {
                    // IFF this is an existing directory,
                    // completion should continue
                    if (comp.count() > 1) {
                        if (comp.current().kind) |kind| {
                            if (kind == .file_system and kind.file_system == .dir) {
                                try tkn.consumec(chr);
                            }
                        }
                    }
                    state.mode = .TYPING;
                    return .Redraw;
                },
                else => {
                    if (state.mode == .COMPENDING) state.mode = .COMPLETING;
                    try comp.searchChar(c);
                    state.mode = try doComplete(hsh, tkn, comp);
                    if (state.mode == .COMPLETING) {
                        try tkn.maybeDrop();
                        try tkn.maybeAdd(comp.search.items);
                    }
                    return .Redraw;
                },
            }
        },
        .key => |k| {
            switch (k) {
                .Esc => {
                    state.mode = .TYPING;
                    try tkn.maybeDrop();
                    if (comp.original) |o| {
                        try tkn.maybeAdd(o.str);
                        try tkn.maybeCommit(null);
                    }
                    comp.raze();
                    return .Redraw;
                },
                .Up, .Down, .Left, .Right => {
                    // TODO implement arrows
                    return .Redraw;
                },
                .Home, .End => |h_e| {
                    state.mode = .TYPING;
                    try tkn.maybeCommit(null);
                    tkn.cPos(if (h_e == .Home) .home else .end);
                    return .Redraw;
                },
                else => {
                    log.err("unexpected key  [{}]\n", .{ks});
                    state.mode = .TYPING;
                    try tkn.maybeCommit(null);
                },
            }
        },
    }
    log.err("end of completing... oops\n  [{}]\n", .{ks});
    unreachable;
}

fn ctrlCode(hsh: *HSH, tkn: *Tokenizer, b: u8, comp: *complete.CompSet) !Event {
    switch (b) {
        0x03 => {
            try hsh.tty.out.print("^C\n\n", .{});
            tkn.reset();
            return .Prompt;
        },
        0x04 => {
            if (tkn.raw.items.len == 0) {
                try hsh.tty.out.print("^D\r\nExit caught... Good bye :)\n", .{});
                return .ExitHSH;
            }

            try hsh.tty.out.print("^D\r\n", .{});
            return .Redraw;
        },
        0x05 => {
            // TODO Currently hack af, this could use some more love!
            if (state.mode == .EXEDIT) {
                state.edinput = true;
                tkn.lineEditor();
                return .Exec;
            } else try hsh.tty.out.print("^E\r\n", .{}); // ENQ
        },
        0x07 => try hsh.tty.out.print("^bel\r\n", .{}),
        // probably ctrl + bs
        0x08 => {
            _ = try tkn.dropWord();
            return .Redraw;
        },
        0x09 => |c| { // \t
            return completing(hsh, tkn, Keys.Event.ascii(c).keysm, comp) catch unreachable;
        },
        0x0A, 0x0D => |nl| {
            //hsh.draw.cursor = 0;
            if (tkn.raw.items.len == 0) {
                try hsh.tty.out.print("\n", .{});
                return .Prompt;
            }

            var nl_exec = tkn.consumec(nl);
            if (nl_exec == error.Exec) {
                if (tkn.validate()) {} else |e| {
                    log.err("validate", .{});
                    switch (e) {
                        TokenErr.OpenGroup, TokenErr.OpenLogic => {},
                        TokenErr.TokenizeFailed => log.err("tokenize Error {}\n", .{e}),
                        else => return .ExpectedError,
                    }
                    return .Prompt;
                }
                tkn.bsc();
                return .Exec;
            }
            //var run = Parser.parse(tkn.alloc, tkns) catch return .Redraw;
            //defer run.raze();
            //if (run.tokens.len > 0) return .Exec;
            return .Redraw;
        },
        0x0C => try hsh.tty.out.print("^L (reset term)\x1B[J\n", .{}),
        0x0E => try hsh.tty.out.print("shift in\r\n", .{}),
        0x0F => try hsh.tty.out.print("^shift out\r\n", .{}),
        0x12 => try hsh.tty.out.print("^R\r\n", .{}), // DC2
        0x13 => try hsh.tty.out.print("^S\r\n", .{}), // DC3
        0x14 => try hsh.tty.out.print("^T\r\n", .{}), // DC4
        // this is supposed to be ^v but it's ^x on mine an another system
        0x16 => try hsh.tty.out.print("^X\r\n", .{}), // SYN
        0x18 => {
            //try hsh.tty.out.print("^X (or something else?)\r\n", .{}); // CAN
            state.mode = .EXEDIT;
        },
        0x1A => try hsh.tty.out.print("^Z\r\n", .{}),
        0x17 => { // ^w
            _ = try tkn.dropWord();
            return .Redraw;
        },
        else => |x| {
            log.err("Unknown ctrl code 0x{x}", .{x});
            unreachable;
        },
    }
    return .None;
}

fn history(h: *HSH, tkn: *Tokenizer, km: Keys.KeyMod) !Event {
    switch (km.evt) {
        .ascii => unreachable,
        .key => |k| {
            switch (k) {
                else => unreachable,
                .Up => {
                    var hist = &(h.hist orelse return .None);
                    if (hist.cnt == 0) {
                        if (tkn.raw.items.len > 0) {
                            tkn.saveLine();
                        } else if (tkn.prev_exec) |pe| {
                            tkn.raw = pe;
                            tkn.prev_exec = null;
                            tkn.c_idx = tkn.raw.items.len;
                            return .Redraw;
                        }
                    }
                    tkn.resetRaw();
                    hist.cnt += 1;
                    if (tkn.hist_z) |hz| {
                        _ = hist.readAtFiltered(&tkn.raw, hz.items);
                    } else {
                        _ = hist.readAt(&tkn.raw);
                    }
                    tkn.c_idx = tkn.raw.items.len;
                },
                .Down => {
                    var hist = &(h.hist orelse return .None);
                    if (hist.cnt > 1) {
                        hist.cnt -= 1;
                        tkn.resetRaw();
                        if (tkn.hist_z) |hz| {
                            _ = hist.readAtFiltered(&tkn.raw, hz.items);
                        } else {
                            _ = hist.readAt(&tkn.raw);
                        }
                        tkn.c_idx = tkn.raw.items.len;
                    } else {
                        hist.cnt -|= 1;
                        tkn.restoreLine();
                    }
                },
            }
        },
    }
    return .Redraw;
}

fn event(hsh: *HSH, tkn: *Tokenizer, km: Keys.KeyMod) !Event {
    tkn.err_idx = 0;
    switch (km.evt) {
        .ascii => |a| {
            switch (a) {
                '.' => if (km.mods.alt) log.err("<A-.> not yet implemented\n", .{}),
                else => {},
            }
        },
        .key => |k| {
            switch (k) {
                .Up, .Down => return history(hsh, tkn, km),
                .Left => if (km.mods.ctrl) tkn.cPos(.back) else tkn.cPos(.dec),
                .Right => if (km.mods.ctrl) tkn.cPos(.word) else tkn.cPos(.inc),
                .Home => tkn.cPos(.home),
                .End => tkn.cPos(.end),
                .Delete => tkn.delc(),
                else => {}, // unable to use range on Key :<
            }
            // TODO find a better scope for this call
            hsh.draw.cursor = tkn.cadj();
        },
    }
    return .Redraw;
}

/// Sigh...
fn unicode(tkn: *Tokenizer, buf: u8) !Event {
    try tkn.consumec(buf);
    return .Redraw;
}

fn ascii(hsh: *HSH, tkn: *Tokenizer, buf: u8, comp: *complete.CompSet) !Event {
    switch (buf) {
        0x00...0x1F => return ctrlCode(hsh, tkn, buf, comp),
        ' '...'~' => |b| { // Normal printable ascii
            try tkn.consumec(b);
            try hsh.tty.out.print("{c}", .{b});
            return if (tkn.cadj() == 0) .None else .Redraw;
        },
        0x7F => { // backspace
            tkn.pop() catch |err| {
                if (err == tokenizer.Error.Empty) return .None;
                return err;
            };
            return .Prompt;
        },
        0x80...0xFF => {
            return unicode(tkn, buf);
        },
    }
    return .None;
}

// TODO pls dry
pub fn nonInteractive(hsh: *HSH, comp: *complete.CompSet) !Event {
    // I no longer like this way of tokenization. I'd like to generate
    // Tokens as an n=2 state machine at time of keypress. It might actually
    // be required to unbreak a bug in history.
    const tkn = &hsh.tkn;

    var buffer: [1]u8 = undefined;

    if (hsh.spin()) {
        state.mode = .TYPING;
        return .Signaled;
    }
    var nbyte: usize = try read(hsh.input, &buffer);
    if (nbyte == 0) return .ExitHSH;

    // No... I don't like this, but I've spent too long staring at it
    // TODO optimize later
    const evt = Keys.translate(buffer[0], hsh.input) catch unreachable;

    //const prevm = mode;
    var result: Event = .None;
    switch (state.mode) {
        .COMPLETING, .COMPENDING => {
            const e = if (evt == .ascii) Keys.Event.ascii(evt.ascii) else evt;
            if (e != .keysm) {
                state.mode = .TYPING;
                return .Redraw;
            }
            result = try completing(hsh, tkn, e.keysm, comp);
        },
        .TYPING => {
            result = switch (evt) {
                .ascii => |a| try ascii(hsh, tkn, a, comp),
                .keysm => |e| try event(hsh, tkn, e),
                .mouse => |_| return .Redraw,
            };
        },
        .EXEDIT => unreachable,
    }
    //defer next = if (prevm == mode) null else .Redraw;
    return result;
}

pub fn do(hsh: *HSH, comp: *complete.CompSet) !Event {
    // I no longer like this way of tokenization. I'd like to generate
    // Tokens as an n=2 state machine at time of keypress. It might actually
    // be required to unbreak a bug in history.
    const tkn = &hsh.tkn;

    var buffer: [1]u8 = undefined;

    if (state.edinput) {
        // TODO if $? != 0, don't read file.
        state.mode = .TYPING;
        state.edinput = false;
        tkn.lineEditorRead();
        return .Redraw;
        //log.err("edinput\n", .{});
    }
    var nbyte: usize = 0;
    while (nbyte == 0) {
        if (hsh.spin()) {
            state.mode = .TYPING;
            return .Signaled;
        }
        nbyte = try read(hsh.input, &buffer);
    }

    // No... I don't like this, but I've spent too long staring at it
    // TODO optimize later
    const evt = Keys.translate(buffer[0], hsh.input) catch unreachable;

    //const prevm = mode;
    var result: Event = .None;
    switch (state.mode) {
        .COMPLETING, .COMPENDING => {
            const e = if (evt == .ascii) Keys.Event.ascii(evt.ascii) else evt;
            if (e != .keysm) {
                state.mode = .TYPING;
                return .Redraw;
            }
            result = try completing(hsh, tkn, e.keysm, comp);
        },
        .TYPING => {
            result = switch (evt) {
                .ascii => |a| try ascii(hsh, tkn, a, comp),
                .keysm => |e| try event(hsh, tkn, e),
                .mouse => |_| return .Redraw,
            };
        },
        .EXEDIT => {
            result = try ascii(hsh, tkn, evt.ascii, comp);
        },
    }
    //defer next = if (prevm == mode) null else .Redraw;
    return result;
}
