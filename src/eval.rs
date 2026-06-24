use crate::parser::Expr;
use crate::env::{Env, EnvFrame, Value};

pub struct Evaluator;

impl Evaluator {
    pub fn new() -> Self { Evaluator }

    pub fn eval_all(&self, ast: &[Expr], env: &Env) -> Result<Value, String> {
        let mut result = Value::Nil;
        for expr in ast {
            result = self.eval(expr, env)?;
        }
        Ok(result)
    }

    pub fn eval(&self, expr: &Expr, env: &Env) -> Result<Value, String> {
        let mut cur_expr = expr.clone();
        let mut cur_env  = env.clone();

        loop {
            match &cur_expr {
                Expr::Number(n) => return Ok(Value::Number(*n)),
                Expr::Bool(b)   => return Ok(Value::Bool(*b)),
                Expr::String(s) => return Ok(Value::String(s.clone())),
                Expr::Nil       => return Ok(Value::Nil),

                Expr::Symbol(s) => {
                    return EnvFrame::get(&cur_env, s)
                        .ok_or_else(|| format!("Undefined symbol: {}", s));
                }

                Expr::List(list) => {
                    if list.is_empty() {
                        return Ok(Value::Nil);
                    }

                    if let Expr::Symbol(head) = &list[0] {
                        match head.as_str() {

                            "quote" => {
                                if list.len() != 2 { return Err("quote: 1 arg".into()); }
                                return Ok(expr_to_value(&list[1]));
                            }

                            "if" => {
                                if list.len() < 3 || list.len() > 4 {
                                    return Err("if: (if test then [else])".into());
                                }
                                let test = self.eval(&list[1], &cur_env)?;
                                if is_truthy(&test) {
                                    cur_expr = list[2].clone();
                                } else if list.len() == 4 {
                                    cur_expr = list[3].clone();
                                } else {
                                    return Ok(Value::Nil);
                                }
                                continue;
                            }

                            "cond" => {
                                let mut tail = None;
                                for clause in &list[1..] {
                                    if let Expr::List(c) = clause {
                                        if c.is_empty() { continue; }
                                        let is_else = matches!(&c[0], Expr::Symbol(s) if s == "else");
                                        let test = if is_else {
                                            Value::Bool(true)
                                        } else {
                                            self.eval(&c[0], &cur_env)?
                                        };
                                        if is_truthy(&test) {
                                            if c.len() == 1 { return Ok(test); }
                                            let last = c.len() - 1;
                                            for e in &c[1..last] { self.eval(e, &cur_env)?; }
                                            tail = Some(c[last].clone());
                                            break;
                                        }
                                    } else {
                                        return Err("cond: clause must be a list".into());
                                    }
                                }
                                match tail {
                                    Some(t) => { cur_expr = t; continue; }
                                    None    => return Ok(Value::Nil),
                                }
                            }

                            "and" => {
                                if list.len() == 1 { return Ok(Value::Bool(true)); }
                                let last = list.len() - 1;
                                for e in &list[1..last] {
                                    let v = self.eval(e, &cur_env)?;
                                    if !is_truthy(&v) { return Ok(Value::Bool(false)); }
                                }
                                cur_expr = list[last].clone();
                                continue;
                            }

                            "or" => {
                                if list.len() == 1 { return Ok(Value::Bool(false)); }
                                let last = list.len() - 1;
                                for e in &list[1..last] {
                                    let v = self.eval(e, &cur_env)?;
                                    if is_truthy(&v) { return Ok(v); }
                                }
                                cur_expr = list[last].clone();
                                continue;
                            }

                            // Scheme-style define
                            "define" => {
                                return self.eval_define(list, &cur_env);
                            }

                            // SimpleLisp-style def: (def name (params) body...)
                            "def" => {
                                return self.eval_def(list, &cur_env);
                            }

                            // Scheme set! — only mutates existing bindings
                            "set!" => {
                                if list.len() != 3 { return Err("set!: (set! name val)".into()); }
                                if let Expr::Symbol(name) = &list[1] {
                                    let val = self.eval(&list[2], &cur_env)?;
                                    if !EnvFrame::set_existing(&cur_env, name, val) {
                                        return Err(format!("set!: unbound variable '{}'", name));
                                    }
                                    return Ok(Value::Nil);
                                }
                                return Err("set!: first arg must be a symbol".into());
                            }

                            // SimpleLisp-style set — create-or-update
                            "set" => {
                                if list.len() != 3 { return Err("set: (set name val)".into()); }
                                if let Expr::Symbol(name) = &list[1] {
                                    let val = self.eval(&list[2], &cur_env)?;
                                    // Walk up and mutate if found; otherwise bind in current env
                                    if !EnvFrame::set_existing(&cur_env, name, val.clone()) {
                                        EnvFrame::set(&cur_env, name.clone(), val);
                                    }
                                    return Ok(Value::Nil);
                                }
                                return Err("set: first arg must be a symbol".into());
                            }

                            "lambda" => {
                                return self.eval_lambda(list, &cur_env);
                            }

                            "begin" => {
                                if list.len() == 1 { return Ok(Value::Nil); }
                                let last = list.len() - 1;
                                for e in &list[1..last] { self.eval(e, &cur_env)?; }
                                cur_expr = list[last].clone();
                                continue;
                            }

                            "let" => {
                                let (body, child) = self.eval_let(list, &cur_env)?;
                                cur_env  = child;
                                cur_expr = body;
                                continue;
                            }

                            "let*" => {
                                let (body, child) = self.eval_let_star(list, &cur_env)?;
                                cur_env  = child;
                                cur_expr = body;
                                continue;
                            }

                            "letrec" => {
                                let (body, child) = self.eval_letrec(list, &cur_env)?;
                                cur_env  = child;
                                cur_expr = body;
                                continue;
                            }

                            "when" => {
                                if list.len() < 3 { return Err("when: (when test body...)".into()); }
                                let test = self.eval(&list[1], &cur_env)?;
                                if is_truthy(&test) {
                                    let last = list.len() - 1;
                                    for e in &list[2..last] { self.eval(e, &cur_env)?; }
                                    cur_expr = list[last].clone();
                                    continue;
                                }
                                return Ok(Value::Nil);
                            }

                            "unless" => {
                                if list.len() < 3 { return Err("unless: (unless test body...)".into()); }
                                let test = self.eval(&list[1], &cur_env)?;
                                if !is_truthy(&test) {
                                    let last = list.len() - 1;
                                    for e in &list[2..last] { self.eval(e, &cur_env)?; }
                                    cur_expr = list[last].clone();
                                    continue;
                                }
                                return Ok(Value::Nil);
                            }

                            _ => {} // fall through to function call
                        }
                    }

                    // Function call
                    let func = self.eval(&list[0], &cur_env)?;
                    let args: Result<Vec<Value>, _> = list[1..].iter()
                        .map(|a| self.eval(a, &cur_env))
                        .collect();
                    let args = args?;

                    match func {
                        Value::Builtin(_, f) => return f(&args),
                        Value::Lambda { params, rest, body, env: closure_env } => {
                            let child = EnvFrame::extend(&closure_env, &params, &rest, args)?;
                            let last = body.len() - 1;
                            for e in &body[..last] { self.eval(e, &child)?; }
                            cur_expr = body[last].clone();
                            cur_env  = child;
                            continue;
                        }
                        other => return Err(format!("Not callable: {}", other)),
                    }
                }
            }
        }
    }

    // (define name expr)  OR  (define (name params...) body...)
    fn eval_define(&self, list: &[Expr], env: &Env) -> Result<Value, String> {
        if list.len() < 3 { return Err("define: needs name and value".into()); }
        match &list[1] {
            Expr::Symbol(name) => {
                let val = self.eval(&list[2], env)?;
                EnvFrame::set(env, name.clone(), val);
                Ok(Value::Nil)
            }
            Expr::List(sig) => {
                if sig.is_empty() { return Err("define: empty signature".into()); }
                let name = match &sig[0] {
                    Expr::Symbol(s) => s.clone(),
                    _ => return Err("define: function name must be a symbol".into()),
                };
                let (params, rest) = parse_params(&sig[1..])?;
                let body = list[2..].to_vec();
                EnvFrame::set(env, name, Value::Lambda { params, rest, body, env: env.clone() });
                Ok(Value::Nil)
            }
            _ => Err("define: first arg must be a symbol or list".into()),
        }
    }

    // SimpleLisp style: (def name (params) body...)
    fn eval_def(&self, list: &[Expr], env: &Env) -> Result<Value, String> {
        // (def name (params) body...)
        if list.len() < 4 {
            // Could also be (def name expr) with no params — treat as define
            if list.len() == 3 {
                return self.eval_define(list, env);
            }
            return Err("def: (def name (params) body...)".into());
        }
        let name = match &list[1] {
            Expr::Symbol(s) => s.clone(),
            _ => return Err("def: name must be a symbol".into()),
        };
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
        let body = list[2..].to_vec();
        Ok(Value::Lambda { params, rest, body, env: env.clone() })
    }

    fn eval_let(&self, list: &[Expr], env: &Env) -> Result<(Expr, Env), String> {
        let (bindings, body) = extract_let_parts(list)?;
        let child = EnvFrame::new(Some(env.clone()));
        for (name, expr) in bindings {
            let val = self.eval(&expr, env)?;
            EnvFrame::set(&child, name, val);
        }
        Ok((wrap_begin(body), child))
    }

    fn eval_let_star(&self, list: &[Expr], env: &Env) -> Result<(Expr, Env), String> {
        let (bindings, body) = extract_let_parts(list)?;
        let child = EnvFrame::new(Some(env.clone()));
        for (name, expr) in bindings {
            let val = self.eval(&expr, &child)?;
            EnvFrame::set(&child, name, val);
        }
        Ok((wrap_begin(body), child))
    }

    fn eval_letrec(&self, list: &[Expr], env: &Env) -> Result<(Expr, Env), String> {
        let (bindings, body) = extract_let_parts(list)?;
        let child = EnvFrame::new(Some(env.clone()));
        for (name, _) in &bindings {
            EnvFrame::set(&child, name.clone(), Value::Nil);
        }
        for (name, expr) in bindings {
            let val = self.eval(&expr, &child)?;
            EnvFrame::set(&child, name, val);
        }
        Ok((wrap_begin(body), child))
    }
}

// ---- Helpers ----

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

fn parse_params(exprs: &[Expr]) -> Result<(Vec<String>, Option<String>), String> {
    let mut params = Vec::new();
    let mut rest   = None;
    let mut i = 0;
    while i < exprs.len() {
        match &exprs[i] {
            Expr::Symbol(s) if s == "." => {
                if i + 1 < exprs.len() {
                    if let Expr::Symbol(r) = &exprs[i+1] {
                        rest = Some(r.clone());
                        break;
                    }
                }
                return Err("lambda: malformed rest param".into());
            }
            Expr::Symbol(s) => params.push(s.clone()),
            _ => return Err("lambda: params must be symbols".into()),
        }
        i += 1;
    }
    Ok((params, rest))
}

fn extract_let_parts(list: &[Expr]) -> Result<(Vec<(String, Expr)>, Vec<Expr>), String> {
    if list.len() < 3 { return Err("let: (let ((x v)...) body...)".into()); }
    let bindings_expr = match &list[1] {
        Expr::List(b) => b,
        _ => return Err("let: bindings must be a list".into()),
    };
    let mut bindings = Vec::new();
    for b in bindings_expr {
        if let Expr::List(pair) = b {
            if pair.len() == 2 {
                if let Expr::Symbol(name) = &pair[0] {
                    bindings.push((name.clone(), pair[1].clone()));
                    continue;
                }
            }
        }
        return Err("let: each binding must be (name expr)".into());
    }
    Ok((bindings, list[2..].to_vec()))
}

fn wrap_begin(mut exprs: Vec<Expr>) -> Expr {
    if exprs.len() == 1 { exprs.remove(0) }
    else {
        let mut v = vec![Expr::Symbol("begin".to_string())];
        v.extend(exprs);
        Expr::List(v)
    }
}
