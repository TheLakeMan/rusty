use crate::lexer::Token;

#[derive(Debug, Clone)]
pub enum Expr {
    Number(f64),
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

    pub fn parse(&mut self) -> Vec<Expr> {
        let mut ast = Vec::new();
        while self.pos < self.tokens.len() {
            if let Some(expr) = self.parse_expr() {
                ast.push(expr);
            } else {
                break;
            }
        }
        ast
    }

    fn parse_expr(&mut self) -> Option<Expr> {
        if self.pos >= self.tokens.len() {
            return None;
        }
        match &self.tokens[self.pos] {
            Token::LParen => {
                self.pos += 1;
                let mut list = Vec::new();
                while self.pos < self.tokens.len() && self.tokens[self.pos] != Token::RParen {
                    if let Some(e) = self.parse_expr() {
                        list.push(e);
                    } else {
                        break;
                    }
                }
                if self.pos < self.tokens.len() && self.tokens[self.pos] == Token::RParen {
                    self.pos += 1;
                }
                Some(Expr::List(list))
            }
            Token::Number(n) => {
                self.pos += 1;
                Some(Expr::Number(*n))
            }
            Token::String(s) => {
                self.pos += 1;
                Some(Expr::String(s.clone()))
            }
            Token::Symbol(s) => {
                self.pos += 1;
                Some(Expr::Symbol(s.clone()))
            }
            Token::RParen | Token::EOF => {
                self.pos += 1;
                None
            }
        }
    }
}
