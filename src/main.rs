use std::io::{self, Write};
 

mod lexer;
mod parser;
mod env;
mod eval;

use lexer::Lexer;
use parser::{Parser, Expr};
use env::{Environment, Value};
use eval::Evaluator;

fn main() {
    println!("🚀 SimpleLisp Rust v0.7 - TCO, Hygienic Macros, Full Features");
    println!("REPL Ready. Type expressions or 'quit' to exit.\n");

    let mut env = Environment::new();
    let mut evaluator = Evaluator::new();

    // Setup basic builtins
    setup_builtins(&mut env);

    loop {
        print!("lisp> ");
        io::stdout().flush().unwrap();

        let mut line = String::new();
        if io::stdin().read_line(&mut line).is_err() {
            break;
        }

        let line = line.trim();
        if line == "quit" || line == "exit" {
            break;
        }
        if line.is_empty() {
            continue;
        }

        match evaluate_line(line, &mut env, &mut evaluator) {
            Ok(result) => println!("=> {:?}", result),
            Err(e) => println!("Error: {}", e),
        }
    }
    println!("\nGoodbye!");
}

fn setup_builtins(env: &mut Environment) {
    env.set("add".to_string(), Value::Function(|args| {
        if args.len() == 2 {
            if let (Value::Number(a), Value::Number(b)) = (&args[0], &args[1]) {
                Ok(Value::Number(a + b))
            } else {
                Err("add: expected numbers".to_string())
            }
        } else {
            Err("add expects 2 args".to_string())
        }
    }));
    // Add more builtins as needed
    println!("Basic builtins loaded (add, etc.)");
}

fn evaluate_line(line: &str, env: &mut Environment, evaluator: &mut Evaluator) -> Result<Value, String> {
    let mut lexer = Lexer::new(line);
    let tokens = lexer.tokenize();
    let mut parser = Parser::new(tokens);
    let ast = parser.parse();
    evaluator.eval_all(&ast, env)
}