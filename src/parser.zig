const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;
const Token = tokenizer.Token;
const TokenList = tokenizer.TokenList;
const Allocator = mem.Allocator;
const bytecode = @import("bytecode.zig");
const Builder = bytecode.Builder;
const RegRef = bytecode.RegRef;

pub const Parser = struct {
    builder: Builder,
    tokenizer: Tokenizer,
    tokens: TokenList,
    token_it: TokenList.Iterator,

    pub fn init(allocator: *Allocator) !Parser {
        return Parser{
            .builder = try Builder.init(allocator),
            .tokenizer = .{
                .it = .{
                    .i = 0,
                    .bytes = "",
                },
            },
            .tokens = TokenList.init(allocator),
            .token_it = undefined, // set in `tokenize`
        };
    }

    pub fn deinit(parser: *Parser) void {
        parser.tokens.deinit();
    }

    pub fn parse(parser: *Parser, input: []const u8) !void {
        try parser.tokenize(input);
        try parser.root();
    }

    fn tokenize(parser: *Parser, input: []const u8) !void {
        parser.tokenizer.it.bytes = input;
        const new_len = if (parser.tokens.len != 0) blk: {
            const len = parser.tokens.len - 1; // pop .Eof
            parser.tokens.len = len;
            break :blk len;
        } else 0;
        parser.token_it = parser.tokens.iterator(new_len);
        while (true) {
            const tok = try parser.tokens.addOne();
            tok.* = parser.tokenizer.next();
            if (tok.id == .Eof)
                break;
        }
    }

    const LRValue = enum {
        L,
        R,
    };

    /// root : (stmt NL)* EOF
    fn root(parser: *Parser) !void {
        if (parser.eatToken(.Eof, true)) |_| return;
        while (true) {
            const res = try parser.stmt();
            if (res) |some|
                try parser.builder.discard(some);
            if (parser.eatToken(.Nl, false)) |_| continue;
            _ = try parser.expectToken(.Eof, false);
            return;
        }
    }

    /// stmt : let | expr.l
    fn stmt(parser: *Parser) !?RegRef {
        return if (try parser.let())
            null
        else
            try parser.expr(.L, false);
    }

    /// let : "let" unwrap "=" expr.r
    fn let(parser: *Parser) anyerror!bool {
        unreachable;
    }

    /// expr
    ///     : fn
    ///     | [.l jump_expr]
    ///     | bool_expr
    fn expr(parser: *Parser, lr_value: LRValue, skip_nl: bool) anyerror!?RegRef {
        return if (try parser.func(skip_nl)) |val|
            val
        else if (try parser.jumpExpr(lr_value))
            null
        else
            try parser.boolExpr(lr_value, skip_nl);
    }

    /// fn : "fn" "(" (unwrap ",")* ")" expr
    fn func(parser: *Parser, skip_nl: bool) anyerror!?RegRef {
        const tok = parser.eatToken(.Keyword_fn, skip_nl) orelse return null;
        return error.Unimplemented;
        // try parser.builder.beginFunc(tok);
        // try parser.expectToken(.LParen, true);
        // try parser.expectToken(.LParen, true);
        // const res = try parser.expr(.R true);
        // return try parser.builder.endFunc(tok, res);
    }

    /// jump_expr : "return" expr.r | "break" | "continue"
    fn jumpExpr(parser: *Parser, lr_value: LRValue) anyerror!bool {
        const tok = parser.eatToken(.Keyword_return, false) orelse
            parser.eatToken(.Keyword_break, false) orelse
            parser.eatToken(.Keyword_continue, false) orelse
            return false;
        if (lr_value != .L) {
            // TODO return, break, continue do not produce values
            return error.ParseError;
        }
        return error.Unimplemented;
        // return true;
    }

    /// bool_expr : comparision_expr (("or" comparision_expr.r)* | ("and" comparision_expr.r)*)
    fn boolExpr(parser: *Parser, lr_value: LRValue, skip_nl: bool) !?RegRef {
        var lhs = (try parser.comparisionExpr(lr_value, skip_nl)) orelse return null;

        // TODO improve
        if (parser.eatToken(.Keyword_or, skip_nl)) |t| {
            var tok = t;
            while (true) {
                const rhs = (try parser.comparisionExpr(.R, true)).?;
                lhs = try parser.builder.infix(lhs, tok, rhs);
                if (parser.eatToken(.Keyword_or, skip_nl)) |tt| tok = tt else break;
            }
        } else {
            while (parser.eatToken(.Keyword_and, skip_nl)) |tok| {
                const rhs = (try parser.comparisionExpr(.R, true)).?;
                lhs = try parser.builder.infix(lhs, tok, rhs);
            }
        }
        return lhs;
    }

    /// comparision_expr : range_expr (("<" | "<=" | ">" | ">="| "==" | "!=" | "in"  | "is") range_expr.r)
    fn comparisionExpr(parser: *Parser, lr_value: LRValue, skip_nl: bool) !?RegRef {
        var lhs = (try parser.rangeExpr(lr_value, skip_nl)) orelse return null;

        if (parser.eatToken(.LArr, skip_nl) orelse
            parser.eatToken(.LArrEqual, skip_nl) orelse
            parser.eatToken(.RArr, skip_nl) orelse
            parser.eatToken(.RArrEqual, skip_nl) orelse
            parser.eatToken(.EqualEqual, skip_nl) orelse
            parser.eatToken(.BangEqual, skip_nl) orelse
            parser.eatToken(.Keyword_in, skip_nl) orelse
            parser.eatToken(.Keyword_is, skip_nl)) |tok|
        {
            const rhs = (try parser.rangeExpr(.R, true)).?;
            lhs = try parser.builder.infix(lhs, tok, rhs);
        }
        return lhs;
    }

    /// range_expr : bit_expr ("..." bit_expr.r)?
    fn rangeExpr(parser: *Parser, lr_value: LRValue, skip_nl: bool) !?RegRef {
        var lhs = (try parser.bitExpr(lr_value, skip_nl)) orelse return null;

        if (parser.eatToken(.Ellipsis, skip_nl)) |tok| {
            const rhs = (try parser.bitExpr(.R, true)).?;
            lhs = try parser.builder.infix(lhs, tok, rhs);
        }
        return lhs;
    }

    /// bit_expr : shift_expr (("&" shift_expr.r)* | ("|" shift_expr.r)* | ("|" shift_expr.r)*) | ("catch" ("|" unwrap "|")? expr)
    fn bitExpr(parser: *Parser, lr_value: LRValue, skip_nl: bool) !?RegRef {
        var lhs = (try parser.shiftExpr(lr_value, skip_nl)) orelse return null;

        // TODO improve
        if (parser.eatToken(.Ampersand, skip_nl)) |t| {
            // &
            var tok = t;
            while (true) {
                const rhs = (try parser.shiftExpr(.R, true)).?;
                lhs = try parser.builder.infix(lhs, tok, rhs);
                if (parser.eatToken(.Ampersand, skip_nl)) |tt| tok = tt else break;
            }
        } else if (parser.eatToken(.Pipe, skip_nl)) |t| {
            // |
            var tok = t;
            while (true) {
                const rhs = (try parser.shiftExpr(.R, true)).?;
                lhs = try parser.builder.infix(lhs, tok, rhs);
                if (parser.eatToken(.Pipe, skip_nl)) |tt| tok = tt else break;
            }
        } else if (parser.eatToken(.Caret, skip_nl)) |t| {
            // ^
            var tok = t;
            while (true) {
                const rhs = (try parser.shiftExpr(.R, true)).?;
                lhs = try parser.builder.infix(lhs, tok, rhs);
                if (parser.eatToken(.Caret, skip_nl)) |tt| tok = tt else break;
            }
        } else if (parser.eatToken(.Keyword_catch, skip_nl)) |_| {
            // catch
            const jump = try parser.builder.jumpNotErr(lhs);
            defer parser.builder.finishJump(jump);
            if (parser.eatToken(.Pipe, true)) |_| {
                @panic("TODO");
                // const unwrap = try parser.unwrap();
                // lhs = try parser.builder.unwrap(lhs, unwrap);
                // _ = try parser.expectToken(.Pipe, true);
            }
            if (try parser.expr(lr_value, true)) |rhs| {
                try parser.builder.move(rhs, lhs);
            }
        }
        return lhs;
    }

    /// shift_expr : add_expr (("<<" | ">>") add_expr.r)
    fn shiftExpr(parser: *Parser, lr_value: LRValue, skip_nl: bool) !?RegRef {
        var lhs = (try parser.addExpr(lr_value, skip_nl)) orelse return null;

        if (parser.eatToken(.LArrArr, skip_nl) orelse
            parser.eatToken(.RArrArr, skip_nl)) |tok|
        {
            const rhs = (try parser.addExpr(.R, true)).?;
            return try parser.builder.infix(lhs, tok, rhs);
        }
        return lhs;
    }

    /// add_expr : mul_expr (("-" | "+") mul_expr.r)*
    fn addExpr(parser: *Parser, lr_value: LRValue, skip_nl: bool) !?RegRef {
        var lhs = (try parser.mulExpr(lr_value, skip_nl)) orelse return null;

        while (parser.eatToken(.Minus, skip_nl) orelse
            parser.eatToken(.Plus, skip_nl)) |tok|
        {
            const rhs = (try parser.mulExpr(.R, true)).?;
            lhs = try parser.builder.infix(lhs, tok, rhs);
        }
        return lhs;
    }

    /// mul_expr : prefix_expr (("*" | "/" | "//" | "%") prefix_expr.r)*
    fn mulExpr(parser: *Parser, lr_value: LRValue, skip_nl: bool) anyerror!?RegRef {
        var lhs = (try parser.prefixExpr(lr_value, skip_nl)) orelse return null;

        while (parser.eatToken(.Asterisk, skip_nl) orelse
            parser.eatToken(.Slash, skip_nl) orelse
            parser.eatToken(.SlashSlash, skip_nl) orelse
            parser.eatToken(.Percent, skip_nl)) |tok|
        {
            const rhs = (try parser.prefixExpr(.R, true)).?;
            lhs = try parser.builder.infix(lhs, tok, rhs);
        }

        return lhs;
    }

    /// prefix_expr
    ///     : "try" bool_expr.r
    ///     | ("-" | "+" | "not" | "~")? primary_expr suffix_expr* [.l assign]?
    fn prefixExpr(parser: *Parser, lr_value: LRValue, skip_nl: bool) anyerror!?RegRef {
        if (parser.eatToken(.Keyword_try, skip_nl)) |tok| {
            const rhs = (try parser.boolExpr(.R, true)).?;
            return try parser.builder.prefix(tok, rhs);
        }
        const prefix_op = parser.eatToken(.Minus, skip_nl) orelse parser.eatToken(.Plus, skip_nl) orelse
            parser.eatToken(.Tilde, skip_nl) orelse parser.eatToken(.Keyword_not, skip_nl);
        var primary = try parser.primaryExpr(lr_value, skip_nl);
        primary = try parser.suffixExpr(primary, skip_nl);
        if (prefix_op) |some| {
            primary = try parser.builder.prefix(some, primary);
        }
        return try parser.assign(lr_value, primary);
    }

    /// suffix_expr
    ///     : "[" bool_expr.r "]"
    ///     | "(" (bool_expr.r ",")* ")"
    ///     | "." IDENTIFIER
    fn suffixExpr(parser: *Parser, lhs: RegRef, skip_nl: bool) anyerror!RegRef {
        while (parser.eatToken(.LBracket, skip_nl) orelse
            parser.eatToken(.LParen, skip_nl) orelse
            parser.eatToken(.Period, skip_nl)) |tok|
        {
            // TODO
            return error.Unimplemented;
            // const rhs = (try parser.boolExpr(.R, true)).?;
            // lhs = try parser.builder.infix(lhs, tok, rhs);
        }

        return lhs;
    }

    /// assign
    ///     : "=" expr.r
    ///     | ("+=" | "-=" | "*=" | "/=" | "//=" | "%=" | "<<=" | ">>=" | "&=" | "|=" | "^=") bit_expr.r
    fn assign(parser: *Parser, lr_value: LRValue, lhs: RegRef) anyerror!?RegRef {
        // assignment cannot happen in places where NL is not necessary
        if (parser.eatToken(.Equal, false) orelse
            parser.eatToken(.MinusEqual, false) orelse
            parser.eatToken(.AsteriskEqual, false) orelse
            parser.eatToken(.SlashEqual, false) orelse
            parser.eatToken(.SlashSlashEqual, false) orelse
            parser.eatToken(.PercentEqual, false) orelse
            parser.eatToken(.LArrArrEqual, false) orelse
            parser.eatToken(.RArrArrEqual, false) orelse
            parser.eatToken(.AmpersandEqual, false) orelse
            parser.eatToken(.PipeEqual, false) orelse
            parser.eatToken(.CaretEqual, false)) |tok|
        {
            if (lr_value != .L) {
                // TODO assignment does not produce value
                return error.ParseError;
            }
            const rhs = if (tok.id == .Equal)
                (try parser.expr(.R, true)).?
            else
                (try parser.bitExpr(.R, true)).?;
            try parser.builder.assign(lhs, tok, rhs);
            return null;
        }

        return lhs;
    }

    /// primary_expr
    ///     : IDENTIFIER
    ///     | STRING
    ///     | NUMBER
    ///     | "true"
    ///     | "false"
    ///     | "(" (expr.r ",")* ")"
    ///     | "{" ((IDENTIFIER | STRING) ":" expr.r ",")* "}"
    ///     | "[" (expr.r ",")* "]"
    ///     | "error" "(" expr.r ")"
    ///     | "import" "(" STRING ")"
    ///     | block
    ///     | if
    ///     | while
    ///     | for
    ///     | match
    fn primaryExpr(parser: *Parser, lr_value: LRValue, skip_nl: bool) anyerror!RegRef {
        if (parser.eatToken(.Number, skip_nl) orelse
            parser.eatToken(.String, skip_nl) orelse
            parser.eatToken(.Keyword_true, skip_nl) orelse
            parser.eatToken(.Keyword_false, skip_nl)) |tok|
        {
            return parser.builder.constant(tok);
        }
        if (parser.eatToken(.Identifier, skip_nl)) |tok| {
            return parser.builder.declRef(tok);
        }
        if (parser.eatToken(.Keyword_error, skip_nl)) |tok| {
            _ = try parser.expectToken(.LParen, true);
            const val = (try parser.expr(.R, true)).?;
            _ = try parser.expectToken(.RParen, true);
            return parser.builder.buildErr(tok, val);
        }
        if (parser.eatToken(.Keyword_import, skip_nl)) |tok| {
            _ = try parser.expectToken(.LParen, true);
            const str = try parser.builder.constant(try parser.expectToken(.String, true));
            _ = try parser.expectToken(.RParen, true);
            return parser.builder.import(tok, str);
        }
        if (parser.eatToken(.LParen, skip_nl)) |tok| {
            if (parser.eatToken(.Nl, false)) |_| {
                // block
            } else {
                // tuple or grouped expr
            }
        }
        if (parser.eatToken(.LBrace, skip_nl)) |tok| {
            //     | "{" ((IDENTIFIER | STRING) ":" expr.r ",")* "}"
        }
        if (parser.eatToken(.LBracket, skip_nl)) |tok| {
            //     | "[" (expr.r ",")* "]"
            const arr = try parser.builder.buildList(tok);
            var count: u32 = 0;
            var rbracket: *Token = undefined;
            if (parser.eatToken(.RBracket, true)) |t| {
                rbracket = t;
            } else {
                while (true) {
                    const val = (try parser.expr(.R, true)).?;
                    try parser.builder.listPush(val);
                    if (parser.eatToken(.Comma, true) == null) break;
                }
                rbracket = try parser.expectToken(.RBracket, true);
            }
            return try parser.builder.finishList(rbracket, count);
        }
        //     | if
        //     | while
        //     | for
        //     | match
        // TODO expected Identifier, String, Number, true, false, '(', '{', '[', error, import, if, while, for, match
        return error.ParseError;
    }

    fn eatToken(parser: *Parser, id: @TagType(Token.Id), skip_nl: bool) ?*Token {
        var next = parser.token_it.next().?;
        if (skip_nl) {
            while (next.id == .Nl) {
                next = parser.token_it.next().?;
            }
        }
        if (next.id == id) {
            return next;
        } else {
            _ = parser.token_it.prev();
            return null;
        }
    }

    fn expectToken(parser: *Parser, id: @TagType(Token.Id), skip_nl: bool) anyerror!*Token {
        if (parser.eatToken(id, skip_nl)) |tok| return tok;
        // TODO err expected token {id} found {parser.token_it.next().?.id}
        return error.ParseError;
    }
};
