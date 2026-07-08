mod lexer;
mod parser;
mod env;
mod eval;
mod interp;
mod arena;
mod rust_jit;
mod graph_ir;
mod type_check;
mod effect_check;

use env::Value;
use eval::Evaluator;
use interp::{make_env, run_code, print_repr};
use rustyline::DefaultEditor;

fn main() {
    let global = make_env();
    let eval   = Evaluator::new();

    // File mode
    let args: Vec<String> = std::env::args().collect();
    if args.len() > 1 {
        let code = std::fs::read_to_string(&args[1])
            .unwrap_or_else(|e| { eprintln!("Error reading {}: {}", args[1], e); std::process::exit(1); });
        match run_code(&code, &global, &eval) {
            Ok(Value::Nil) | Ok(Value::Bool(false)) => {}
            Ok(v)  => println!("{}", print_repr(&v)),
            Err(e) => { eprintln!("Error: {}", e); std::process::exit(1); }
        }
        return;
    }

    // REPL
    println!("☯ Rusty v0.10.0 — A Lisp in Rust");
    println!("   In memory of my brother.");
    println!("   Type (help) or 'quit' to exit.\n");
    let mut rl = DefaultEditor::new().unwrap();
    let mut buffer = String::new();

    loop {
        let prompt = if buffer.is_empty() { "rusty> " } else { "  ...> " };
        match rl.readline(prompt) {
            Err(_) => break,
            Ok(line) => {
                if buffer.is_empty() {
                    let trimmed = line.trim();
                    if trimmed.is_empty() { continue; }
                    if trimmed == "quit" || trimmed == "exit" { break; }
                }
                if !buffer.is_empty() { buffer.push('\n'); }
                buffer.push_str(&line);
                match check_complete(&buffer) {
                    InputStatus::Complete => {
                        let _ = rl.add_history_entry(&buffer);
                        match run_code(&buffer, &global, &eval) {
                            Ok(Value::Nil) => {}
                            Ok(v)          => println!("=> {}", print_repr(&v)),
                            Err(e)         => println!("Error: {}", e),
                        }
                        buffer.clear();
                    }
                    InputStatus::Incomplete => {}
                    InputStatus::Error(e)   => { println!("Syntax error: {}", e); buffer.clear(); }
                }
            }
        }
    }
    println!("\nGoodbye.");
}

enum InputStatus { Complete, Incomplete, Error(String) }

fn check_complete(text: &str) -> InputStatus {
    let mut depth: i32 = 0;
    let mut in_string   = false;
    let mut escape      = false;
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if in_string {
            if escape { escape = false; }
            else if c == '\\' { escape = true; }
            else if c == '"'  { in_string = false; }
        } else {
            match c {
                '"'      => in_string = true,
                ';'      => { while i < chars.len() && chars[i] != '\n' { i += 1; } }
                '('|'['  => depth += 1,
                ')'|']'  => {
                    depth -= 1;
                    if depth < 0 { return InputStatus::Error("unmatched ')'".to_string()); }
                }
                _ => {}
            }
        }
        i += 1;
    }
    if in_string   { return InputStatus::Error("unterminated string".to_string()); }
    if depth > 0   { InputStatus::Incomplete } else { InputStatus::Complete }
}
