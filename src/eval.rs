use crate::parser::Expr;
use crate::env::{Env, EnvFrame, Value};
use reqwest::Client;
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize)]
struct ChatMessage {
    role: String,
    content: String,
}

#[derive(Serialize)]
struct ChatRequest {
    model: String,
    messages: Vec<ChatMessage>,
    temperature: f32,
    max_tokens: Option<u32>,
}

#[derive(Deserialize)]
struct ChatChoice {
    message: ChatMessage,
}

#[derive(Deserialize)]
struct ChatResponse {
    choices: Vec<ChatChoice>,
}

pub struct Evaluator;

impl Evaluator {
    pub fn new() -> Self { Evaluator }

    // ── LLM Builtin ───────────────────────────────────────────────────────
    async fn call_llm(prompt: &str, temperature: f32, max_tokens: Option<u32>) -> Result<String, String> {
        let client = Client::new();

        let request = ChatRequest {
            model: "local".to_string(),
            messages: vec![ChatMessage {
                role: "user".to_string(),
                content: prompt.to_string(),
            }],
            temperature,
            max_tokens,
        };

        let response = client
            .post("http://localhost:8080/v1/chat/completions")
            .json(&request)
            .send()
            .await
            .map_err(|e| e.to_string())?
            .json::<ChatResponse>()
            .await
            .map_err(|e| e.to_string())?;

        response.choices
            .first()
            .map(|c| c.message.content.clone())
            .ok_or_else(|| "No response from LLM".to_string())
    }

    pub fn eval_all(&self, ast: &[Expr], env: &Env) -> Result<Value, String> {
        let mut result = Value::Nil;
        for expr in ast { result = self.eval(expr, env)?; }
        Ok(result)
    }

    pub fn eval(&self, expr: &Expr, env: &Env) -> Result<Value, String> {
        let mut cur = expr.clone();
        let mut env = env.clone();

        loop {
            match &cur {
                Expr::Number(n) => return Ok(Value::Number(*n)),
                Expr::Bool(b)   => return Ok(Value::Bool(*b)),
                Expr::String(s) => return Ok(Value::String(s.clone())),
                Expr::Nil       => return Ok(Value::Nil),

                Expr::Symbol(s) => {
                    return EnvFrame::get(&env, s)
                        .ok_or_else(|| format!("Undefined: '{}'", s));
                }

                Expr::List(list) => {
                    if list.is_empty() { return Ok(Value::Nil); }

                    if let Expr::Symbol(head) = &list[0] {
                        match head.as_str() {

                            // ── LLM Call ─────────────────────────────────
                            "llm" => {
                                if list.len() < 2 {
                                    return Err("(llm prompt [temperature] [max-tokens])".into());
                                }
                                let prompt = match self.eval(&list[1], &env)? {
                                    Value::String(s) => s,
                                    _ => return Err("llm: prompt must be a string".into()),
                                };
                                let temp = if list.len() > 2 {
                                    match self.eval(&list[2], &env)? {
                                        Value::Number(n) => n as f32,
                                        _ => 0.7,
                                    }
                                } else { 0.7 };
                                let max_t = if list.len() > 3 {
                                    match self.eval(&list[3], &env)? {
                                        Value::Number(n) => Some(n as u32),
                                        _ => None,
                                    }
                                } else { None };

                                let result = tokio::runtime::Runtime::new()
                                    .unwrap()
                                    .block_on(Self::call_llm(&prompt, temp, max_t));

                                return result.map(Value::String);
                            }

                            // ── deftool ───────────────────────────────────
                            "deftool" => {
                                if list.len() < 4 {
                                    return Err("deftool: (deftool name (params) \"description\" body...)".into());
                                }
                                let name = sym_name(&list[1], "deftool")?;
                                let params = match &list[2] {
                                    Expr::List(ps) => ps.iter().map(|p| sym_name(p, "deftool param"))
                                        .collect::<Result<Vec<_>, _>>()?,
                                    _ => return Err("deftool: params must be a list".into()),
                                };
                                let description = match self.eval(&list[3], &env)? {
                                    Value::String(s) => s,
                                    _ => return Err("deftool: description must be a string".into()),
                                };
                                let body = list[4..].to_vec();
                                EnvFrame::set(&env, name.clone(), Value::Tool {
                                    name, description, params, body, env: env.clone(),
                                });
                                return Ok(Value::Nil);
                            }

                            // ── tool-call ─────────────────────────────────
                            "tool-call" => {
                                if list.len() < 2 {
                                    return Err("tool-call: (tool-call \"name\" args...)".into());
                                }
                                let name = match self.eval(&list[1], &env)? {
                                    Value::String(s) => s,
                                    Value::Symbol(s) => s,
                                    _ => return Err("tool-call: name must be a string".into()),
                                };
                                let args: Result<Vec<Value>, _> = list[2..]
                                    .iter().map(|a| self.eval(a, &env)).collect();
                                let args = args?;
                                match EnvFrame::get(&env, &name) {
                                    Some(Value::Tool { params, body, env: tenv, .. }) => {
                                        let child = EnvFrame::new(Some(tenv.clone()));
                                        for (p, a) in params.iter().zip(args.iter()) {
                                            EnvFrame::set(&child, p.clone(), a.clone());
                                        }
                                        let last = body.len() - 1;
                                        for e in &body[..last] { self.eval(e, &child)?; }
                                        return self.eval(&body[last], &child);
                                    }
                                    Some(Value::Builtin(_, f)) => return f(&args),
                                    Some(Value::Lambda { params, rest, body, env: lenv }) => {
                                        let child = EnvFrame::extend(&lenv, &params, &rest, args)?;
                                        let last = body.len() - 1;
                                        for e in &body[..last] { self.eval(e, &child)?; }
                                        return self.eval(&body[last], &child);
                                    }
                                    _ => return Err(format!("Unknown tool: {}", name)),
                                }
                            }

                            // ── list-tools ─────────────────────────────────
                            "list-tools" => {
                                let mut tools = Vec::new();
                                fn collect_tools(env: &Env, out: &mut Vec<Value>) {
                                    let frame = env.borrow();
                                    for (name, v) in &frame.vars {
                                        if let Value::Tool { description, params, .. } = v {
                                            out.push(Value::List(vec![
                                                Value::Symbol(name.clone()),
                                                Value::String(description.clone()),
                                                Value::List(params.iter().map(|p| Value::Symbol(p.clone())).collect()),
                                            ]));
                                        }
                                    }
                                    if let Some(ref parent) = frame.parent {
                                        collect_tools(parent, out);
                                    }
                                }
                                collect_tools(&env, &mut tools);
                                return Ok(Value::List(tools));
                            }

                            // ── react-loop goal max-steps) ────────────────────
                            // ReAct: Reason → Act → Observe loop
                            // The LLM reasons about which tool to call,
                            // Rusty executes it, result feeds back to LLM.
                            "react-loop" => {
                                if list.len() < 2 {
                                    return Err("react-loop: (react-loop goal [max-steps])".into());
                                }
                                let goal = match self.eval(&list[1], &env)? {
                                    Value::String(s) => s,
                                    other => format!("{}", other),
                                };
                                let max_steps = if list.len() > 2 {
                                    match self.eval(&list[2], &env)? {
                                        Value::Number(n) => n as usize,
                                        _ => 10,
                                    }
                                } else { 10 };

                                // Build tool descriptions for system prompt — walk full env chain
                                let mut tool_descs = String::new();
                                {
                                    let mut scan_env = env.clone();
                                    loop {
                                        let frame = scan_env.borrow();
                                        for (_, v) in &frame.vars {
                                            if let Value::Tool { name, description, params, .. } = v {
                                                if !tool_descs.contains(&format!("- {}", name)) {
                                                    tool_descs.push_str(&format!(
                                                        "- {}{}: {}\n",
                                                        name,
                                                        if params.is_empty() { String::new() }
                                                        else { format!("({})", params.join(", ")) },
                                                        description
                                                    ));
                                                }
                                            }
                                        }
                                        let parent = frame.parent.clone();
                                        drop(frame);
                                        match parent {
                                            Some(p) => scan_env = p,
                                            None => break,
                                        }
                                    }
                                }

                                let system = format!(
                                    "You are an AI agent. Complete the goal using available tools.\n\
                                     Available tools:\n{}\n\
                                     To use a tool, respond with:\n\
                                     ACTION: tool-name\nINPUT: argument\n\n\
                                     When done, respond with:\n\
                                     FINAL: your answer",
                                    tool_descs
                                );

                                let mut history = format!("Goal: {}\n", goal);
                                let mut last_result = Value::Nil;

                                for step in 0..max_steps {
                                    let prompt = format!("{}\nStep {}:", history, step + 1);
                                    let full_prompt = format!("{}\n\n{}", system, prompt);

                                    let response = tokio::runtime::Runtime::new()
                                        .unwrap()
                                        .block_on(Self::call_llm(&full_prompt, 0.3, Some(200)));

                                    let response = match response {
                                        Ok(r) => r,
                                        Err(e) => return Err(format!("react-loop: LLM error: {}", e)),
                                    };

                                    // Parse ACTION / FINAL from response
                                    if response.contains("FINAL:") {
                                        if let Some(ans) = response.split("FINAL:").nth(1) {
                                            last_result = Value::String(ans.trim().to_string());
                                            break;
                                        }
                                    } else if response.contains("ACTION:") {
                                        let action = response.split("ACTION:").nth(1)
                                            .unwrap_or("").lines().next().unwrap_or("").trim();
                                        let input = response.split("INPUT:").nth(1)
                                            .unwrap_or("").lines().next().unwrap_or("").trim();

                                        // Try to call the tool
                                        let obs = match EnvFrame::get(&env, action) {
                                            Some(Value::Tool { params, body, env: tenv, .. }) => {
                                                let child = EnvFrame::new(Some(tenv.clone()));
                                                if !params.is_empty() {
                                                    EnvFrame::set(&child, params[0].clone(),
                                                        Value::String(input.to_string()));
                                                }
                                                let last = body.len() - 1;
                                                for e in &body[..last] { let _ = self.eval(e, &child); }
                                                match self.eval(&body[last], &child) {
                                                    Ok(v) => format!("{}", v),
                                                    Err(e) => format!("Error: {}", e),
                                                }
                                            }
                                            _ => format!("Unknown tool: {}", action),
                                        };

                                        history.push_str(&format!(
                                            "\nStep {}: ACTION={} INPUT={}\nOBSERVATION: {}\n",
                                            step + 1, action, input, obs
                                        ));
                                        last_result = Value::String(obs);
                                    } else {
                                        // Pure reasoning step
                                        history.push_str(&format!("\nThought: {}\n", response.trim()));
                                    }
                                }

                                return Ok(last_result);
                            }

                            // ── (load "file.lisp") ──────────────────────
                            "load" | "load-relative" => {
                                if list.len() != 2 {
                                    return Err(format!("{}: expects a filename", head));
                                }
                                let path_val = self.eval(&list[1], &env)?;
                                let path_str = match &path_val {
                                    Value::String(s) => s.clone(),
                                    _ => return Err(format!("{}: filename must be a string", head)),
                                };
                                let code = std::fs::read_to_string(&path_str)
                                    .map_err(|e| format!("load: cannot read '{}': {}", path_str, e))?;
                                let tokens = crate::lexer::Lexer::new(&code).tokenize();
                                let ast    = crate::parser::Parser::new(tokens).parse();
                                return self.eval_all(&ast, &env);
                            }

                            // ── (try-catch body (err) handler) ──────────
                            "try-catch" => {
                                if list.len() < 4 {
                                    return Err("try-catch: (try-catch body (err) handler)".into());
                                }
                                match self.eval(&list[1], &env) {
                                    Ok(v) => return Ok(v),
                                    Err(e) => {
                                        let catch_env = EnvFrame::new(Some(env.clone()));
                                        if let Expr::List(vars) = &list[2] {
                                            if let Some(Expr::Symbol(name)) = vars.first() {
                                                EnvFrame::set(&catch_env, name.clone(),
                                                    Value::String(e));
                                            }
                                        }
                                        cur = list[3].clone();
                                        env = catch_env;
                                        continue;
                                    }
                                }
                            }

                            // ── (match expr (pat body)...) ───────────────
                            "match" => {
                                if list.len() < 3 {
                                    return Err("match: (match expr (pattern body)...)".into());
                                }
                                let subject = self.eval(&list[1], &env)?;
                                let mut matched = None;
                                'clauses: for clause in &list[2..] {
                                    if let Expr::List(c) = clause {
                                        if c.len() < 2 { continue; }
                                        let pat = &c[0];
                                        let body_exprs = &c[1..];
                                        let mut bindings: Vec<(String, Value)> = Vec::new();
                                        if match_pattern(pat, &subject, &mut bindings) {
                                            let match_env = EnvFrame::new(Some(env.clone()));
                                            for (name, val) in bindings {
                                                EnvFrame::set(&match_env, name, val);
                                            }
                                            let last = body_exprs.len() - 1;
                                            for e in &body_exprs[..last] {
                                                self.eval(e, &match_env)?;
                                            }
                                            matched = Some((body_exprs[last].clone(), match_env));
                                            break 'clauses;
                                        }
                                    }
                                }
                                match matched {
                                    Some((body, match_env)) => {
                                        cur = body;
                                        env = match_env;
                                        continue;
                                    }
                                    None => return Err(format!("match: no clause matched {}", subject)),
                                }
                            }

                            // ── Quote / Quasiquote ────────────────────────
                            "quote" => {
                                if list.len() != 2 { return Err("quote: expects 1 arg".into()); }
                                return Ok(expr_to_value(&list[1]));
                            }

                            "quasiquote" => {
                                if list.len() != 2 { return Err("quasiquote: expects 1 arg".into()); }
                                return self.expand_quasiquote(&list[1], &env);
                            }

                            // ── Conditionals ──────────────────────────────
                            "if" => {
                                if list.len() < 3 { return Err("if: (if test then [else])".into()); }
                                let test_val = self.eval(&list[1], &env)?;
                                if is_truthy(&test_val) {
                                    cur = list[2].clone();
                                } else if list.len() > 3 {
                                    cur = list[3].clone();
                                } else {
                                    return Ok(Value::Nil);
                                }
                                continue;
                            }

                            "when" => {
                                if list.len() < 3 { return Err("when: (when test body...)".into()); }
                                let test_val = self.eval(&list[1], &env)?;
                                if is_truthy(&test_val) {
                                    let last = list.len() - 1;
                                    for e in &list[2..last] { self.eval(e, &env)?; }
                                    cur = list[last].clone(); continue;
                                }
                                return Ok(Value::Nil);
                            }

                            "unless" => {
                                if list.len() < 3 { return Err("unless: (unless test body...)".into()); }
                                let test_val = self.eval(&list[1], &env)?;
                                if !is_truthy(&test_val) {
                                    let last = list.len() - 1;
                                    for e in &list[2..last] { self.eval(e, &env)?; }
                                    cur = list[last].clone(); continue;
                                }
                                return Ok(Value::Nil);
                            }

                            "cond" => {
                                let mut found: Option<Expr> = None;
                                'cond: for clause in &list[1..] {
                                    if let Expr::List(c) = clause {
                                        if c.is_empty() { continue; }
                                        let is_else = matches!(&c[0], Expr::Symbol(s) if s == "else");
                                        let test_val = if is_else { Value::Bool(true) } else { self.eval(&c[0], &env)? };
                                        if is_truthy(&test_val) {
                                            if c.len() == 1 { return Ok(test_val); }
                                            let last = c.len() - 1;
                                            for e in &c[1..last] { self.eval(e, &env)?; }
                                            found = Some(c[last].clone());
                                            break 'cond;
                                        }
                                    }
                                }
                                match found {
                                    Some(e) => { cur = e; continue; }
                                    None    => return Ok(Value::Nil),
                                }
                            }

                            // ── Boolean short-circuit ─────────────────────
                            "and" => {
                                if list.len() == 1 { return Ok(Value::Bool(true)); }
                                let last = list.len() - 1;
                                for e in &list[1..last] {
                                    let v = self.eval(e, &env)?;
                                    if !is_truthy(&v) { return Ok(v); }
                                }
                                cur = list[last].clone(); continue;
                            }

                            "or" => {
                                if list.len() == 1 { return Ok(Value::Bool(false)); }
                                let last = list.len() - 1;
                                for e in &list[1..last] {
                                    let v = self.eval(e, &env)?;
                                    if is_truthy(&v) { return Ok(v); }
                                }
                                cur = list[last].clone(); continue;
                            }

                            // ── Sequencing ────────────────────────────────
                            "begin" => {
                                if list.len() == 1 { return Ok(Value::Nil); }
                                let last = list.len() - 1;
                                for e in &list[1..last] { self.eval(e, &env)?; }
                                cur = list[last].clone(); continue;
                            }

                            // ── Definitions ───────────────────────────────
                            "define" => { return self.eval_define(list, &env); }
                            "def"    => { return self.eval_def(list, &env); }

                            "set!" => {
                                if list.len() != 3 { return Err("set!: (set! name value)".into()); }
                                let name = sym_name(&list[1], "set!")?;
                                let val  = self.eval(&list[2], &env)?;
                                if !EnvFrame::set_existing(&env, &name, val) {
                                    return Err(format!("set!: undefined variable '{}'", name));
                                }
                                return Ok(Value::Nil);
                            }

                            // Legacy SimpleLisp alias — creates variable if not yet defined
                            "set" => {
                                if list.len() != 3 { return Err("set: (set name value)".into()); }
                                let name = sym_name(&list[1], "set")?;
                                let val  = self.eval(&list[2], &env)?;
                                if !EnvFrame::set_existing(&env, &name, val.clone()) {
                                    EnvFrame::set(&env, name, val);
                                }
                                return Ok(Value::Nil);
                            }

                            // ── Lambdas ───────────────────────────────────
                            "lambda" | "fn" | "λ" => { return self.eval_lambda(list, &env); }

                            // ── Macros ────────────────────────────────────
                            "defmacro" | "define-macro" => {
                                if list.len() < 4 { return Err("defmacro: (defmacro name (params) body...)".into()); }
                                let name = sym_name(&list[1], "defmacro")?;
                                let (params, rest) = match &list[2] {
                                    Expr::List(ps) => parse_params(ps)?,
                                    _ => return Err("defmacro: params must be a list".into()),
                                };
                                let body = list[3..].to_vec();
                                EnvFrame::set(&env, name, Value::Macro { params, rest, body, env: env.clone() });
                                return Ok(Value::Nil);
                            }

                            // ── Let forms ─────────────────────────────────
                            "let" => {
                                // Named let: (let loop ((var val)...) body...)
                                if list.len() > 2 {
                                    if let Expr::Symbol(lname) = &list[1] {
                                        let lname = lname.clone();
                                        let (e, new_env) = self.eval_named_let(&lname, list, &env)?;
                                        cur = e; env = new_env; continue;
                                    }
                                }
                                let (e, new_env) = self.eval_let(list, &env)?;
                                cur = e; env = new_env; continue;
                            }

                            "let*" => {
                                let (e, new_env) = self.eval_let_star(list, &env)?;
                                cur = e; env = new_env; continue;
                            }

                            "letrec" | "letrec*" => {
                                let (e, new_env) = self.eval_letrec(list, &env)?;
                                cur = e; env = new_env; continue;
                            }

                            // ── Do loop ───────────────────────────────────
                            "do" => { return self.eval_do(list, &env); }

                            _ => {} // fall through to macro / function call
                        }
                    }

                    // ── Macro expansion ──
                    if let Expr::Symbol(s) = &list[0] {
                        if let Some(Value::Macro { params, rest, body, env: mac_env }) =
                            EnvFrame::get(&env, s)
                        {
                            let arg_vals: Vec<Value> = list[1..].iter().map(expr_to_value).collect();
                            let mac_child = EnvFrame::extend(&mac_env, &params, &rest, arg_vals)?;
                            let last = body.len() - 1;
                            for e in &body[..last] { self.eval(e, &mac_child)?; }
                            let expanded = self.eval(&body[last], &mac_child)?;
                            cur = value_to_expr(&expanded);
                            continue;
                        }
                    }

                    // ── Function call ──
                    let func = self.eval(&list[0], &env)?;
                    let args: Result<Vec<Value>, _> = list[1..].iter()
                        .map(|a| self.eval(a, &env)).collect();
                    let args = args?;

                    match func {
                        Value::Builtin(_, f) => return f(&args),
                        Value::Lambda { params, rest, body, env: cenv } => {
                            let child = EnvFrame::extend(&cenv, &params, &rest, args)?;
                            let last = body.len() - 1;
                            for e in &body[..last] { self.eval(e, &child)?; }
                            cur = body[last].clone();
                            env = child;
                            continue;
                        }
                        other => return Err(format!("Not callable: {}", other)),
                    }
                }
            }
        }
    }

    // ── quasiquote ────────────────────────────────────────────────────────
    fn expand_quasiquote(&self, expr: &Expr, env: &Env) -> Result<Value, String> {
        match expr {
            Expr::List(list) if !list.is_empty() => {
                // (unquote x) → evaluate x
                if let Expr::Symbol(s) = &list[0] {
                    if s == "unquote" && list.len() == 2 {
                        return self.eval(&list[1], env);
                    }
                }
                // Build list, splicing ,@ items
                let mut result = Vec::new();
                for item in list {
                    if let Expr::List(inner) = item {
                        if let Some(Expr::Symbol(s)) = inner.first() {
                            if s == "unquote-splicing" && inner.len() == 2 {
                                match self.eval(&inner[1], env)? {
                                    Value::List(vs) => { result.extend(vs); continue; }
                                    Value::Nil      => continue,
                                    v => return Err(format!(",@: expected list, got {}", v)),
                                }
                            }
                        }
                    }
                    result.push(self.expand_quasiquote(item, env)?);
                }
                Ok(Value::List(result))
            }
            other => Ok(expr_to_value(other)),
        }
    }

    // ── define / def ────────────────────────────────────────────────────────
    fn eval_define(&self, list: &[Expr], env: &Env) -> Result<Value, String> {
        if list.len() < 3 { return Err("define: needs name and value".into()); }
        match &list[1] {
            Expr::Symbol(name) => {
                let val = self.eval(&list[2], env)?;
                EnvFrame::set(env, name.clone(), val);
            }
            Expr::List(sig) => {
                let name = sym_name(sig.first().ok_or("define: empty signature")?, "define")?;
                let (params, rest) = parse_params(&sig[1..])?;
                let body = list[2..].to_vec();
                EnvFrame::set(env, name, Value::Lambda { params, rest, body, env: env.clone() });
            }
            _ => return Err("define: first arg must be symbol or list".into()),
        }
        Ok(Value::Nil)
    }

    fn eval_def(&self, list: &[Expr], env: &Env) -> Result<Value, String> {
        if list.len() < 3 { return Err("def: needs name and value".into()); }
        if list.len() == 3 { return self.eval_define(list, env); }
        let name = sym_name(&list[1], "def")?;
        let (params, rest) = match &list[2] {
            Expr::List(ps) => parse_params(ps)?,
            _ => return Err("def: params must be a list".into()),
        };
        let body = list[3..].to_vec();
        EnvFrame::set(env, name, Value::Lambda { params, rest, body, env: env.clone() });
        Ok(Value::Nil)
    }

    fn eval_lambda(&self, list: &[Expr], env: &Env) -> Result<Value, String> {
        if list.len() < 3 { return Err("lambda: (lambda (params) body...)".into()); }
        let (params, rest) = match &list[1] {
            Expr::List(ps)  => parse_params(ps)?,
            Expr::Symbol(s) => (vec![], Some(s.clone())),
            _ => return Err("lambda: params must be a list or symbol".into()),
        };
        Ok(Value::Lambda { params, rest, body: list[2..].to_vec(), env: env.clone() })
    }

    // ── let forms ─────────────────────────────────────────────────────────
    fn eval_let(&self, list: &[Expr], env: &Env) -> Result<(Expr, Env), String> {
        let (bindings, body) = extract_let_parts(list)?;
        let child = EnvFrame::new(Some(env.clone()));
        for (n, e) in bindings { EnvFrame::set(&child, n, self.eval(&e, env)?); }
        Ok((wrap_begin(body), child))
    }

    fn eval_let_star(&self, list: &[Expr], env: &Env) -> Result<(Expr, Env), String> {
        let (bindings, body) = extract_let_parts(list)?;
        let child = EnvFrame::new(Some(env.clone()));
        for (n, e) in bindings { let v = self.eval(&e, &child)?; EnvFrame::set(&child, n, v); }
        Ok((wrap_begin(body), child))
    }

    fn eval_letrec(&self, list: &[Expr], env: &Env) -> Result<(Expr, Env), String> {
        let (bindings, body) = extract_let_parts(list)?;
        let child = EnvFrame::new(Some(env.clone()));
        for (n, _) in &bindings { EnvFrame::set(&child, n.clone(), Value::Nil); }
        for (n, e)  in bindings  { let v = self.eval(&e, &child)?; EnvFrame::set(&child, n, v); }
        Ok((wrap_begin(body), child))
    }

    // Named let: (let loop ((i 0) (acc 1)) body...)
    fn eval_named_let(&self, name: &str, list: &[Expr], env: &Env) -> Result<(Expr, Env), String> {
        let bindings_raw = match &list[2] {
            Expr::List(b) => b,
            _ => return Err("named let: bindings must be a list".into()),
        };
        let mut params = Vec::new();
        let mut inits  = Vec::new();
        for b in bindings_raw {
            if let Expr::List(pair) = b {
                if pair.len() == 2 {
                    if let Expr::Symbol(n) = &pair[0] {
                        params.push(n.clone());
                        inits.push(pair[1].clone());
                        continue;
                    }
                }
            }
            return Err("named let: each binding must be (var init)".into());
        }
        let body = list[3..].to_vec();
        // Evaluate inits in outer env
        let init_vals: Result<Vec<Value>, _> = inits.iter().map(|e| self.eval(e, env)).collect();
        let init_vals = init_vals?;
        // Create env with the loop function bound
        let loop_env = EnvFrame::new(Some(env.clone()));
        let lambda = Value::Lambda {
            params: params.clone(), rest: None,
            body: body.clone(), env: loop_env.clone(),
        };
        EnvFrame::set(&loop_env, name.to_string(), lambda);
        // Bind initial param values
        let call_env = EnvFrame::extend(&loop_env, &params, &None, init_vals)?;
        Ok((wrap_begin(body), call_env))
    }

    // ── do loop ─────────────────────────────────────────────────────────
    // (do ((var init step)...) (test result...) body...)
    fn eval_do(&self, list: &[Expr], env: &Env) -> Result<Value, String> {
        if list.len() < 3 { return Err("do: (do ((var init step)...) (test result...) body...)".into()); }
        let var_specs = match &list[1] { Expr::List(v) => v, _ => return Err("do: var specs must be a list".into()) };
        let test_clause = match &list[2] { Expr::List(t) if !t.is_empty() => t, _ => return Err("do: test clause must be a non-empty list".into()) };
        let body = &list[3..];

        let mut names: Vec<String>       = Vec::new();
        let mut inits: Vec<Expr>         = Vec::new();
        let mut steps: Vec<Option<Expr>> = Vec::new();

        for spec in var_specs {
            if let Expr::List(s) = spec {
                match s.len() {
                    2 => { names.push(sym_name(&s[0], "do")?); inits.push(s[1].clone()); steps.push(None); }
                    3 => { names.push(sym_name(&s[0], "do")?); inits.push(s[1].clone()); steps.push(Some(s[2].clone())); }
                    _ => return Err("do: var spec must be (var init) or (var init step)".into()),
                }
            } else { return Err("do: var spec must be a list".into()); }
        }

        let loop_env = EnvFrame::new(Some(env.clone()));
        for (n, i) in names.iter().zip(inits.iter()) {
            let v = self.eval(i, env)?;
            EnvFrame::set(&loop_env, n.clone(), v);
        }

        loop {
            if is_truthy(&self.eval(&test_clause[0], &loop_env)?) {
                if test_clause.len() == 1 { return Ok(Value::Nil); }
                let last = test_clause.len() - 1;
                for e in &test_clause[1..last] { self.eval(e, &loop_env)?; }
                return self.eval(&test_clause[last], &loop_env);
            }
            for e in body { self.eval(e, &loop_env)?; }
            // Evaluate all steps before updating (simultaneous)
            let new_vals: Result<Vec<Value>, _> = names.iter().zip(steps.iter())
                .map(|(n, step)| match step {
                    Some(s) => self.eval(s, &loop_env),
                    None    => Ok(EnvFrame::get(&loop_env, n).unwrap_or(Value::Nil)),
                }).collect();
            for (n, v) in names.iter().zip(new_vals?.into_iter()) {
                EnvFrame::set(&loop_env, n.clone(), v);
            }
        }
    }
}

// ── free helpers ─────────────────────────────────────────────────────────

pub fn is_truthy(v: &Value) -> bool {
    !matches!(v, Value::Bool(false) | Value::Nil)
}

pub fn expr_to_value(e: &Expr) -> Value {
    match e {
        Expr::Number(n) => Value::Number(*n),
        Expr::Bool(b)   => Value::Bool(*b),
        Expr::String(s) => Value::String(s.clone()),
        Expr::Symbol(s) => Value::Symbol(s.clone()),
        Expr::List(vs)  => Value::List(vs.iter().map(expr_to_value).collect()),
        Expr::Nil       => Value::Nil,
    }
}

pub fn value_to_expr(v: &Value) -> Expr {
    match v {
        Value::Number(n) => Expr::Number(*n),
        Value::Bool(b)   => Expr::Bool(*b),
        Value::String(s) => Expr::String(s.clone()),
        Value::Symbol(s) => Expr::Symbol(s.clone()),
        Value::List(vs)  => Expr::List(vs.iter().map(value_to_expr).collect()),
        _                => Expr::Nil,
    }
}

fn sym_name(e: &Expr, ctx: &str) -> Result<String, String> {
    match e {
        Expr::Symbol(s) => Ok(s.clone()),
        _ => Err(format!("{}: expected a symbol", ctx)),
    }
}

fn parse_params(exprs: &[Expr]) -> Result<(Vec<String>, Option<String>), String> {
    let mut params = Vec::new();
    let mut rest   = None;
    let mut i = 0;
    while i < exprs.len() {
        match &exprs[i] {
            Expr::Symbol(s) if s == "." => {
                if i + 1 < exprs.len() {
                    if let Expr::Symbol(r) = &exprs[i+1] { rest = Some(r.clone()); break; }
                }
                return Err("malformed rest param after '.'".into());
            }
            Expr::Symbol(s) => params.push(s.clone()),
            _ => return Err("params must be symbols".into()),
        }
        i += 1;
    }
    Ok((params, rest))
}

fn extract_let_parts(list: &[Expr]) -> Result<(Vec<(String, Expr)>, Vec<Expr>), String> {
    if list.len() < 3 { return Err("let: (let ((x v)...) body...)".into()); }
    let bs = match &list[1] { Expr::List(b) => b, _ => return Err("let: bindings must be a list".into()) };
    let mut bindings = Vec::new();
    for b in bs {
        if let Expr::List(pair) = b {
            if pair.len() == 2 {
                if let Expr::Symbol(n) = &pair[0] { bindings.push((n.clone(), pair[1].clone())); continue; }
            }
        }
        return Err("let: each binding must be (name expr)".into());
    }
    Ok((bindings, list[2..].to_vec()))
}

pub fn wrap_begin(mut exprs: Vec<Expr>) -> Expr {
    if exprs.len() == 1 { exprs.remove(0) }
    else { let mut v = vec![Expr::Symbol("begin".into())]; v.extend(exprs); Expr::List(v) }
}

// ── Pattern matching helper ───────────────────────────────────────────────
//
// Patterns:
//   _                  — wildcard, matches anything
//   42 / "str" / #t   — literal match
//   x                  — symbol binding (binds value to x)
//   (list p1 p2 ...)   — list pattern
//   (cons h t)         — head/tail destructure
//   (quote sym)        — match literal symbol
//   (? pred)           — guard: match if (pred value) is truthy
//
pub fn match_pattern(pat: &Expr, val: &Value, bindings: &mut Vec<(String, Value)>) -> bool {
    match pat {
        // Wildcard
        Expr::Symbol(s) if s == "_" => true,

        // Symbol → bind
        Expr::Symbol(s) => {
            bindings.push((s.clone(), val.clone()));
            true
        }

        // Literal number
        Expr::Number(n) => matches!(val, Value::Number(v) if v == n),

        // Literal bool
        Expr::Bool(b) => matches!(val, Value::Bool(v) if v == b),

        // Literal string
        Expr::String(s) => matches!(val, Value::String(v) if v == s),

        // Nil / empty list
        Expr::Nil => matches!(val, Value::Nil) || matches!(val, Value::List(v) if v.is_empty()),

        // List pattern
        Expr::List(pats) if !pats.is_empty() => {
            // (quote sym) — match literal symbol
            if let Expr::Symbol(head) = &pats[0] {
                if head == "quote" && pats.len() == 2 {
                    if let Expr::Symbol(sym) = &pats[1] {
                        return matches!(val, Value::Symbol(s) if s == sym);
                    }
                }

                // (? pred-expr) — guard pattern (pred applied to value)
                if head == "?" && pats.len() == 2 {
                    // We can't easily eval here without an env reference,
                    // so guard is a symbol predicate check: (? number?) etc.
                    if let Expr::Symbol(pred) = &pats[1] {
                        return match pred.as_str() {
                            "number?"  => matches!(val, Value::Number(_)),
                            "string?"  => matches!(val, Value::String(_)),
                            "boolean?" => matches!(val, Value::Bool(_)),
                            "list?"    => matches!(val, Value::List(_) | Value::Nil),
                            "symbol?"  => matches!(val, Value::Symbol(_)),
                            "nil?"     => matches!(val, Value::Nil),
                            "pair?"    => matches!(val, Value::List(v) if !v.is_empty()),
                            "zero?"    => matches!(val, Value::Number(n) if *n == 0.0),
                            "positive?"=> matches!(val, Value::Number(n) if *n > 0.0),
                            "negative?"=> matches!(val, Value::Number(n) if *n < 0.0),
                            _          => false,
                        };
                    }
                }

                // (cons head tail) — destructure list
                if head == "cons" && pats.len() == 3 {
                    if let Value::List(xs) = val {
                        if xs.is_empty() { return false; }
                        let h = xs[0].clone();
                        let t = Value::List(xs[1..].to_vec());
                        let save = bindings.len();
                        if match_pattern(&pats[1], &h, bindings)
                            && match_pattern(&pats[2], &t, bindings) {
                            return true;
                        }
                        bindings.truncate(save);
                        return false;
                    }
                    return false;
                }
            }

            // (p1 p2 ...) — fixed-length list pattern
            // OR (p1 p2 . rest) — dotted rest pattern (last pat is `. rest-var`)
            if let Value::List(vals) = val {
                // Check for dotted rest: if second-to-last pattern is the symbol "."
                // e.g. pattern (a b . rest) parsed as list [a, b, ., rest]
                let dot_pos = pats.iter().position(|p| matches!(p, Expr::Symbol(s) if s == "."));
                if let Some(dp) = dot_pos {
                    // Fixed part: pats[..dp], rest var: pats[dp+1]
                    if dp + 1 >= pats.len() { return false; }
                    if vals.len() < dp { return false; }
                    let save = bindings.len();
                    for (p, v) in pats[..dp].iter().zip(vals[..dp].iter()) {
                        if !match_pattern(p, v, bindings) {
                            bindings.truncate(save);
                            return false;
                        }
                    }
                    // Bind rest variable to remaining items
                    let rest_val = Value::List(vals[dp..].to_vec());
                    if !match_pattern(&pats[dp+1], &rest_val, bindings) {
                        bindings.truncate(save);
                        return false;
                    }
                    return true;
                }

                // Fixed-length: must match exactly
                if vals.len() != pats.len() { return false; }
                let save = bindings.len();
                for (p, v) in pats.iter().zip(vals.iter()) {
                    if !match_pattern(p, v, bindings) {
                        bindings.truncate(save);
                        return false;
                    }
                }
                true
            } else {
                false
            }
        }

        _ => false,
    }
}
