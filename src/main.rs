mod lexer;
mod parser;
mod env;
mod eval;

use lexer::Lexer;
use parser::Parser;
use env::{Env, EnvFrame, Value};
use eval::Evaluator;
use rustyline::DefaultEditor;

fn main() {
    println!("🦀 Rusty v0.10.0 — A Lisp in Rust");
    println!("   In memory of my brother.");
    println!("   Type (help) or 'quit' to exit.\n");

    let global = EnvFrame::new(None);
    let eval = Evaluator::new();
    setup_builtins(&global);
    load_stdlib(&global, &eval);

    // Run a file if passed as argument
    let args: Vec<String> = std::env::args().collect();
    if args.len() > 1 {
        let code = std::fs::read_to_string(&args[1])
            .unwrap_or_else(|e| { eprintln!("Error reading {}: {}", args[1], e); std::process::exit(1); });
        match run_code(&code, &global, &eval) {
            Ok(Value::Nil) | Ok(Value::Bool(false)) => {}
            Ok(v) => println!("{}", v),
            Err(e) => { eprintln!("Error: {}", e); std::process::exit(1); }
        }
        return;
    }

    // REPL
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
                            Ok(v)          => println!("=> {}", v),
                            Err(e)         => println!("Error: {}", e),
                        }
                        buffer.clear();
                    }
                    InputStatus::Incomplete => {} // keep buffering
                    InputStatus::Error(e) => {
                        println!("Syntax error: {}", e);
                        buffer.clear();
                    }
                }
            }
        }
    }
    println!("\nGoodbye.");
}

enum InputStatus {
    Complete,
    Incomplete,
    Error(String),
}

fn check_complete(text: &str) -> InputStatus {
    let mut depth: i32 = 0;
    let mut in_string = false;
    let mut escape = false;
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if in_string {
            if escape { escape = false; }
            else if c == '\\' { escape = true; }
            else if c == '"' { in_string = false; }
        } else {
            match c {
                '"' => in_string = true,
                ';' => { while i < chars.len() && chars[i] != '\n' { i += 1; } }
                '(' | '[' => depth += 1,
                ')' | ']' => {
                    depth -= 1;
                    if depth < 0 {
                        return InputStatus::Error("unmatched ')'".to_string());
                    }
                }
                _ => {}
            }
        }
        i += 1;
    }
    if in_string { return InputStatus::Error("unterminated string".to_string()); }
    if depth > 0 { InputStatus::Incomplete } else { InputStatus::Complete }
}


// ---- Value helpers ----

fn num2(args: &[Value]) -> Result<(f64, f64), String> {
    if args.len() != 2 {
        return Err(format!("Expected 2 args, got {}", args.len()));
    }
    match (&args[0], &args[1]) {
        (Value::Number(a), Value::Number(b)) => Ok((*a, *b)),
        _ => Err(format!("Expected numbers, got {} and {}", args[0], args[1])),
    }
}

fn nums(args: &[Value]) -> Result<Vec<f64>, String> {
    args.iter().map(|v| match v {
        Value::Number(n) => Ok(*n),
        _ => Err(format!("Expected number, got {}", v)),
    }).collect()
}

pub fn apply_value(f: &Value, args: &[Value], eval: &Evaluator) -> Result<Value, String> {
    match f {
        Value::Builtin(_, func) => func(args),
        Value::Lambda { params, rest, body, env } => {
            let child = EnvFrame::extend(env, params, rest, args.to_vec())?;
            let last = body.len() - 1;
            for e in &body[..last] { eval.eval(e, &child)?; }
            eval.eval(&body[last], &child)
        }
        _ => Err(format!("Not callable: {}", f)),
    }
}

pub fn value_equal(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x == y,
        (Value::Bool(x), Value::Bool(y)) => x == y,
        (Value::String(x), Value::String(y)) => x == y,
        (Value::Symbol(x), Value::Symbol(y)) => x == y,
        (Value::Nil, Value::Nil) => true,
        (Value::List(xs), Value::List(ys)) =>
            xs.len() == ys.len() && xs.iter().zip(ys).all(|(a,b)| value_equal(a,b)),
        _ => false,
    }
}

// ---- Builtins ----

fn setup_builtins(env: &Env) {
    macro_rules! b {
        ($name:expr, $f:expr) => {
            EnvFrame::set(env, $name.to_string(), Value::Builtin($name, $f));
        };
    }
    macro_rules! alias {
        ($from:expr, $to:expr) => {
            if let Some(v) = EnvFrame::get(env, $to) {
                EnvFrame::set(env, $from.to_string(), v);
            }
        };
    }

    // ---- Arithmetic (Scheme style) ----
    b!("+", |args| {
        if args.is_empty() { return Ok(Value::Number(0.0)); }
        Ok(Value::Number(nums(args)?.iter().sum()))
    });
    b!("-", |args| {
        if args.is_empty() { return Err("- requires at least 1 arg".into()); }
        let vs = nums(args)?;
        if vs.len() == 1 { return Ok(Value::Number(-vs[0])); }
        Ok(Value::Number(vs[0] - vs[1..].iter().sum::<f64>()))
    });
    b!("*", |args| {
        if args.is_empty() { return Ok(Value::Number(1.0)); }
        Ok(Value::Number(nums(args)?.iter().product()))
    });
    b!("/", |args| {
        if args.len() < 2 { return Err("/ requires at least 2 args".into()); }
        let vs = nums(args)?;
        if vs[1..].iter().any(|&x| x == 0.0) { return Err("Division by zero".into()); }
        Ok(Value::Number(vs[0] / vs[1..].iter().product::<f64>()))
    });
    b!("mod",      |args| { let (a,b)=num2(args)?; if b==0.0{return Err("mod: division by zero".into());} Ok(Value::Number(a%b)) });
    b!("expt",     |args| { let (a,b)=num2(args)?; Ok(Value::Number(a.powf(b))) });
    b!("abs",      |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Number(n.abs()))}else{Err("abs: not a number".into())} });
    b!("floor",    |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Number(n.floor()))}else{Err("floor: not a number".into())} });
    b!("ceiling",  |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Number(n.ceil()))}else{Err("ceiling: not a number".into())} });
    b!("round",    |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Number(n.round()))}else{Err("round: not a number".into())} });
    b!("sqrt",     |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Number(n.sqrt()))}else{Err("sqrt: not a number".into())} });
    b!("max", |args| { let vs=nums(args)?; Ok(Value::Number(vs.into_iter().fold(f64::NEG_INFINITY,f64::max))) });
    b!("min", |args| { let vs=nums(args)?; Ok(Value::Number(vs.into_iter().fold(f64::INFINITY,f64::min))) });

    // SimpleLisp-compatible arithmetic aliases
    alias!("add", "+");
    alias!("sub", "-");
    alias!("mul", "*");
    alias!("div", "/");

    // ---- Comparisons (Scheme style) ----
    b!("=",  |args| { let (a,b)=num2(args)?; Ok(Value::Bool(a==b)) });
    b!("<",  |args| { let (a,b)=num2(args)?; Ok(Value::Bool(a<b))  });
    b!(">",  |args| { let (a,b)=num2(args)?; Ok(Value::Bool(a>b))  });
    b!("<=", |args| { let (a,b)=num2(args)?; Ok(Value::Bool(a<=b)) });
    b!(">=", |args| { let (a,b)=num2(args)?; Ok(Value::Bool(a>=b)) });

    // SimpleLisp-compatible comparison aliases
    // eq uses Python == semantics — works on any type
    b!("eq", |args| {
        if args.len() != 2 { return Err("eq: 2 args".into()); }
        Ok(Value::Bool(value_equal(&args[0], &args[1])))
    });
    alias!("gt",  ">");
    alias!("lt",  "<");
    alias!("ge",  ">=");
    alias!("le",  "<=");
    b!("neq", |args| { let (a,b)=num2(args)?; Ok(Value::Bool(a!=b)) });

    b!("eq?", |args| {
        if args.len() != 2 { return Err("eq?: 2 args".into()); }
        let eq = match (&args[0], &args[1]) {
            (Value::Number(a), Value::Number(b)) => a == b,
            (Value::Bool(a),   Value::Bool(b))   => a == b,
            (Value::Nil,       Value::Nil)        => true,
            (Value::Symbol(a), Value::Symbol(b))  => a == b,
            (Value::String(a), Value::String(b))  => a == b,
            (Value::List(a),   Value::List(b))    => a.len()==0 && b.len()==0,
            _ => false,
        };
        Ok(Value::Bool(eq))
    });
    b!("equal?", |args| {
        if args.len() != 2 { return Err("equal?: 2 args".into()); }
        Ok(Value::Bool(value_equal(&args[0], &args[1])))
    });
    b!("not", |args| {
        if args.len() != 1 { return Err("not: 1 arg".into()); }
        Ok(Value::Bool(matches!(args[0], Value::Bool(false) | Value::Nil)))
    });
    b!("zero?",     |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Bool(*n==0.0))}else{Err("zero?: not a number".into())} });
    b!("positive?", |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Bool(*n>0.0))}else{Err("positive?: not a number".into())} });
    b!("negative?", |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Bool(*n<0.0))}else{Err("negative?: not a number".into())} });
    b!("odd?",      |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Bool((*n as i64)%2!=0))}else{Err("odd?: not a number".into())} });
    b!("even?",     |args| { if let Some(Value::Number(n))=args.first(){Ok(Value::Bool((*n as i64)%2==0))}else{Err("even?: not a number".into())} });

    // ---- List ops ----
    b!("cons", |args| {
        if args.len() != 2 { return Err("cons: 2 args".into()); }
        match &args[1] {
            Value::List(xs) => { let mut v=vec![args[0].clone()]; v.extend_from_slice(xs); Ok(Value::List(v)) }
            Value::Nil      => Ok(Value::List(vec![args[0].clone()])),
            _               => Ok(Value::List(vec![args[0].clone(), args[1].clone()])),
        }
    });
    b!("car", |args| {
        match args.first() {
            Some(Value::List(xs)) if !xs.is_empty() => Ok(xs[0].clone()),
            _ => Err("car: not a non-empty list".into()),
        }
    });
    b!("cdr", |args| {
        match args.first() {
            Some(Value::List(xs)) if !xs.is_empty() => Ok(Value::List(xs[1..].to_vec())),
            Some(Value::List(_)) => Ok(Value::Nil),
            _ => Err("cdr: not a list".into()),
        }
    });
    b!("list",    |args| Ok(Value::List(args.to_vec())));
    b!("null?",   |args| Ok(Value::Bool(match args.first() {
        Some(Value::Nil) => true,
        Some(Value::List(v)) => v.is_empty(),
        _ => false,
    })));
    b!("pair?",   |args| Ok(Value::Bool(matches!(args.first(), Some(Value::List(v)) if !v.is_empty()))));
    b!("list?",   |args| Ok(Value::Bool(matches!(args.first(), Some(Value::List(_))|Some(Value::Nil)))));
    b!("length",  |args| {
        match args.first() {
            Some(Value::List(xs)) => Ok(Value::Number(xs.len() as f64)),
            Some(Value::Nil)      => Ok(Value::Number(0.0)),
            _ => Err("length: not a list".into()),
        }
    });
    b!("append", |args| {
        let mut result = Vec::new();
        for a in args {
            match a {
                Value::List(xs) => result.extend_from_slice(xs),
                Value::Nil => {}
                _ => return Err("append: not a list".into()),
            }
        }
        Ok(Value::List(result))
    });
    b!("reverse", |args| {
        match args.first() {
            Some(Value::List(xs)) => { let mut v=xs.clone(); v.reverse(); Ok(Value::List(v)) }
            Some(Value::Nil)      => Ok(Value::Nil),
            _ => Err("reverse: not a list".into()),
        }
    });
    b!("nth", |args| {
        if args.len() != 2 { return Err("nth: 2 args (list index)".into()); }
        match (&args[0], &args[1]) {
            (Value::List(xs), Value::Number(i)) => {
                let idx = *i as usize;
                xs.get(idx).cloned().ok_or_else(|| format!("nth: index {} out of range", idx))
            }
            _ => Err("nth: (list index) expected".into()),
        }
    });
    b!("member", |args| {
        if args.len() != 2 { return Err("member: 2 args".into()); }
        match &args[1] {
            Value::List(xs) => Ok(Value::Bool(xs.iter().any(|x| value_equal(x, &args[0])))),
            _ => Err("member: second arg must be a list".into()),
        }
    });
    b!("list-tail", |args| {
        if args.len() != 2 { return Err("list-tail: 2 args".into()); }
        match (&args[0], &args[1]) {
            (Value::List(xs), Value::Number(n)) => Ok(Value::List(xs[*n as usize..].to_vec())),
            _ => Err("list-tail: expected list and number".into()),
        }
    });

    // Higher-order
    b!("map", |args| {
        if args.len() != 2 { return Err("map: 2 args".into()); }
        let xs = match &args[1] {
            Value::List(xs) => xs.clone(),
            Value::Nil      => return Ok(Value::List(vec![])),
            _ => return Err("map: second arg must be a list".into()),
        };
        let eval = Evaluator::new();
        let result: Result<Vec<Value>, _> = xs.iter()
            .map(|x| apply_value(&args[0], &[x.clone()], &eval))
            .collect();
        Ok(Value::List(result?))
    });
    b!("filter", |args| {
        if args.len() != 2 { return Err("filter: 2 args".into()); }
        let xs = match &args[1] {
            Value::List(xs) => xs.clone(),
            Value::Nil      => return Ok(Value::List(vec![])),
            _ => return Err("filter: second arg must be a list".into()),
        };
        let eval = Evaluator::new();
        let mut result = Vec::new();
        for x in xs {
            if !matches!(apply_value(&args[0], &[x.clone()], &eval)?, Value::Bool(false)|Value::Nil) {
                result.push(x);
            }
        }
        Ok(Value::List(result))
    });
    b!("for-each", |args| {
        if args.len() != 2 { return Err("for-each: 2 args".into()); }
        let xs = match &args[1] {
            Value::List(xs) => xs.clone(),
            _ => return Err("for-each: second arg must be a list".into()),
        };
        let eval = Evaluator::new();
        for x in xs { apply_value(&args[0], &[x], &eval)?; }
        Ok(Value::Nil)
    });
    b!("foldl", |args| {
        if args.len() != 3 { return Err("foldl: 3 args".into()); }
        let xs = match &args[2] {
            Value::List(xs) => xs.clone(),
            _ => return Err("foldl: third arg must be a list".into()),
        };
        let eval = Evaluator::new();
        let mut acc = args[1].clone();
        for x in xs { acc = apply_value(&args[0], &[x, acc], &eval)?; }
        Ok(acc)
    });
    b!("foldr", |args| {
        if args.len() != 3 { return Err("foldr: 3 args".into()); }
        let xs = match &args[2] {
            Value::List(xs) => xs.clone(),
            _ => return Err("foldr: third arg must be a list".into()),
        };
        let eval = Evaluator::new();
        let mut acc = args[1].clone();
        for x in xs.into_iter().rev() { acc = apply_value(&args[0], &[x, acc], &eval)?; }
        Ok(acc)
    });
    b!("apply", |args| {
        if args.len() < 2 { return Err("apply: needs function and args-list".into()); }
        let last = args.last().unwrap();
        let mut call_args: Vec<Value> = args[1..args.len()-1].to_vec();
        match last {
            Value::List(xs) => call_args.extend_from_slice(xs),
            Value::Nil      => {}
            _ => return Err("apply: last arg must be a list".into()),
        }
        let eval = Evaluator::new();
        apply_value(&args[0], &call_args, &eval)
    });

    // ---- Type predicates ----
    b!("number?",    |args| Ok(Value::Bool(matches!(args.first(), Some(Value::Number(_))))));
    b!("string?",    |args| Ok(Value::Bool(matches!(args.first(), Some(Value::String(_))))));
    b!("boolean?",   |args| Ok(Value::Bool(matches!(args.first(), Some(Value::Bool(_))))));
    b!("symbol?",    |args| Ok(Value::Bool(matches!(args.first(), Some(Value::Symbol(_))))));
    b!("nil?",       |args| Ok(Value::Bool(match args.first() {
        Some(Value::Nil) => true,
        Some(Value::List(v)) => v.is_empty(),
        _ => false,
    })));
    b!("procedure?", |args| Ok(Value::Bool(matches!(args.first(),
        Some(Value::Builtin(..))|Some(Value::Lambda{..})|Some(Value::Macro{..})))));
    b!("macro?", |args| Ok(Value::Bool(matches!(args.first(), Some(Value::Macro{..})))));

    // ---- String ops ----
    b!("string-length",  |args| {
        if let Some(Value::String(s))=args.first(){Ok(Value::Number(s.chars().count() as f64))}
        else{Err("string-length: not a string".into())}
    });
    b!("string-append", |args| {
        let mut out = String::new();
        for a in args {
            match a {
                Value::String(s) => out.push_str(s),
                _ => return Err(format!("string-append: not a string: {}", a)),
            }
        }
        Ok(Value::String(out))
    });
    b!("substring", |args| {
        if args.len() < 2 { return Err("substring: needs string start [end]".into()); }
        if let Value::String(s) = &args[0] {
            let chars: Vec<char> = s.chars().collect();
            let start = match &args[1] { Value::Number(n) => *n as usize, _ => return Err("substring: start must be number".into()) };
            let end   = if args.len() > 2 { match &args[2] { Value::Number(n) => *n as usize, _ => return Err("substring: end must be number".into()) } } else { chars.len() };
            Ok(Value::String(chars[start..end].iter().collect()))
        } else { Err("substring: not a string".into()) }
    });
    b!("string-ref", |args| {
        if args.len() != 2 { return Err("string-ref: 2 args".into()); }
        if let (Value::String(s), Value::Number(i)) = (&args[0], &args[1]) {
            let c = s.chars().nth(*i as usize).ok_or("string-ref: index out of range")?;
            Ok(Value::String(c.to_string()))
        } else { Err("string-ref: expected string and number".into()) }
    });
    b!("string=?", |args| {
        if args.len() != 2 { return Err("string=?: 2 args".into()); }
        match (&args[0], &args[1]) {
            (Value::String(a), Value::String(b)) => Ok(Value::Bool(a==b)),
            _ => Err("string=?: expected strings".into()),
        }
    });
    b!("number->string", |args| {
        if let Some(Value::Number(n))=args.first(){Ok(Value::String(format_number(*n)))}
        else{Err("number->string: not a number".into())}
    });
    b!("string->number", |args| {
        if let Some(Value::String(s))=args.first(){
            match s.parse::<f64>(){Ok(n)=>Ok(Value::Number(n)),Err(_)=>Ok(Value::Bool(false))}
        }else{Err("string->number: not a string".into())}
    });
    b!("symbol->string", |args| {
        if let Some(Value::Symbol(s))=args.first(){Ok(Value::String(s.clone()))}
        else{Err("symbol->string: not a symbol".into())}
    });
    b!("string->symbol", |args| {
        if let Some(Value::String(s))=args.first(){Ok(Value::Symbol(s.clone()))}
        else{Err("string->symbol: not a string".into())}
    });
    b!("string->list", |args| {
        if let Some(Value::String(s))=args.first(){
            Ok(Value::List(s.chars().map(|c| Value::String(c.to_string())).collect()))
        }else{Err("string->list: not a string".into())}
    });

    // ---- String Interpolation (NEW in v0.10) ----
    // Option 1: Simple variadic str function
    // (str "Hello" name "you are" age) → "Hello<value of name>you are<value of age>"
    b!("str", |args| {
        let mut result = String::new();
        for arg in args {
            match arg {
                Value::String(s) => result.push_str(s),
                Value::Number(n) => result.push_str(&format_number(*n)),
                Value::Bool(b) => result.push_str(if *b { "#t" } else { "#f" }),
                Value::Nil => result.push_str("()"),
                Value::Symbol(s) => result.push_str(s),
                Value::List(xs) => {
                    result.push('(');
                    for (i, v) in xs.iter().enumerate() {
                        if i > 0 { result.push(' '); }
                        result.push_str(&v.to_string());
                    }
                    result.push(')');
                }
                Value::Builtin(name, _) => result.push_str(&format!("#<builtin:{}>", name)),
                Value::Lambda { .. } => result.push_str("#<lambda>"),
                Value::Macro { .. } => result.push_str("#<macro>"),
            }
        }
        Ok(Value::String(result))
    });

    // ---- Math extras ----
    b!("gcd", |args| {
        fn gcd(a: u64, b: u64) -> u64 { if b==0{a}else{gcd(b,a%b)} }
        let vs = nums(args)?;
        if vs.len() < 2 { return Err("gcd: 2+ args".into()); }
        let result = vs.iter().map(|&n| n.abs() as u64).reduce(gcd).unwrap_or(0);
        Ok(Value::Number(result as f64))
    });

    // ---- I/O ----
    b!("display", |args| {
        for a in args { match a { Value::String(s) => print!("{}", s), other => print!("{}", other) } }
        Ok(Value::Nil)
    });
    b!("newline", |_| { println!(); Ok(Value::Nil) });
    b!("print",   |args| {
        let parts: Vec<String> = args.iter().map(print_repr).collect();
        println!("{}", parts.join(" "));
        Ok(Value::Nil)
    });
    b!("error",   |args| {
        let msg = args.iter().map(|v| format!("{}", v)).collect::<Vec<_>>().join(" ");
        Err(msg)
    });

    // ---- nil ----
    b!("nil", |_| Ok(Value::Nil));

    // ---- Help ----
    b!("help", |_| {
        println!("Rusty v0.10.0 — SimpleLisp-compatible Lisp in Rust");
        println!();
        println!("Special forms:");
        println!("  (define name expr)          bind name to value");
        println!("  (define (f params) body...)  define a function");
        println!("  (def name (params) body...)  SimpleLisp-style define");
        println!("  (set! name val)              mutate existing binding");
        println!("  (set name val)               create-or-update binding");
        println!("  (lambda (params) body...)    anonymous function");
        println!("  (if test then else)          conditional");
        println!("  (cond (test expr)...)        multi-branch");
        println!("  (let ((x v)) body)           local binding");
        println!("  (let* ((x v)) body)          sequential let");
        println!("  (letrec ((x v)) body)        recursive let");
        println!("  (begin e1 e2 ...)            sequence");
        println!("  (and ...) (or ...)           short-circuit logic");
        println!("  (quote x)  'x               literal data");
        println!();
        println!("Arithmetic: + - * / mod expt abs sqrt floor ceiling round max min");
        println!("Aliases:    add sub mul div eq gt lt ge le neq");
        println!("Compare:    = < > <= >= eq? equal? not zero? positive? negative?");
        println!("Lists:      cons car cdr list null? pair? length append reverse");
        println!("            nth member list-tail map filter foldl foldr for-each apply");
        println!("Strings:    str string-length string-append substring string-ref string=?");
        println!("            number->string string->number symbol->string");
        println!("Types:      number? string? boolean? symbol? list? procedure? nil?");
        println!("I/O:        display newline print error");
        Ok(Value::Nil)
    });

    // ---- Macro utilities ----
    b!("gensym", |args| {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let prefix = match args.first() {
            Some(Value::String(s)) | Some(Value::Symbol(s)) => s.clone(),
            _ => "g".to_string(),
        };
        Ok(Value::Symbol(format!("{}__{}", prefix, n)))
    });
}

fn run_code(input: &str, env: &Env, eval: &Evaluator) -> Result<Value, String> {
    let tokens = Lexer::new(input).tokenize();
    let ast    = Parser::new(tokens).parse();
    eval.eval_all(&ast, env)
}

fn load_stdlib(env: &Env, eval: &Evaluator) {
    // Try external std.lisp first (allows user customisation)
    for path in &["std.lisp", "/usr/local/share/rusty/std.lisp"] {
        if let Ok(code) = std::fs::read_to_string(path) {
            if let Err(e) = run_code(&code, env, eval) {
                eprintln!("Warning: stdlib error in {}: {}", path, e);
            }
            return;
        }
    }
    // Embedded fallback
    if let Err(e) = run_code(STDLIB, env, eval) {
        eprintln!("Warning: embedded stdlib error: {}", e);
    }
}

const STDLIB: &str = include_str!("../std.lisp");

fn format_number(n: f64) -> String {
    if n.fract() == 0.0 && n.abs() < 1e15 { format!("{}", n as i64) }
    else { format!("{}", n) }
}

// Print a value the way Python's str() does — strings unquoted, lists without quotes on elements
fn print_repr(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::List(xs) => {
            let inner: Vec<String> = xs.iter().map(print_repr).collect();
            format!("({})", inner.join(" "))
        }
        other => format!("{}", other),
    }
}
