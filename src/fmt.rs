// Copyright (c) 2026 Nicholas Vermeulen
// SPDX-License-Identifier: AGPL-3.0-or-later

//! rusty-fmt — a canonical source formatter for Rusty (Phase 5.2, dev env).
//!
//! It is a *re-indenter + spacing normalizer*, NOT an AST round-tripper: it
//! tokenizes the source (preserving comments and string contents verbatim) and
//! re-emits with canonical whitespace, so it is **semantics-preserving by
//! construction** — the token sequence is identical, only the whitespace
//! *between* tokens changes, and whitespace is insignificant in Lisp except
//! inside strings, which are kept byte-for-byte. Two properties the golden test
//! pins:
//!   - idempotent:            `fmt(fmt(x)) == fmt(x)`
//!   - semantics-preserving:  `eval(fmt(x)) == eval(x)` (and comments survive)
//!
//! Canonical rules, all documented so the output is predictable:
//!   - no space after `(` / before `)`; exactly one space between tokens on a
//!     line; reader prefixes `' ` `` ` `` `,` `,@` attach to the following form.
//!   - structural indentation: a *body form* (define/lambda/let/when/…) indents
//!     its body two spaces from its own `(`; any other symbol-headed form aligns
//!     continuation lines under its first argument (so `if`/`cond`/`and`/calls
//!     line up the operands); a data list (headed by a non-symbol) aligns under
//!     its first element.
//!   - the user's own LINE BREAKS are preserved (no reflow — deliberately, since
//!     reflowing s-expressions is opinionated and risky); runs of blank lines
//!     collapse to at most one; trailing whitespace is stripped; the file ends
//!     in exactly one newline.
//!
//! Honest scope: this normalizes layout, it does not restructure code. It will
//! change files whose comment margins or line breaks differ from the canonical
//! layout — that is what a formatter is for; it is opt-in (`rusty fmt`), never
//! run implicitly.

/// Format Rusty source text into its canonical layout.
pub fn format(src: &str) -> String {
    let toks = tokenize(src);
    render(&toks)
}

#[derive(Clone, Debug, PartialEq)]
enum Tok {
    Open,
    Close,
    Prefix(String), // ' ` , ,@
    Atom(String),   // symbol / number / `.`
    Str(String),    // includes the surrounding quotes, verbatim
    Comment(String), // includes the leading `;`, verbatim, no trailing newline
    Newline,
}

fn tokenize(src: &str) -> Vec<Tok> {
    let chars: Vec<char> = src.chars().collect();
    let mut toks = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        match c {
            '\n' => { toks.push(Tok::Newline); i += 1; }
            ' ' | '\t' | '\r' => { i += 1; }
            ';' => {
                let start = i;
                while i < chars.len() && chars[i] != '\n' { i += 1; }
                toks.push(Tok::Comment(chars[start..i].iter().collect()));
            }
            '"' => {
                let start = i;
                i += 1;
                while i < chars.len() {
                    match chars[i] {
                        '\\' => { i += 2; }        // skip escaped char
                        '"'  => { i += 1; break; }
                        _    => { i += 1; }
                    }
                }
                toks.push(Tok::Str(chars[start..i.min(chars.len())].iter().collect()));
            }
            '(' | '[' => { toks.push(Tok::Open); i += 1; }
            ')' | ']' => { toks.push(Tok::Close); i += 1; }
            '\'' => { toks.push(Tok::Prefix("'".into())); i += 1; }
            '`'  => { toks.push(Tok::Prefix("`".into())); i += 1; }
            ',' => {
                if i + 1 < chars.len() && chars[i + 1] == '@' {
                    toks.push(Tok::Prefix(",@".into())); i += 2;
                } else {
                    toks.push(Tok::Prefix(",".into())); i += 1;
                }
            }
            _ => {
                let start = i;
                while i < chars.len()
                    && !matches!(chars[i],
                        ' ' | '\t' | '\r' | '\n' | '(' | ')' | '[' | ']'
                        | '"' | ';' | '\'' | '`' | ',') {
                    i += 1;
                }
                toks.push(Tok::Atom(chars[start..i].iter().collect()));
            }
        }
    }
    toks
}

/// Forms whose body hangs two spaces from their own `(`, overriding the
/// default first-argument alignment. (`if`/`cond`/`and`/`or` are deliberately
/// absent — they read better with operand alignment.)
fn is_body_form(s: &str) -> bool {
    matches!(s,
        "define" | "def" | "define-macro" | "defmacro" | "deftool" | "deftool-spec"
        | "defrust" | "defrust*" | "defun-constrained" | "define-typed" | "defproof"
        | "deftest" | "defguard" | "lambda"
        | "let" | "let*" | "letrec" | "letrec*" | "named-let" | "parameterize"
        | "when" | "unless" | "begin" | "do" | "dotimes" | "while" | "for" | "for-each"
        | "case" | "match" | "eval-when" | "module")
}

#[derive(Clone, Copy, PartialEq)]
enum Kind { Data, Body, Operator }

struct Ctx {
    paren_col: usize,
    base: usize,          // indent for continuation lines inside this form
    kind: Kind,
    head_seen: bool,
    awaiting_arg1: bool,
    head_line: usize,
}

fn is_number(s: &str) -> bool { s.parse::<f64>().is_ok() }

fn render(toks: &[Tok]) -> String {
    // Split into logical source lines on Newline (empty groups = blank lines).
    let mut lines: Vec<Vec<&Tok>> = vec![Vec::new()];
    for t in toks {
        if *t == Tok::Newline { lines.push(Vec::new()); }
        else { lines.last_mut().unwrap().push(t); }
    }

    let mut stack: Vec<Ctx> = Vec::new();
    let mut out: Vec<String> = Vec::new();
    let mut line_no = 0usize;

    for group in &lines {
        if group.is_empty() {
            // blank line — collapse runs to at most one, drop leading blanks
            if !out.is_empty() && !out.last().unwrap().is_empty() { out.push(String::new()); }
            line_no += 1;
            continue;
        }
        let indent = stack.last().map(|c| c.base).unwrap_or(0);
        let mut line = " ".repeat(indent);
        let mut col = indent;
        // A space is inserted before a token unless we're at the line start, or
        // the previous token was `(` or a reader prefix (which attach to the
        // following form). Only these two "no space after" flags are needed.
        let mut prev_prefix = false;
        let mut prev_open = false;

        for tok in group {
            match tok {
                Tok::Newline => unreachable!(),
                Tok::Open => {
                    if col != indent && !prev_open && !prev_prefix { line.push(' '); col += 1; }
                    let paren_col = col;
                    line.push('('); col += 1;
                    consume_arg1(&mut stack, line_no, paren_col); // arg1 of enclosing form is this `(`
                    stack.push(Ctx { paren_col, base: paren_col + 1, kind: Kind::Data,
                                     head_seen: false, awaiting_arg1: false, head_line: line_no });
                    prev_open = true; prev_prefix = false;
                }
                Tok::Close => {
                    line.push(')'); col += 1;
                    stack.pop();
                    prev_open = false; prev_prefix = false;
                }
                Tok::Prefix(p) => {
                    if col != indent && !prev_open && !prev_prefix { line.push(' '); col += 1; }
                    let at = col;
                    line.push_str(p); col += p.chars().count();
                    // a prefix that heads a form marks it as a data list
                    set_head_or_arg1(&mut stack, line_no, at, HeadTok::Prefix);
                    prev_prefix = true; prev_open = false;
                }
                Tok::Atom(a) => {
                    if col != indent && !prev_open && !prev_prefix { line.push(' '); col += 1; }
                    let at = col;
                    line.push_str(a); col += a.chars().count();
                    let ht = if is_body_form(a) { HeadTok::BodySym }
                             else if is_number(a) { HeadTok::NonSym }
                             else { HeadTok::Sym };
                    set_head_or_arg1(&mut stack, line_no, at, ht);
                    prev_open = false; prev_prefix = false;
                }
                Tok::Str(s) => {
                    if col != indent && !prev_open && !prev_prefix { line.push(' '); col += 1; }
                    let at = col;
                    line.push_str(s);
                    // a string can (rarely) contain a newline; track columns honestly
                    col = match s.rsplit_once('\n') {
                        Some((_, tail)) => tail.chars().count(),
                        None => col + s.chars().count(),
                    };
                    set_head_or_arg1(&mut stack, line_no, at, HeadTok::NonSym);
                    prev_open = false; prev_prefix = false;
                }
                Tok::Comment(cm) => {
                    if col != indent && !prev_open && !prev_prefix { line.push(' '); col += 1; }
                    line.push_str(cm); col += cm.chars().count();
                    // a comment never counts as a form head or argument
                    prev_open = false; prev_prefix = false;
                }
            }
        }
        // strip any accidental trailing whitespace
        while line.ends_with(' ') { line.pop(); }
        out.push(line);
        line_no += 1;
    }

    // drop trailing blank lines, guarantee exactly one final newline
    while out.last().map(|l| l.is_empty()).unwrap_or(false) { out.pop(); }
    let mut s = out.join("\n");
    s.push('\n');
    s
}

enum HeadTok { Sym, BodySym, NonSym, Prefix }

/// If the innermost form has just been opened, classify its head; otherwise, if
/// it is an operator form still awaiting its first argument, record the arg's
/// column as the continuation indent.
fn set_head_or_arg1(stack: &mut [Ctx], line_no: usize, at: usize, ht: HeadTok) {
    if let Some(top) = stack.last_mut() {
        if !top.head_seen {
            top.head_seen = true;
            top.head_line = line_no;
            match ht {
                HeadTok::BodySym => { top.kind = Kind::Body; top.base = top.paren_col + 2; }
                HeadTok::Sym => {
                    top.kind = Kind::Operator;
                    top.base = top.paren_col + 2; // fallback if arg1 is on the next line
                    top.awaiting_arg1 = true;
                }
                HeadTok::NonSym | HeadTok::Prefix => {
                    top.kind = Kind::Data; top.base = top.paren_col + 1;
                }
            }
        } else if top.awaiting_arg1 && top.kind == Kind::Operator {
            if line_no == top.head_line { top.base = at; }
            top.awaiting_arg1 = false;
        }
    }
}

/// A newly-opened `(` inside an enclosing form is either that form's head (so
/// the form is a data list) or its first argument (fixing the operator's
/// continuation indent).
fn consume_arg1(stack: &mut [Ctx], line_no: usize, at: usize) {
    if let Some(top) = stack.last_mut() {
        if !top.head_seen {
            top.head_seen = true;
            top.head_line = line_no;
            top.kind = Kind::Data;
            top.base = top.paren_col + 1;
        } else if top.awaiting_arg1 && top.kind == Kind::Operator {
            if line_no == top.head_line { top.base = at; }
            top.awaiting_arg1 = false;
        }
    }
}
