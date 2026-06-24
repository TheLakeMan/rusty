use crate::lexer::Token;

#[derive(Debug, Clone)]
pub enum Expr {
    Number(f64),
    Bool(bool),
    String(String),
    Symbol(String),
    List(Vec<Expr>),
    Nil,
}

pub struct Parser {
    tokens: Vec<Token>,
    pos: usize,
}

impl Parser {
    pub fn new(tokens: Vec<Token>) -> Self {
        Parser { tokens, pos: 0 }
    }

    fn peek(&self) -> &Token {
        self.tokens.get(self.pos).unwrap_or(&Token::EOF)
    }

    fn advance(&mut self) -> &Token {
        let tok = self.tokens.get(self.pos).unwrap_or(&Token::EOF);
        self.pos += 1;
        tok
    }

    pub fn parse(&mut self) -> Vec<Expr> {
        let mut ast = Vec::new();
        while !matches!(self.peek(), Token::EOF) {
            if let Some(expr) = self.parse_expr() {
                ast.push(expr);
            } else {
                break;
            }
        }
        ast
    }

    fn parse_expr(&mut self) -> Option<Expr> {
        match self.peek().clone() {
            Token::EOF => None,
            Token::RParen => {
                self.advance();
                None
            }
            Token::Quote => {
                self.advance();
                // Desugar 'x -> (quote x)
                let inner = self.parse_expr()?;
                Some(Expr::List(vec![Expr::Symbol("quote".to_string()), inner]))
            }
            Token::LParen => {
                self.advance();
                let mut list = Vec::new();
                loop {
                    match self.peek() {
                        Token::RParen | Token::EOF => { self.advance(); break; }
                        _ => {
                            if let Some(e) = self.parse_expr() {
                                list.push(e);
                            }
                        }
                    }
                }
                Some(Expr::List(list))
            }
            Token::Number(n) => { let n = n; self.advance(); Some(Expr::Number(n)) }
            Token::Bool(b) => { let b = b; self.advance(); Some(Expr::Bool(b)) }
            Token::String(s) => { let s = s; self.advance(); Some(Expr::String(s)) }
            Token::Symbol(s) => { let s = s; self.advance(); Some(Expr::Symbol(s)) }
        }
    }
}
