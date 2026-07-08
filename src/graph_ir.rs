//! graph_ir.rs — a computation-graph IR (inspired by XLA/TVM) over the same
//! restricted numeric subset `defrust` compiles (numbers, params, + - * /,
//! comparisons, if). Built with hash-consing, so structurally identical
//! subexpressions collapse to one node as a side effect of construction —
//! that *is* the common-subexpression elimination here, not a separate pass.
//! `optimize` then runs constant folding (including pruning an `if` branch
//! when its condition is constant) and dead-code elimination (mark-and-sweep
//! from the output, which cleans up whatever folding/pruning orphaned).
//!
//! This is an inspectable/executable IR only — no codegen backend yet (see
//! docs/ROADMAP.md 1.2; wiring it into `rust_jit`'s codegen is future work).

use crate::env::Value;
use crate::parser::Expr;
use std::collections::HashMap;

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Op {
    Const(u64), // f64::to_bits — f64 itself isn't Eq/Hash, so we key on bits
    Param(usize),
    Add, Sub, Mul, Div,
    Lt, Gt, Le, Ge, Eq,
    If, // (cond, then, else)
}

#[derive(Clone, Debug)]
pub struct Node {
    pub op:   Op,
    pub args: Vec<usize>, // indices into Graph::nodes; always < this node's own index
}

#[derive(Clone, Debug, Default)]
pub struct Graph {
    pub nodes:  Vec<Node>,
    pub output: usize,
}

struct Interner {
    nodes: Vec<Node>,
    memo:  HashMap<(Op, Vec<usize>), usize>,
}

impl Interner {
    fn new() -> Self { Interner { nodes: Vec::new(), memo: HashMap::new() } }

    fn intern(&mut self, op: Op, args: Vec<usize>) -> usize {
        let key = (op.clone(), args.clone());
        if let Some(&i) = self.memo.get(&key) { return i; }
        let i = self.nodes.len();
        self.nodes.push(Node { op, args });
        self.memo.insert(key, i);
        i
    }

    fn const_val(&self, idx: usize) -> Option<f64> {
        match &self.nodes[idx].op {
            Op::Const(bits) => Some(f64::from_bits(*bits)),
            _ => None,
        }
    }

    fn konst(&mut self, v: f64) -> usize { self.intern(Op::Const(v.to_bits()), vec![]) }
}

// ── Build: restricted Expr subset → Graph ────────────────────────────────

fn build_num(ib: &mut Interner, params: &[String], expr: &Expr) -> Result<usize, String> {
    match expr {
        Expr::Number(n) => Ok(ib.konst(*n)),
        Expr::Symbol(s) => {
            if let Some(i) = params.iter().position(|p| p == s) {
                Ok(ib.intern(Op::Param(i), vec![]))
            } else {
                Err(format!(
                    "graph-ir: unsupported reference to '{}' — only params, numbers, + - * /, \
                     and if are supported", s
                ))
            }
        }
        Expr::List(items) if !items.is_empty() => {
            if let Expr::Symbol(head) = &items[0] {
                match head.as_str() {
                    "+" | "-" | "*" | "/" if items.len() >= 2 => {
                        let mut arg_ids = items[1..].iter()
                            .map(|e| build_num(ib, params, e))
                            .collect::<Result<Vec<_>, _>>()?;
                        let op = match head.as_str() { "+" => Op::Add, "-" => Op::Sub, "*" => Op::Mul, "/" => Op::Div, _ => unreachable!() };
                        if head == "-" && arg_ids.len() == 1 {
                            let zero = ib.konst(0.0);
                            return Ok(ib.intern(Op::Sub, vec![zero, arg_ids[0]]));
                        }
                        let mut acc = arg_ids.remove(0);
                        for a in arg_ids { acc = ib.intern(op.clone(), vec![acc, a]); }
                        Ok(acc)
                    }
                    "if" if items.len() == 4 => {
                        let c = build_bool(ib, params, &items[1])?;
                        let t = build_num(ib, params, &items[2])?;
                        let e = build_num(ib, params, &items[3])?;
                        Ok(ib.intern(Op::If, vec![c, t, e]))
                    }
                    other => Err(format!("graph-ir: unsupported operator '{}'", other)),
                }
            } else {
                Err("graph-ir: unsupported expression".into())
            }
        }
        _ => Err("graph-ir: only numbers, params, + - * /, and if are supported".into()),
    }
}

fn build_bool(ib: &mut Interner, params: &[String], expr: &Expr) -> Result<usize, String> {
    if let Expr::List(items) = expr {
        if let Some(Expr::Symbol(head)) = items.first() {
            let op = match head.as_str() {
                "<" => Some(Op::Lt), ">" => Some(Op::Gt), "<=" => Some(Op::Le),
                ">=" => Some(Op::Ge), "=" => Some(Op::Eq), _ => None,
            };
            if let (Some(op), 3) = (op, items.len()) {
                let a = build_num(ib, params, &items[1])?;
                let b = build_num(ib, params, &items[2])?;
                return Ok(ib.intern(op, vec![a, b]));
            }
        }
    }
    Err("graph-ir: an `if` condition must be a comparison (< > <= >= =)".into())
}

pub fn build(params: &[String], body: &Expr) -> Result<Graph, String> {
    let mut ib = Interner::new();
    let output = build_num(&mut ib, params, body)?;
    Ok(Graph { nodes: ib.nodes, output })
}

// ── Optimize: constant fold (+ if-branch pruning) then dead-code eliminate ─

fn fold_binop(ib: &mut Interner, op: Op, a: usize, b: usize, f: impl Fn(f64, f64) -> f64) -> usize {
    match (ib.const_val(a), ib.const_val(b)) {
        (Some(x), Some(y)) => ib.konst(f(x, y)),
        _ => ib.intern(op, vec![a, b]),
    }
}

fn fold_cmp(ib: &mut Interner, op: Op, a: usize, b: usize, f: impl Fn(f64, f64) -> bool) -> usize {
    match (ib.const_val(a), ib.const_val(b)) {
        (Some(x), Some(y)) => ib.konst(if f(x, y) { 1.0 } else { 0.0 }),
        _ => ib.intern(op, vec![a, b]),
    }
}

fn fold(graph: &Graph) -> Graph {
    let mut ib = Interner::new();
    let mut remap = vec![0usize; graph.nodes.len()];
    for (i, node) in graph.nodes.iter().enumerate() {
        let args: Vec<usize> = node.args.iter().map(|&a| remap[a]).collect();
        let new_idx = match (&node.op, args.as_slice()) {
            (Op::Add, [a, b]) => fold_binop(&mut ib, Op::Add, *a, *b, |x, y| x + y),
            (Op::Sub, [a, b]) => fold_binop(&mut ib, Op::Sub, *a, *b, |x, y| x - y),
            (Op::Mul, [a, b]) => fold_binop(&mut ib, Op::Mul, *a, *b, |x, y| x * y),
            (Op::Div, [a, b]) => fold_binop(&mut ib, Op::Div, *a, *b, |x, y| x / y),
            (Op::Lt, [a, b]) => fold_cmp(&mut ib, Op::Lt, *a, *b, |x, y| x < y),
            (Op::Gt, [a, b]) => fold_cmp(&mut ib, Op::Gt, *a, *b, |x, y| x > y),
            (Op::Le, [a, b]) => fold_cmp(&mut ib, Op::Le, *a, *b, |x, y| x <= y),
            (Op::Ge, [a, b]) => fold_cmp(&mut ib, Op::Ge, *a, *b, |x, y| x >= y),
            (Op::Eq, [a, b]) => fold_cmp(&mut ib, Op::Eq, *a, *b, |x, y| x == y),
            // If the condition is constant, prune to whichever branch is
            // live — no re-interning needed, we just reuse its existing id.
            // Anything the untaken branch alone referenced becomes
            // unreachable from the output and is swept by `dce` below.
            (Op::If, [c, t, e]) => match ib.const_val(*c) {
                Some(cv) => if cv != 0.0 { *t } else { *e },
                None => ib.intern(Op::If, args.clone()),
            },
            (other, _) => ib.intern(other.clone(), args.clone()),
        };
        remap[i] = new_idx;
    }
    Graph { nodes: ib.nodes, output: remap[graph.output] }
}

fn dce(graph: &Graph) -> Graph {
    let mut reachable = vec![false; graph.nodes.len()];
    let mut stack = vec![graph.output];
    while let Some(i) = stack.pop() {
        if reachable[i] { continue; }
        reachable[i] = true;
        for &a in &graph.nodes[i].args { stack.push(a); }
    }
    let mut new_index = vec![usize::MAX; graph.nodes.len()];
    let mut new_nodes = Vec::new();
    for (i, node) in graph.nodes.iter().enumerate() {
        if reachable[i] {
            let args = node.args.iter().map(|&a| new_index[a]).collect();
            new_index[i] = new_nodes.len();
            new_nodes.push(Node { op: node.op.clone(), args });
        }
    }
    Graph { nodes: new_nodes, output: new_index[graph.output] }
}

pub fn optimize(graph: &Graph) -> Graph {
    dce(&fold(graph))
}

// ── Execute (direct IR interpreter — no codegen backend yet) ────────────

pub fn eval_graph(graph: &Graph, inputs: &[f64]) -> f64 {
    let mut vals = vec![0.0_f64; graph.nodes.len()];
    for (i, node) in graph.nodes.iter().enumerate() {
        let a = node.args.first().map(|&x| vals[x]);
        let b = node.args.get(1).map(|&x| vals[x]);
        vals[i] = match &node.op {
            Op::Const(bits) => f64::from_bits(*bits),
            Op::Param(p)    => inputs[*p],
            Op::Add => a.unwrap() + b.unwrap(),
            Op::Sub => a.unwrap() - b.unwrap(),
            Op::Mul => a.unwrap() * b.unwrap(),
            Op::Div => a.unwrap() / b.unwrap(),
            Op::Lt  => if a.unwrap() < b.unwrap()  { 1.0 } else { 0.0 },
            Op::Gt  => if a.unwrap() > b.unwrap()  { 1.0 } else { 0.0 },
            Op::Le  => if a.unwrap() <= b.unwrap() { 1.0 } else { 0.0 },
            Op::Ge  => if a.unwrap() >= b.unwrap() { 1.0 } else { 0.0 },
            Op::Eq  => if a.unwrap() == b.unwrap() { 1.0 } else { 0.0 },
            Op::If  => if vals[node.args[0]] != 0.0 { vals[node.args[1]] } else { vals[node.args[2]] },
        };
    }
    vals[graph.output]
}

// ── Inspect: Graph → Lisp data ────────────────────────────────────────────

fn op_name(op: &Op) -> &'static str {
    match op {
        Op::Const(_) => "const", Op::Param(_) => "param",
        Op::Add => "add", Op::Sub => "sub", Op::Mul => "mul", Op::Div => "div",
        Op::Lt => "lt", Op::Gt => "gt", Op::Le => "le", Op::Ge => "ge", Op::Eq => "eq",
        Op::If => "if",
    }
}

pub fn to_value(graph: &Graph) -> Value {
    let nodes: Vec<Value> = graph.nodes.iter().enumerate().map(|(i, node)| {
        let mut row = vec![Value::Number(i as f64), Value::Symbol(op_name(&node.op).to_string())];
        match &node.op {
            Op::Const(bits) => row.push(Value::Number(f64::from_bits(*bits))),
            Op::Param(p)    => row.push(Value::Number(*p as f64)),
            _ => row.extend(node.args.iter().map(|&a| Value::Number(a as f64))),
        }
        crate::env::list(row)
    }).collect();
    crate::env::list(vec![crate::env::list(nodes), Value::Number(graph.output as f64)])
}
