const std = @import("std");
const Writer = std.fs.File.Writer;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Draw = @import("draw.zig");
const HSH = @import("hsh.zig").HSH;
const Lexeme = Draw.Lexeme;
const Drawable = Draw.Drawable;
const draw = Draw.draw;

fn user_text() void {}

var si: usize = 0;

const Spinners = enum {
    corners,
    dots2t3,

    const dots = [_][]const u8{ "⡄", "⡆", "⠆", "⠇", "⠃", "⠋", "⠉", "⠙", "⠘", "⠸", "⠰", "⢰", "⢠", "⣠", "⣀", "⣄" };
    const corners = [_][]const u8{ "◢", "◣", "◤", "◥" };
    pub fn spin(s: Spinners, pos: usize) []const u8 {
        const art = switch (s) {
            .corners => &[_][]const u8{ "◢", "◣", "◤", "◥" },
            .dots2t3 => &[_][]const u8{ "⡄", "⡆", "⠆", "⠇", "⠃", "⠋", "⠉", "⠙", "⠘", "⠸", "⠰", "⢰", "⢠", "⣠", "⣀", "⣄" },
        };
        return art[pos % art.len];
    }
};

fn spinner(s: Spinners) Lexeme {
    // TODO if >1 spinners are in use, this will double increment
    si += 1;
    return .{ .char = s.spin(si) };
}

pub fn prompt(hsh: *HSH, tkn: *Tokenizer) !void {
    var b_raw: [8]u8 = undefined;
    var b_tkns: [8]u8 = undefined;
    var c_tkn: [8]u8 = undefined;
    try draw(&hsh.draw, .{
        .sibling = &[_]Lexeme{
            .{
                .char = hsh.env.get("USER") orelse "[username unknown]",
                .attr = .Bold,
                .fg = .Blue,
            },
            .{ .char = "@" },
            .{ .char = "host" },
            .{ .char = try std.fmt.bufPrint(
                &b_raw,
                "({}) ",
                .{tkn.raw.items.len},
            ) },
            .{ .char = try std.fmt.bufPrint(
                &b_tkns,
                "({}) ",
                .{tkn.tokens.items.len},
            ) },
            .{ .char = try std.fmt.bufPrint(
                &c_tkn,
                "[{}] ",
                .{tkn.c_tkn},
            ) },
            .{ .char = hsh.fs.cwd_short },
            .{ .char = " $ " },
            .{ .char = if (tkn.err_idx > 0) tkn.raw.items[0..tkn.err_idx] else tkn.raw.items },
            .{
                .char = if (tkn.err_idx > 0) tkn.raw.items[tkn.err_idx..] else "",
                .bg = .Red,
            },
        },
    });
}
