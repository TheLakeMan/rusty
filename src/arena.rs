//! arena.rs — Arena Allocator for Rusty (future optimization)
//!
//! The Arena pre-allocates slots to reduce heap fragmentation.
//! Currently dormant — arena_list() in eval.rs wraps list() directly.
//! To activate: integrate mark/sweep with eval's root set.
//!
//! NOTE: uses Rc which is single-threaded, so no global static.
//! Instantiate per-interpreter when wiring in.

use crate::env::Value;

#[allow(dead_code)]
pub struct Arena {
    slots:    Vec<Slot>,
    free:     Vec<usize>,
    capacity: usize,
}

#[allow(dead_code)]
struct Slot {
    value:  Value,
    marked: bool,
}

#[allow(dead_code)]
impl Arena {
    pub fn new(cap: usize) -> Self {
        let mut slots = Vec::with_capacity(cap);
        let mut free  = Vec::with_capacity(cap);
        for i in 0..cap {
            slots.push(Slot { value: Value::Nil, marked: false });
            free.push(i);
        }
        Arena { slots, free, capacity: cap }
    }

    pub fn alloc_list(&mut self, items: Vec<Value>) -> Value {
        if self.free.is_empty() { self.grow(); }
        let idx = self.free.pop().unwrap();
        self.slots[idx].value  = crate::env::list(items);
        self.slots[idx].marked = true;
        self.slots[idx].value.clone()
    }

    fn grow(&mut self) {
        let old = self.capacity;
        let new = old * 2;
        for i in old..new {
            self.slots.push(Slot { value: Value::Nil, marked: false });
            self.free.push(i);
        }
        self.capacity = new;
    }

    pub fn mark(&mut self, v: &Value) {
        match v {
            Value::List(rc) => {
                for item in rc.iter() { self.mark(item); }
            }
            Value::Lambda { env, .. } | Value::Macro { env, .. } | Value::Tool { env, .. } => {
                let frame = env.borrow();
                for val in frame.vars.values() { self.mark(val); }
            }
            _ => {}
        }
    }

    pub fn sweep(&mut self) {
        self.free.clear();
        for (i, slot) in self.slots.iter_mut().enumerate() {
            if !slot.marked {
                slot.value = Value::Nil;
                self.free.push(i);
            } else {
                slot.marked = false;
            }
        }
    }

    pub fn gc(&mut self, roots: &[&Value]) {
        for r in roots { self.mark(r); }
        self.sweep();
    }
}
