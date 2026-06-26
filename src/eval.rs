use crate::parser::Expr;
use crate::env::{Env, EnvFrame, Value};

pub struct Evaluator;

impl Evaluator {
    pub fn new() -> Self { Evaluator }

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

                    // ── Special forms ──
                    if let Expr::Symbol(head) = &list[0] {
                        match head.as_str() {

                            "quote" => {
                                if list.len() != 2 { return Err("quote: expects 1 arg".into()); }
                                return Ok(expr_to_value(&list[1]));
                            }

                            "quasiquote" => {
                                if list.len() != 2 { return Err("quasiquote: expects 1 arg".into()); }
                                return self.expand_quasiquote(&list[1], &env);
                            }

                            "if" => {
                                if list.len() < 3 || list.len() > 4 {
                                    return Err("if: (if test then [else])".into());
                                }
                                let test = self.eval(&list[1], &env)?;
                                cur = if is_truthy(&test) {
                                    list[2].clone()
                                } else if list.len() == 4 {
                                    list[3].clone()
                                } else {
                                    return Ok(Value::Nil);
                                };
                                continue;
                            }

                            "cond" => {
                                let mut tail = None;
                                for clause in &list[1..] {
                                    if let Expr::List(c) = clause {
                                        if c.is_empty() { continue; }
                                        let is_else = matches!(&c[0], Expr::Symbol(s) if s == "else");
                                        let test = if is_else { Value::Bool(true) }
                                                   else { self.eval(&c[0], &env)? };
                                        if is_truthy(&test) {
                                            if c.len() == 1 { return Ok(test); }
                                            let last = c.len() - 1;
                                            for e in &c[1..last] { self.eval(e, &env)?; }
                                            tail = Some(c[last].clone());
                                            break;
                                        }
                                    } else { return Err("cond: clause must be a list".into()); }
                                }
                                match tail { Some(t) => { cur = t; continue; } None => return Ok(Value::Nil) }
                            }

                            "and" => {
                                if list.len() == 1 { return Ok(Value::Bool(true)); }
                                let last = list.len() - 1;
                                for e in &list[1..last] {
                                    if !is_truthy(&self.eval(e, &env)?) { return Ok(Value::Bool(false)); }
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

                            "define" => return self.eval_define(list, &env),
                            "def"    => return self.eval_def(list, &env),

                            "defmacro" => {
                                // (defmacro name (params) body...)
                                if list.len() < 4 {
                                    return Err("defmacro: (defmacro name (params) body...)".into());
                                }
                                let name = sym_name(&list[1], "defmacro")?;
                                let (params, rest) = match &list[2] {
                                    Expr::List(ps) => parse_params(ps)?,
                                    _ => return Err("defmacro: params must be a list".into()),
                                };
                                let body = list[3..].to_vec();
                                EnvFrame::set(&env, name,
                                    Value::Macro { params, rest, body, env: env.clone() });
                                return Ok(Value::Nil);
                            }

                            "set!" => {
                                if list.len() != 3 { return Err("set!: (set! name val)".into()); }
                                let name = sym_name(&list[1], "set!")?;
                                let val = self.eval(&list[2], &env)?;
                                if !EnvFrame::set_existing(&env, &name, val) {
                                    return Err(format!("set!: unbound '{}'", name));
                                }
                                return Ok(Value::Nil);
                            }

                            "set" => {
                                if list.len() != 3 { return Err("set: (set name val)".into()); }
                                let name = sym_name(&list[1], "set")?;
                                let val = self.eval(&list[2], &env)?;
                                if !EnvFrame::set_existing(&env, &name, val.clone()) {
                                    EnvFrame::set(&env, name, val);
                                }
                                return Ok(Value::Nil);
                            }

                            "lambda" => return self.eval_lambda(list, &env),

                            "begin" => {
                                if list.len() == 1 { return Ok(Value::Nil); }
                                let last = list.len() - 1;
                                for e in &list[1..last] { self.eval(e, &env)?; }
                                cur = list[last].clone(); continue;
                            }

                            "let" => {
                                // Named let: (let name ((var init)...) body...)
                                if list.len() >= 4 {
                                    if let Expr::Symbol(loop_name) = &list[1] {
                                        if let Expr::List(_) = &list[2] {
                                            let (body, child) = self.eval_named_let(loop_name, list, &env)?;
                                            env = child; cur = body; continue;
                                        }
                                    }
                                }
                                let (body, child) = self.eval_let(list, &env)?;
                                env = child; cur = body; continue;
                            }

                            "let*"   => { let (b,c) = self.eval_let_star(list, &env)?; env=c; cur=b; continue; }
                            "letrec" => { let (b,c) = self.eval_letrec(list, &env)?;   env=c; cur=b; continue; }

                            "when" => {
                                if list.len() < 3 { return Err("when: (when test body...)".into()); }
                                if !is_truthy(&self.eval(&list[1], &env)?) { return Ok(Value::Nil); }
                                let last = list.len() - 1;
                                for e in &list[2..last] { self.eval(e, &env)?; }
                                cur = list[last].clone(); continue;
                            }

                            "unless" => {
                                if list.len() < 3 { return Err("unless: (unless test body...)".into()); }
                                if is_truthy(&self.eval(&list[1], &env)?) { return Ok(Value::Nil); }
                                let last = list.len() - 1;
                                for e in &list[2..last] { self.eval(e, &env)?; }
                                cur = list[last].clone(); continue;
                            }

                            "do" => return self.eval_do(list, &env),

                            // (try-catch body (err-var) handler)
                            "try-catch" => {
                                if list.len() < 3 {
                                    return Err("try-catch: (try-catch body (err) handler)".into());
                                }
                                match self.eval(&list[1], &env) {
                                    Ok(v) => return Ok(v),
                                    Err(e) => {
                                        // Bind error string to err-var and eval handler
                                        let handler_env = EnvFrame::new(Some(env.clone()));
                                        if let Some(Expr::List(vars)) = list.get(2) {
                                            if let Some(Expr::Symbol(name)) = vars.first() {
                                                EnvFrame::set(&handler_env, name.clone(),
                                                    Value::String(e));
                                            }
                                        }
                                        let handler = list.get(3)
                                            .ok_or("try-catch: missing handler")?;
                                        cur = handler.clone();
                                        env = handler_env;
                                        continue;
                                    }
                                }
                            }

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
