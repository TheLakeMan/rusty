#[derive(Debug, Clone, PartialEq)]
pub enum Token {
    LParen,
    RParen,
    Quote,          // ' shorthand
    Number(f64),
    Bool(bool),     // #t / #f
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
        Lexer { input: input.chars().collect(), pos: 0 }
    }

    fn peek(&self) -> Option<char> {
        self.input.get(self.pos).copied()
    }

    fn advance(&mut self) -> Option<char> {
        let ch = self.input.get(self.pos).copied();
        self.pos += 1;
        ch
    }

    pub fn tokenize(&mut self) -> Vec<Token> {
        let mut tokens = Vec::new();
        loop {
            // Skip whitespace
            while matches!(self.peek(), Some(' ' | '\n' | '\t' | '\r')) {
                self.advance();
            }
            match self.peek() {
                None => break,
                Some(';') => {
                    // Line comment
                    while !matches!(self.peek(), None | Some('\n')) {
                        self.advance();
                    }
                }
                Some('(') => { self.advance(); tokens.push(Token::LParen); }
                Some(')') => { self.advance(); tokens.push(Token::RParen); }
                Some('\'') => { self.advance(); tokens.push(Token::Quote); }
                Some('"') => {
                    self.advance(); // skip opening "
                    let mut s = String::new();
                    loop {
                        match self.advance() {
                            None | Some('"') => break,
                            Some('\\') => match self.advance() {
                                Some('n') => s.push('\n'),
                                Some('t') => s.push('\t'),
                                Some(c) => s.push(c),
                                None => break,
                            },
                            Some(c) => s.push(c),
                        }
                    }
                    tokens.push(Token::String(s));
                }
                Some('#') => {
                    self.advance();
                    match self.peek() {
                        Some('t') => { self.advance(); tokens.push(Token::Bool(true)); }
                        Some('f') => { self.advance(); tokens.push(Token::Bool(false)); }
                        _ => tokens.push(Token::Symbol("#".to_string())),
                    }
                }
                Some(c) => {
                    // Number: starts with digit, or '-' followed by a digit
                    let is_number_start = c.is_ascii_digit()
                        || (c == '-' && matches!(self.input.get(self.pos + 1), Some(d) if d.is_ascii_digit()));
                    if is_number_start {
                        let start = self.pos;
                        if c == '-' { self.advance(); }
                        while matches!(self.peek(), Some(d) if d.is_ascii_digit() || d == '.') {
                            self.advance();
                        }
                        let num_str: String = self.input[start..self.pos].iter().collect();
                        if let Ok(n) = num_str.parse::<f64>() {
                            tokens.push(Token::Number(n));
                        } else {
                            tokens.push(Token::Symbol(num_str));
                        }
                    } else {
                        // Symbol
                        let start = self.pos;
                        while let Some(sc) = self.peek() {
                            if sc.is_whitespace() || sc == '(' || sc == ')' || sc == '\'' || sc == '"' {
                                break;
                            }
                            self.advance();
                        }
                        let sym: String = self.input[start..self.pos].iter().collect();
                        if !sym.is_empty() {
                            tokens.push(Token::Symbol(sym));
                        }
                    }
                }
            }
        }
        tokens.push(Token::EOF);
        tokens
    }
}
