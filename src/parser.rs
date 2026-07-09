use crate::lexer::Token;

#[derive(Debug, Clone)]
pub enum Expr {
    Number(f64),
    Bool(bool),
    String(String),
    Symbol(String),
    List(std::rc::Rc<Vec<Expr>>),
    Nil,
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
}

impl Parser {
    pub fn new(tokens: Vec<Token>) -> Self { Parser { tokens, pos: 0 } }

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

    fn parse_expr(&mut self) -> Option<Expr> {
        match self.peek().clone() {
            Token::EOF | Token::RParen => { self.advance(); None }

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
                        Token::RParen | Token::EOF => { self.advance(); break; }
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
