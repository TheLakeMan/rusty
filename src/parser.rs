// Copyright (c) 2026 Nicholas Vermeulen
// SPDX-License-Identifier: AGPL-3.0-or-later

use crate::lexer::Token;

#[derive(Debug, Clone)]
pub enum Expr {
    Number(f64),
    Bool(bool),
    String(String),
    Symbol(String),
    List(std::rc::Rc<Vec<Expr>>),
    Nil,
    // Lexical addressing (resolve.rs): slot-resolved variable references,
    // produced only by resolving a lambda body at closure creation — never
    // by the parser. Every consumer except eval's lookup path must treat
    // them exactly as Expr::Symbol(name) ("degrade to the name"), so a ref
    // leaking into display/serialization/macro-land is indistinguishable
    // from the symbol it replaced.
    LocalRef { depth: u16, slot: u16, name: std::rc::Rc<str> },
    // idx is a lazily-filled cache of the name's slot in the root frame's
    // stable value table (u32::MAX = not yet resolved); sound because root
    // slots are append-only and a closure's root never changes.
    GlobalRef { name: std::rc::Rc<str>, idx: std::cell::Cell<u32> },
}

/// Build a list expression. `Expr::List` is `Rc`-backed (Phase 3.3 —
/// cloning an Expr used to deep-copy whole function bodies on every call),
/// so construction goes through here.
pub fn elist(items: Vec<Expr>) -> Expr {
    Expr::List(std::rc::Rc::new(items))
}

pub struct Parser {
    tokens: Vec<Token>,
    pos: usize,
    /// First structural complaint found, if any. See `parse_checked`.
    err: Option<String>,
    /// Native recursion depth of `parse_expr` — nesting of parens/quotes. The
    /// parser is recursive descent and would overflow the native stack (an
    /// unrecoverable Rust abort) on deeply nested input; this caps it so a
    /// hostile/corrupt file is *refused* like a truncated one, not core-dumped.
    depth: usize,
}

/// Nesting depth past which parsing is refused. Unlike deep *recursion* (a real
/// use case, guarded stack-adaptively in eval), deeply nested *source* is never
/// legitimate, so a fixed cap safe on the smallest stack we run on (the ~8 MB
/// main thread, whose recursive-descent cliff is ~20k+) is right: 8k refuses
/// hostile/corrupt input cleanly without ever approaching a real file's nesting.
const MAX_PARSE_DEPTH: usize = 8_000;

impl Parser {
    pub fn new(tokens: Vec<Token>) -> Self { Parser { tokens, pos: 0, err: None, depth: 0 } }

    fn peek(&self) -> &Token { self.tokens.get(self.pos).unwrap_or(&Token::EOF) }

    fn advance(&mut self) -> Token {
        let tok = self.tokens.get(self.pos).cloned().unwrap_or(Token::EOF);
        self.pos += 1;
        tok
    }

    pub fn parse(&mut self) -> Vec<Expr> {
        let mut ast = Vec::new();
        while !matches!(self.peek(), Token::EOF) {
            if let Some(e) = self.parse_expr() { ast.push(e); } else { break; }
        }
        ast
    }

    /// `parse`, but structural damage is an error instead of a shrug.
    ///
    /// The lenient version silently *completes* an unclosed list at EOF and
    /// silently *stops* at a stray top-level ')' — so a truncated file (a
    /// partial clone, an interrupted write, a bad merge) loads as though it
    /// were whole, with the tail quietly swallowed into the last open form or
    /// dropped on the floor. Every caller that runs code wants to know instead.
    /// `parse` itself stays lenient: the REPL decides completeness with its own
    /// scanner before it ever gets here, and the LSP reports its own positions.
    pub fn parse_checked(&mut self) -> Result<Vec<Expr>, String> {
        let ast = self.parse();
        match self.err.take() {
            Some(e) => Err(e),
            None => Ok(ast),
        }
    }

    /// Depth-guarded entry to the recursive descent. On overflow it records the
    /// error and consumes the rest of the input so every open `(` loop and the
    /// top-level `parse` loop hit EOF and unwind — `parse_checked` then surfaces
    /// the error instead of the parser overflowing the native stack.
    fn parse_expr(&mut self) -> Option<Expr> {
        self.depth += 1;
        if self.depth > MAX_PARSE_DEPTH {
            if self.err.is_none() {
                self.err = Some(format!(
                    "nesting too deep (over {} levels) — refusing to parse", MAX_PARSE_DEPTH));
            }
            self.pos = self.tokens.len();   // force EOF everywhere → all loops terminate
            self.depth -= 1;
            return None;
        }
        let r = self.parse_expr_inner();
        self.depth -= 1;
        r
    }

    fn parse_expr_inner(&mut self) -> Option<Expr> {
        match self.peek().clone() {
            Token::EOF => { self.advance(); None }
            // A ')' with nothing open. parse() stops here, which would discard
            // everything after it — never silently.
            Token::RParen => {
                if self.err.is_none() {
                    self.err = Some("unexpected ')' with no matching '('".to_string());
                }
                self.advance();
                None
            }

            Token::Quote => {
                self.advance();
                let inner = self.parse_expr()?;
                Some(elist(vec![Expr::Symbol("quote".into()), inner]))
            }
            Token::Quasiquote => {
                self.advance();
                let inner = self.parse_expr()?;
                Some(elist(vec![Expr::Symbol("quasiquote".into()), inner]))
            }
            Token::Unquote => {
                self.advance();
                let inner = self.parse_expr()?;
                Some(elist(vec![Expr::Symbol("unquote".into()), inner]))
            }
            Token::UnquoteSplice => {
                self.advance();
                let inner = self.parse_expr()?;
                Some(elist(vec![Expr::Symbol("unquote-splicing".into()), inner]))
            }
            Token::LParen => {
                self.advance();
                let mut list = Vec::new();
                loop {
                    match self.peek() {
                        Token::RParen => { self.advance(); break; }
                        // Input ran out with this list still open. Don't advance
                        // past EOF — parse()'s loop needs to see it and stop.
                        Token::EOF => {
                            if self.err.is_none() {
                                self.err = Some(
                                    "unexpected end of input: a '(' is never closed".to_string());
                            }
                            break;
                        }
                        _ => { if let Some(e) = self.parse_expr() { list.push(e); } }
                    }
                }
                Some(elist(list))
            }
            Token::Number(n) => { let n = n; self.advance(); Some(Expr::Number(n)) }
            Token::Bool(b)   => { let b = b; self.advance(); Some(Expr::Bool(b)) }
            Token::String(s) => { let s = s; self.advance(); Some(Expr::String(s)) }
            Token::Symbol(s) => { let s = s; self.advance(); Some(Expr::Symbol(s)) }
        }
    }
}
