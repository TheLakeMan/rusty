// Copyright (c) 2026 Nicholas Vermeulen
// SPDX-License-Identifier: AGPL-3.0-or-later

mod lexer;
mod parser;
mod resolve;
mod env;
mod eval;
mod interp;
mod arena;
mod rust_jit;
mod graph_ir;
mod checkpoint;
mod trace;
mod type_check;
mod effect_check;
mod kg;

use env::Value;
use eval::Evaluator;
use interp::{make_env, run_code, print_repr};
use rustyline::DefaultEditor;

/// Append this process's exercised-command names to $RUSTY_COVERAGE_FILE, one
/// per line. Each golden test runs in its own process, so the coverage pass in
/// run_tests.sh accumulates the union across the suite in a single file.
fn dump_coverage() {
    if !trace::coverage_enabled() { return; }   // never touch the file when off
    let path = match std::env::var("RUSTY_COVERAGE_FILE") { Ok(p) => p, Err(_) => return };
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        for n in trace::coverage_names() { let _ = writeln!(f, "{}", n); }
    }
}

fn main() {
    // The Rc-based core recurses on the native stack for non-tail eval,
    // recursive parsing, and value display; without a guard, deep enough input
    // *aborts* the process (a Rust stack overflow can't be caught). We run on
    // the main thread (its stack grows on demand up to `ulimit -s`, and staying
    // off a spawned thread avoids that thread's slower TLS on the eval hot path)
    // and size the recursion guard to that limit — so anything past the stack
    // budget becomes a clean raised error, never a core dump. `ulimit -s` is the
    // knob for how deep recursion may go.
    eval::set_interp_stack(eval::native_stack_limit_bytes());
    run_cli();
}

fn run_cli() {
    let global = make_env();
    let eval   = Evaluator::new();

    // File mode
    let args: Vec<String> = std::env::args().collect();
    if args.len() > 1 {
        let code = std::fs::read_to_string(&args[1])
            .unwrap_or_else(|e| { eprintln!("Error reading {}: {}", args[1], e); std::process::exit(1); });
        // Coverage mode is armed HERE, after make_env() — so std.lisp's own
        // bootstrap doesn't get to mark commands "covered" that no test ever
        // exercised. Coverage measures what the script runs, nothing else.
        if std::env::var("RUSTY_COVERAGE").is_ok() { trace::coverage_set_enabled(true); }
        let result = run_code(&code, &global, &eval);
        dump_coverage();   // before any exit path, so a failing script still reports
        match result {
            Ok(Value::Nil) | Ok(Value::Bool(false)) => {}
            Ok(v)  => println!("{}", print_repr(&v)),
            Err(e) => { eprintln!("Error: {}", e); std::process::exit(1); }
        }
        return;
    }

    // REPL
    println!("☯ Rusty v{} — A Lisp in Rust", env!("CARGO_PKG_VERSION"));
    println!("   In memory of my brother.");
    println!("   Type (help) or 'quit' to exit.\n");
    let mut rl = DefaultEditor::new().unwrap();
    let mut buffer = String::new();

    loop {
        let prompt = if buffer.is_empty() { "rusty> " } else { "  ...> " };
        match rl.readline(prompt) {
            Err(_) => break,
            Ok(mut line) => {
                if buffer.is_empty() {
                    let trimmed = line.trim();
                    if trimmed.is_empty() { continue; }
                    if trimmed == "quit" || trimmed == "exit" { break; }
                    // `/foo` in the REPL is sugar for (apropos "foo").
                    if let Some(q) = trimmed.strip_prefix('/') {
                        line = format!("(apropos \"{}\")", q.trim().replace('"', ""));
                    }
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
