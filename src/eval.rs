use crate::parser::Expr;
use crate::env::{Environment, Value};

pub struct Evaluator;

impl Evaluator {
    pub fn new() -> Self {
        Evaluator
    }

    pub fn eval_all(&mut self, ast: &[Expr], env: &mut Environment) -> Result<Value, String> {
        let mut result = Value::Nil;
        for expr in ast {
            result = self.eval(expr, env)?;
        }
        Ok(result)
    }

    pub fn eval(&self, expr: &Expr, env: &mut Environment) -> Result<Value, String> {
        match expr {
            Expr::Number(n) => Ok(Value::Number(*n)),
            Expr::String(s) => Ok(Value::String(s.clone())),
            Expr::Symbol(s) => {
                if let Some(v) = env.get(s) {
                    Ok(v)
                } else {
                    Err(format!("Undefined symbol: {}", s))
                }
            }
            Expr::List(list) => {
                if list.is_empty() {
                    return Ok(Value::Nil);
                }
                let op = &list[0];
                match op {
                    Expr::Symbol(s) if s == "add" => {
                        if list.len() == 3 {
                            if let (Expr::Number(a), Expr::Number(b)) = (&list[1], &list[2]) {
                                return Ok(Value::Number(a + b));
                            }
                        }
                        Err("add expects 2 numbers".to_string())
                    }
                    _ => Err("Unsupported operation".to_string()),
                }
            }
            Expr::Nil => Ok(Value::Nil),
        }
    }
}
