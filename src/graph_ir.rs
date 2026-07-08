//! graph_ir.rs — a computation-graph IR (inspired by XLA/TVM) over the same
//! restricted numeric subset `defrust` compiles (numbers, params, + - * /,
//! comparisons, if) plus the Phase-3.1 tensor ops (tensor-add/sub/mul/div,
//! matmul, transpose, tensor-sum). Built with hash-consing, so structurally identical
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
use std::rc::Rc;

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Op {
    Const(u64), // f64::to_bits — f64 itself isn't Eq/Hash, so we key on bits
    Param(usize),
    Add, Sub, Mul, Div,
    Lt, Gt, Le, Ge, Eq,
    If, // (cond, then, else)
    // Tensor ops (Phase 3.1). There are no tensor *literals* in the Expr
    // subset — tensors only enter a graph through Params — so constant
    // folding never fires on these; what they get from the pipeline is
    // hash-consing CSE, if-branch pruning, and DCE, all shape-agnostic.
    TAdd, TSub, TMul, TDiv, // elementwise, scalar broadcast (either side) at eval time
    MatMul,                 // rank-2 × rank-2
    Transpose,              // rank-2
    TSum,                   // tensor → scalar
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
                     if, and the tensor ops are supported", s
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
                    "tensor-add" | "tensor-sub" | "tensor-mul" | "tensor-div"
                        if items.len() == 3 =>
                    {
                        let a = build_num(ib, params, &items[1])?;
                        let b = build_num(ib, params, &items[2])?;
                        let op = match head.as_str() {
                            "tensor-add" => Op::TAdd, "tensor-sub" => Op::TSub,
                            "tensor-mul" => Op::TMul, _ => Op::TDiv,
                        };
                        Ok(ib.intern(op, vec![a, b]))
                    }
                    "matmul" if items.len() == 3 => {
                        let a = build_num(ib, params, &items[1])?;
                        let b = build_num(ib, params, &items[2])?;
                        Ok(ib.intern(Op::MatMul, vec![a, b]))
                    }
                    "transpose" if items.len() == 2 => {
                        let a = build_num(ib, params, &items[1])?;
                        Ok(ib.intern(Op::Transpose, vec![a]))
                    }
                    "tensor-sum" if items.len() == 2 => {
                        let a = build_num(ib, params, &items[1])?;
                        Ok(ib.intern(Op::TSum, vec![a]))
                    }
                    other => Err(format!("graph-ir: unsupported operator '{}'", other)),
                }
            } else {
                Err("graph-ir: unsupported expression".into())
            }
        }
        _ => Err("graph-ir: only numbers, params, + - * /, if, and the tensor ops are supported".into()),
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

/// Runtime value flowing through the graph: scalar or tensor. Tensors only
/// enter via Params (no tensor literals in the Expr subset), and the tensor
/// buffer is the same Rc'd flat row-major layout as `Value::Tensor`.
#[derive(Clone, Debug)]
pub enum GVal {
    Num(f64),
    Tensor { data: Rc<Vec<f64>>, shape: Vec<usize> },
}

fn num(v: &GVal, op: &str) -> Result<f64, String> {
    match v {
        GVal::Num(n) => Ok(*n),
        GVal::Tensor { shape, .. } => Err(format!(
            "graph-eval: {} expects a number, got a {} tensor — use the tensor-* ops",
            op, shape.iter().map(|d| d.to_string()).collect::<Vec<_>>().join("x")
        )),
    }
}

// Same semantics as interp.rs's tensor_binop2: tensor⊕tensor needs matching
// shapes, tensor⊕scalar broadcasts on either side, scalar⊕scalar is plain
// arithmetic (so tensor-add etc. degrade gracefully to numbers).
fn t_binop(a: &GVal, b: &GVal, name: &str, f: fn(f64, f64) -> f64) -> Result<GVal, String> {
    match (a, b) {
        (GVal::Tensor { data: xd, shape: xs }, GVal::Tensor { data: yd, shape: ys }) => {
            if xs != ys {
                return Err(format!("graph-eval: {}: shape mismatch {:?} vs {:?}", name, xs, ys));
            }
            let data: Vec<f64> = xd.iter().zip(yd.iter()).map(|(x, y)| f(*x, *y)).collect();
            Ok(GVal::Tensor { data: Rc::new(data), shape: xs.clone() })
        }
        (GVal::Tensor { data, shape }, GVal::Num(s)) =>
            Ok(GVal::Tensor { data: Rc::new(data.iter().map(|x| f(*x, *s)).collect()), shape: shape.clone() }),
        (GVal::Num(s), GVal::Tensor { data, shape }) =>
            Ok(GVal::Tensor { data: Rc::new(data.iter().map(|x| f(*s, *x)).collect()), shape: shape.clone() }),
        (GVal::Num(x), GVal::Num(y)) => Ok(GVal::Num(f(*x, *y))),
    }
}

fn t_matmul(a: &GVal, b: &GVal) -> Result<GVal, String> {
    match (a, b) {
        (GVal::Tensor { data: xd, shape: xs }, GVal::Tensor { data: yd, shape: ys }) => {
            if xs.len() != 2 || ys.len() != 2 {
                return Err("graph-eval: matmul: both arguments must be rank-2 tensors".into());
            }
            let (n, k) = (xs[0], xs[1]);
            let (k2, m) = (ys[0], ys[1]);
            if k != k2 {
                return Err(format!("graph-eval: matmul: inner dimensions differ ({} vs {})", k, k2));
            }
            let mut data = vec![0.0; n * m];
            for i in 0..n {
                for p in 0..k {
                    let x = xd[i * k + p];
                    for j in 0..m {
                        data[i * m + j] += x * yd[p * m + j];
                    }
                }
            }
            Ok(GVal::Tensor { data: Rc::new(data), shape: vec![n, m] })
        }
        _ => Err("graph-eval: matmul: both arguments must be tensors".into()),
    }
}

fn t_transpose(a: &GVal) -> Result<GVal, String> {
    match a {
        GVal::Tensor { data, shape } if shape.len() == 2 => {
            let (n, m) = (shape[0], shape[1]);
            let mut out = vec![0.0; n * m];
            for i in 0..n {
                for j in 0..m {
                    out[j * n + i] = data[i * m + j];
                }
            }
            Ok(GVal::Tensor { data: Rc::new(out), shape: vec![m, n] })
        }
        _ => Err("graph-eval: transpose: argument must be a rank-2 tensor".into()),
    }
}

pub fn eval_graph(graph: &Graph, inputs: &[GVal]) -> Result<GVal, String> {
    let mut vals: Vec<GVal> = Vec::with_capacity(graph.nodes.len());
    for node in &graph.nodes {
        let a = node.args.first().map(|&x| &vals[x]);
        let b = node.args.get(1).map(|&x| &vals[x]);
        let v = match &node.op {
            Op::Const(bits) => GVal::Num(f64::from_bits(*bits)),
            Op::Param(p)    => inputs[*p].clone(),
            Op::Add => GVal::Num(num(a.unwrap(), "+")? + num(b.unwrap(), "+")?),
            Op::Sub => GVal::Num(num(a.unwrap(), "-")? - num(b.unwrap(), "-")?),
            Op::Mul => GVal::Num(num(a.unwrap(), "*")? * num(b.unwrap(), "*")?),
            Op::Div => GVal::Num(num(a.unwrap(), "/")? / num(b.unwrap(), "/")?),
            Op::Lt  => GVal::Num(if num(a.unwrap(), "<")?  < num(b.unwrap(), "<")?  { 1.0 } else { 0.0 }),
            Op::Gt  => GVal::Num(if num(a.unwrap(), ">")?  > num(b.unwrap(), ">")?  { 1.0 } else { 0.0 }),
            Op::Le  => GVal::Num(if num(a.unwrap(), "<=")? <= num(b.unwrap(), "<=")? { 1.0 } else { 0.0 }),
            Op::Ge  => GVal::Num(if num(a.unwrap(), ">=")? >= num(b.unwrap(), ">=")? { 1.0 } else { 0.0 }),
            Op::Eq  => GVal::Num(if num(a.unwrap(), "=")? == num(b.unwrap(), "=")?  { 1.0 } else { 0.0 }),
            Op::If  => {
                let c = num(&vals[node.args[0]], "if")?;
                if c != 0.0 { vals[node.args[1]].clone() } else { vals[node.args[2]].clone() }
            }
            Op::TAdd => t_binop(a.unwrap(), b.unwrap(), "tensor-add", |x, y| x + y)?,
            Op::TSub => t_binop(a.unwrap(), b.unwrap(), "tensor-sub", |x, y| x - y)?,
            Op::TMul => t_binop(a.unwrap(), b.unwrap(), "tensor-mul", |x, y| x * y)?,
            Op::TDiv => t_binop(a.unwrap(), b.unwrap(), "tensor-div", |x, y| x / y)?,
            Op::MatMul    => t_matmul(a.unwrap(), b.unwrap())?,
            Op::Transpose => t_transpose(a.unwrap())?,
            Op::TSum => match a.unwrap() {
                GVal::Tensor { data, .. } => GVal::Num(data.iter().sum()),
                GVal::Num(n) => GVal::Num(*n),
            },
        };
        vals.push(v);
    }
    Ok(vals[graph.output].clone())
}

// ── Inspect: Graph → Lisp data ────────────────────────────────────────────

fn op_name(op: &Op) -> &'static str {
    match op {
        Op::Const(_) => "const", Op::Param(_) => "param",
        Op::Add => "add", Op::Sub => "sub", Op::Mul => "mul", Op::Div => "div",
        Op::Lt => "lt", Op::Gt => "gt", Op::Le => "le", Op::Ge => "ge", Op::Eq => "eq",
        Op::If => "if",
        Op::TAdd => "tensor-add", Op::TSub => "tensor-sub",
        Op::TMul => "tensor-mul", Op::TDiv => "tensor-div",
        Op::MatMul => "matmul", Op::Transpose => "transpose", Op::TSum => "tensor-sum",
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
