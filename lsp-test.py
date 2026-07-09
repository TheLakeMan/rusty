#!/usr/bin/env python3
# lsp-test.py — scripted stdio session against rusty-lsp (Phase 5.2).
# Checks: init handshake, diagnostics with exact positions, completion
# harvested from a real interpreter env, hover for globals and special
# forms. Exits 0 and prints LSP-TEST OK on success.
import subprocess, json, sys

def frame(obj):
    b = json.dumps(obj).encode()
    return b"Content-Length: %d\r\n\r\n%s" % (len(b), b)

reqs = [
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}},
    {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{
        "uri":"file:///t.lisp","text":"(define (f x)\n  (+ x 1)\n(print (f 2))\n(print \"oops"}}},
    {"jsonrpc":"2.0","id":2,"method":"textDocument/completion","params":{
        "textDocument":{"uri":"file:///t.lisp"},"position":{"line":0,"character":0}}},
    {"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{
        "textDocument":{"uri":"file:///t.lisp"},"position":{"line":1,"character":3}}},
    {"jsonrpc":"2.0","id":4,"method":"textDocument/hover","params":{
        "textDocument":{"uri":"file:///t.lisp"},"position":{"line":0,"character":2}}},
    {"jsonrpc":"2.0","id":5,"method":"shutdown","params":{}},
    {"jsonrpc":"2.0","method":"exit"},
]
inp = b"".join(frame(r) for r in reqs)
out = subprocess.run(["./target/release/rusty-lsp"], input=inp,
                     capture_output=True, timeout=60).stdout

msgs, i = [], 0
while i < len(out):
    j = out.index(b"\r\n\r\n", i)
    ln = int(out[i:j].split(b":")[1].strip())
    msgs.append(json.loads(out[j+4:j+4+ln])); i = j+4+ln

diags = [d for m in msgs if m.get("method") == "textDocument/publishDiagnostics"
         for d in m["params"]["diagnostics"]]
comp  = next(m["result"] for m in msgs if m.get("id") == 2)
hov3  = next(m["result"] for m in msgs if m.get("id") == 3)
hov4  = next(m["result"] for m in msgs if m.get("id") == 4)

assert any(d["message"] == "unterminated string"
           and d["range"]["start"] == {"line":3,"character":7} for d in diags), diags
assert sum(d["message"] == "unclosed parenthesis" for d in diags) == 2, diags
labels = {x["label"] for x in comp}
assert {"map","defrust","graph-grad","agent-spawn","let"} <= labels, sorted(labels)[:10]
assert "builtin `+`" in hov3["contents"]["value"], hov3
assert "special form" in hov4["contents"]["value"], hov4
print("LSP-TEST OK")
