#[derive(Debug, Clone, PartialEq)]
pub enum Token {
    LParen,
    RParen,
    Number(f64),
    String(String),
    Symbol(String),
    EOF,
}

pub struct Lexer {
    input: Vec<char>,
    pos: usize,
}

impl Lexer {
    pub fn new(input: &str) -> Self {
        Lexer {
            input: input.chars().collect(),
            pos: 0,
        }
    }

    pub fn tokenize(&mut self) -> Vec<Token> {
        let mut tokens = Vec::new();
        while self.pos < self.input.len() {
            let ch = self.input[self.pos];
            match ch {
                '(' => {
                    tokens.push(Token::LParen);
                    self.pos += 1;
                }
                ')' => {
                    tokens.push(Token::RParen);
                    self.pos += 1;
                }
                '0'..='9' | '-' => {
                    // Simple number parsing
                    let start = self.pos;
                    while self.pos < self.input.len() && (self.input[self.pos].is_numeric() || self.input[self.pos] == '.' || self.input[self.pos] == '-') {
                        self.pos += 1;
                    }
                    let num_str: String = self.input[start..self.pos].iter().collect();
                    if let Ok(n) = num_str.parse::<f64>() {
                        tokens.push(Token::Number(n));
                    } else {
                        tokens.push(Token::Symbol(num_str));
                    }
                }
                '"' => {
                    // Simple string
                    self.pos += 1;
                    let start = self.pos;
                    while self.pos < self.input.len() && self.input[self.pos] != '"' {
                        self.pos += 1;
                    }
                    let s: String = self.input[start..self.pos].iter().collect();
                    tokens.push(Token::String(s));
                    self.pos += 1; // skip closing quote
                }
                ' ' | '\n' | '\t' | '\r' => {
                    self.pos += 1;
                }
                ';' => {
                    // Comment
                    while self.pos < self.input.len() && self.input[self.pos] != '\n' {
                        self.pos += 1;
                    }
                }
                _ => {
                    let start = self.pos;
                    while self.pos < self.input.len() && !self.input[self.pos].is_whitespace() && self.input[self.pos] != '(' && self.input[self.pos] != ')' {
                        self.pos += 1;
                    }
                    let sym: String = self.input[start..self.pos].iter().collect();
                    if !sym.is_empty() {
                        tokens.push(Token::Symbol(sym));
                    }
                }
            }
        }
        tokens.push(Token::EOF);
        tokens
    }
}
