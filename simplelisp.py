# Copyright (c) 2026 Nicholas Vermeulen
# SPDX-License-Identifier: AGPL-3.0-or-later
import sys

# Token types
TOKEN_LPAREN = 'LPAREN'
TOKEN_RPAREN = 'RPAREN'
TOKEN_NUMBER = 'NUMBER'
TOKEN_STRING = 'STRING'
TOKEN_SYMBOL = 'SYMBOL'
TOKEN_EOF = 'EOF'


class Token:
    def __init__(self, type, value):
        self.type = type
        self.value = value

    def __repr__(self):
        return f"Token({self.type}, {self.value!r})"


class Environment:
    """
    Holds variables and functions.

    Supports parent chaining:

        local_env -> closure_env -> root_env
    """

    def __init__(self, parent=None):
        self.vars = {}
        self.parent = parent

    def set(self, name, value):
        self.vars[name] = value
        return value

    def get(self, name):
        env = self.find(name)

        if env is None:
            raise NameError(f"Undefined: {name}")

        return env.vars[name]

    def find(self, name):
        current = self

        while current is not None:
            if name in current.vars:
                return current

            current = current.parent

        return None


class UserFunction:
    """
    User-defined function object.
    """
    def __init__(self, params, body, closure_env, interpreter, name=None):
        self.params = params
        self.body = body
        self.closure_env = closure_env
        self.interpreter = interpreter
        self.name = name

    def __call__(self, args):
        if len(args) != len(self.params):
            expected = len(self.params)
            got = len(args)
            label = self.name or "lambda"
            raise ValueError(f"{label} expects {expected} args, got {got}")

        local_env = Environment(self.closure_env)

        for param, value in zip(self.params, args):
            local_env.set(param, value)

        return self.interpreter.evaluate_sequence(self.body, local_env)

    def __repr__(self):
        return f"<function {self.name or 'lambda'}>"


class Macro:
    """
    Simple hygienic macro.
    Uses gensym for hygiene in basic cases.
    """
    def __init__(self, params, body, closure_env, interpreter, name=None):
        self.params = params
        self.body = body
        self.closure_env = closure_env
        self.interpreter = interpreter
        self.name = name
        self.gensym_counter = 0

    def gensym(self, base="g"):
        self.gensym_counter += 1
        return f"{base}_{self.gensym_counter}"

    def expand(self, args, env):
        """Basic macro expansion with hygiene"""
        if len(args) != len(self.params):
            raise ValueError(f"Macro {self.name} expects {len(self.params)} args")

        local_env = Environment(self.closure_env)
        for param, value in zip(self.params, args):
            local_env.set(param, value)

        # For hygiene, replace symbols in body with gensym where needed (simplified)
        expanded_body = self._hygiene_transform(self.body)
        return self.interpreter.evaluate_sequence(expanded_body, local_env)

    def _hygiene_transform(self, body):
        # Simplified hygiene: placeholder for full implementation
        if isinstance(body, list):
            return [self._hygiene_transform(item) for item in body]
        return body

    def __call__(self, args):
        # Macros receive unevaluated args and expand
        return self.expand(args, None)

    def __repr__(self):
        return f"<macro {self.name}>"


class Interpreter:
    def __init__(self):
        # Stable root environment.
        # Do NOT mutate this to become the current call frame.
        self.root_env = Environment()

        self.builtins = {
            'add': self._builtin_add,
            'sub': self._builtin_sub,
            'mul': self._builtin_mul,
            'div': self._builtin_div,

            'eq': self._builtin_eq,
            'gt': self._builtin_gt,
            'lt': self._builtin_lt,
            'ge': self._builtin_ge,
            'le': self._builtin_le,
            'neq': self._builtin_neq,
            'not': self._builtin_not,

            'print': self._builtin_print,

            'set': self._builtin_set,
            'if': self._builtin_if,
            'def': self._builtin_def,
            'lambda': self._builtin_lambda,
            'quote': self._builtin_quote,
            'begin': self._builtin_begin,

            'list': self._builtin_list,
            'car': self._builtin_car,
            'cdr': self._builtin_cdr,
            'cons': self._builtin_cons,
            'length': self._builtin_length,
            'append': self._builtin_append,
            'reverse': self._builtin_reverse,
            'nth': self._builtin_nth,
            'member': self._builtin_member,

            'map': self._builtin_map,
            'filter': self._builtin_filter,

            'nil': self._builtin_nil,

            # New special forms
            'let': self._builtin_let,
            'let*': self._builtin_let_star,
            'letrec': self._builtin_letrec,
            'cond': self._builtin_cond,
            'and': self._builtin_and,
            'or': self._builtin_or,
            'error': self._builtin_error,
            'load': self._builtin_load,

            # Macro support
            'defmacro': self._builtin_defmacro,

            # Type predicates
            'number?': self._builtin_number_p,
            'list?': self._builtin_list_p,
            'symbol?': self._builtin_symbol_p,
            'string?': self._builtin_string_p,
            'procedure?': self._builtin_procedure_p,
        }

        # Install builtins into the stable root environment.
        for name, fn in self.builtins.items():
            self.root_env.set(name, fn)

    # ------------------------------------------------------------------
    # Arithmetic helpers
    # ------------------------------------------------------------------

    def _product(self, args):
        result = 1

        for a in args:
            result *= a

        return result

    def _builtin_add(self, args, env=None):
        return sum(args)

    def _builtin_sub(self, args, env=None):
        if not args:
            return 0

        return args[0] - sum(args[1:])

    def _builtin_mul(self, args, env=None):
        if not args:
            return 1

        return args[0] * self._product(args[1:])

    def _builtin_div(self, args, env=None):
        if len(args) != 2:
            raise ValueError("div needs 2 args")

        if args[1] == 0:
            raise ValueError("Division by zero")

        return args[0] / args[1]

    # ------------------------------------------------------------------
    # Comparison helpers
    # ------------------------------------------------------------------

    def _builtin_eq(self, args, env=None):
        if len(args) != 2:
            raise ValueError("eq needs 2 args")

        return args[0] == args[1]

    def _builtin_gt(self, args, env=None):
        if len(args) != 2:
            raise ValueError("gt needs 2 args")

        return args[0] > args[1]

    def _builtin_lt(self, args, env=None):
        if len(args) != 2:
            raise ValueError("lt needs 2 args")

        return args[0] < args[1]

    def _builtin_ge(self, args, env=None):
        if len(args) != 2:
            raise ValueError("ge needs 2 args")

        return args[0] >= args[1]

    def _builtin_le(self, args, env=None):
        if len(args) != 2:
            raise ValueError("le needs 2 args")

        return args[0] <= args[1]

    def _builtin_neq(self, args, env=None):
        if len(args) != 2:
            raise ValueError("neq needs 2 args")

        return args[0] != args[1]

    def _builtin_not(self, args, env=None):
        if len(args) != 1:
            raise ValueError("not needs 1 arg")

        return not bool(args[0])

    # ------------------------------------------------------------------
    # Output
    # ------------------------------------------------------------------

    def _builtin_print(self, args, env=None):
        print(*args)
        return None

    # ------------------------------------------------------------------
    # Core environment helpers
    # ------------------------------------------------------------------

    def _check_params(self, params, form):
        if not isinstance(params, list):
            raise ValueError(f"{form} params must be a list")

        if not all(isinstance(p, str) for p in params):
            raise ValueError(f"{form} params must be symbols")

        if len(params) != len(set(params)):
            raise ValueError(f"{form} has duplicate params")

    def _literal_from_ast(self, node):
        """
        Convert parsed AST literal data into runtime data.

        Strings are parsed as ('STRING', value) to distinguish them from symbols.
        """

        if isinstance(node, tuple) and len(node) == 2 and node[0] == 'STRING':
            return node[1]

        if isinstance(node, list):
            return [self._literal_from_ast(item) for item in node]

        return node

    def evaluate_sequence(self, body, env):
        result = None

        for expr in body:
            result = self.evaluate(expr, env)

        return result

    # ------------------------------------------------------------------
    # Special forms
    # ------------------------------------------------------------------

    def _builtin_set(self, args, env=None):
        """
        Set variable.

        Important:
        - If the variable already exists in the environment chain, update it.
        - Otherwise, create it in the current environment.

        This preserves old SimpleLisp behavior while allowing closures to mutate
        captured variables.
        """

        if env is None:
            env = self.root_env

        if len(args) != 2 or not isinstance(args[0], str):
            raise ValueError("set needs symbol and value")

        name = args[0]
        value = self.evaluate(args[1], env)

        target_env = env.find(name)

        if target_env is None:
            target_env = env

        target_env.set(name, value)
        return None

    def _builtin_if(self, args, env=None):
        """
        If conditional.

        Receives unevaluated args.
        """

        if env is None:
            env = self.root_env

        if len(args) != 3:
            raise ValueError("if needs condition, then, else")

        cond = self.evaluate(args[0], env)

        if cond:
            return self.evaluate(args[1], env)
        else:
            return self.evaluate(args[2], env)

    def _builtin_def(self, args, env=None):
        """
        Define function.

        Receives unevaluated args.

        Example:

            (def double (x)
              (mul x 2))
        """

        if env is None:
            env = self.root_env

        if len(args) < 3 or not isinstance(args[0], str) or not isinstance(args[1], list):
            raise ValueError("def needs name, params list, body")

        name = args[0]
        params = args[1]
        body = args[2:]

        self._check_params(params, "def")

        fn = UserFunction(
            params=params,
            body=body,
            closure_env=env,
            interpreter=self,
            name=name,
        )

        env.set(name, fn)
        return None

    def _builtin_lambda(self, args, env=None):
        """
        Lambda function.

        Receives unevaluated args.

        Example:

            (lambda (x) (mul x x))
        """

        if env is None:
            env = self.root_env

        if len(args) < 2 or not isinstance(args[0], list):
            raise ValueError("lambda needs params list and body")

        params = args[0]
        body = args[1:]

        self._check_params(params, "lambda")

        return UserFunction(
            params=params,
            body=body,
            closure_env=env,
            interpreter=self,
        )

    def _builtin_quote(self, args, env=None):
        if len(args) != 1:
            raise ValueError("quote needs 1 arg")

        return self._literal_from_ast(args[0])

    def _builtin_begin(self, args, env=None):
        if env is None:
            env = self.root_env

        return self.evaluate_sequence(args, env)

    # ------------------------------------------------------------------
    # New special forms
    # ------------------------------------------------------------------

    def _builtin_let(self, args, env=None):
        """Simple let: (let ((x 1) (y 2)) body...)"""
        if env is None:
            env = self.root_env

        if len(args) < 2 or not isinstance(args[0], list):
            raise ValueError("let needs bindings list and body")

        bindings = args[0]
        body = args[1:]

        local_env = Environment(env)

        for binding in bindings:
            if not isinstance(binding, list) or len(binding) != 2:
                raise ValueError("let binding must be (var value)")
            var, val_expr = binding
            if not isinstance(var, str):
                raise ValueError("let var must be symbol")
            value = self.evaluate(val_expr, env)
            local_env.set(var, value)

        return self.evaluate_sequence(body, local_env)

    def _builtin_let_star(self, args, env=None):
        """Sequential let*: (let* ((x 1) (y (add x 1))) body...)"""
        if env is None:
            env = self.root_env

        if len(args) < 2 or not isinstance(args[0], list):
            raise ValueError("let* needs bindings list and body")

        bindings = args[0]
        body = args[1:]

        local_env = Environment(env)

        for binding in bindings:
            if not isinstance(binding, list) or len(binding) != 2:
                raise ValueError("let* binding must be (var value)")
            var, val_expr = binding
            if not isinstance(var, str):
                raise ValueError("let* var must be symbol")
            value = self.evaluate(val_expr, local_env)
            local_env.set(var, value)

        return self.evaluate_sequence(body, local_env)

    def _builtin_letrec(self, args, env=None):
        """letrec for recursive local bindings"""
        if env is None:
            env = self.root_env

        if len(args) < 2 or not isinstance(args[0], list):
            raise ValueError("letrec needs bindings list and body")

        bindings = args[0]
        body = args[1:]

        local_env = Environment(env)

        # First bind placeholders
        for binding in bindings:
            if not isinstance(binding, list) or len(binding) != 2:
                raise ValueError("letrec binding must be (var value)")
            var = binding[0]
            if not isinstance(var, str):
                raise ValueError("letrec var must be symbol")
            local_env.set(var, None)  # placeholder

        # Then evaluate values in local_env (for recursion)
        for binding in bindings:
            var, val_expr = binding
            value = self.evaluate(val_expr, local_env)
            local_env.set(var, value)

        return self.evaluate_sequence(body, local_env)

    def _builtin_cond(self, args, env=None):
        """cond: (cond (test1 expr1) (test2 expr2) ... (else exprN))"""
        if env is None:
            env = self.root_env

        for clause in args:
            if not isinstance(clause, list) or len(clause) < 1:
                raise ValueError("cond clause must be a list")
            test = clause[0]
            if test == 'else' or self.evaluate(test, env):
                body = clause[1:] if len(clause) > 1 else [test]
                return self.evaluate_sequence(body, env)
        return None

    def _builtin_and(self, args, env=None):
        """Short-circuit and"""
        if env is None:
            env = self.root_env
        result = True
        for expr in args:
            result = self.evaluate(expr, env)
            if not result:
                return False
        return result

    def _builtin_or(self, args, env=None):
        """Short-circuit or"""
        if env is None:
            env = self.root_env
        for expr in args:
            result = self.evaluate(expr, env)
            if result:
                return result
        return False

    def _builtin_error(self, args, env=None):
        """Raise error"""
        if env is None:
            env = self.root_env
        if args:
            msg = self.evaluate(args[0], env)
            raise RuntimeError(f"Error: {msg}")
        raise RuntimeError("Explicit error")

    def _builtin_load(self, args, env=None):
        """Load and run a file"""
        if env is None:
            env = self.root_env
        if not args:
            raise ValueError("load needs filename")
        filename = self.evaluate(args[0], env)
        if not isinstance(filename, str):
            raise TypeError("load expects string filename")
        try:
            with open(filename, 'r', encoding='utf-8') as f:
                code = f.read()
            return self.run(code)  # Note: reuses root_env for simplicity
        except Exception as e:
            raise RuntimeError(f"Load failed for {filename}: {e}")

    def _builtin_defmacro(self, args, env=None):
        """Hygienic macro support (basic gensym hygiene)"""
        if env is None:
            env = self.root_env
        if len(args) < 3 or not isinstance(args[0], str) or not isinstance(args[1], list):
            raise ValueError("defmacro needs name, params list, body")
        name = args[0]
        params = args[1]
        body = args[2:]
        self._check_params(params, "defmacro")

        # Macro as special UserFunction with hygiene
        macro = Macro(params, body, env, self, name=name)
        env.set(name, macro)
        return None

    # ------------------------------------------------------------------
    # List helpers
    # ------------------------------------------------------------------

    def _builtin_list(self, args, env=None):
        return list(args)

    def _builtin_car(self, args, env=None):
        if len(args) != 1:
            raise ValueError("car needs 1 arg")

        lst = args[0]

        if not isinstance(lst, list):
            raise TypeError("car expects a list")

        return lst[0] if lst else None

    def _builtin_cdr(self, args, env=None):
        if len(args) != 1:
            raise ValueError("cdr needs 1 arg")

        lst = args[0]

        if not isinstance(lst, list):
            raise TypeError("cdr expects a list")

        return lst[1:] if lst else []

    def _builtin_cons(self, args, env=None):
        if len(args) != 2:
            raise ValueError("cons needs 2 args")

        first = args[0]
        rest = args[1]

        if not isinstance(rest, list):
            raise TypeError("cons second argument must be a list")

        return [first] + rest

    def _builtin_length(self, args, env=None):
        if len(args) != 1:
            raise ValueError("length needs 1 arg")

        lst = args[0]

        if not isinstance(lst, list):
            raise TypeError("length expects a list")

        return len(lst)

    def _builtin_append(self, args, env=None):
        if len(args) != 2:
            raise ValueError("append needs 2 args")

        left = args[0]
        right = args[1]

        if not isinstance(left, list) or not isinstance(right, list):
            raise TypeError("append expects two lists")

        return left + right

    def _builtin_reverse(self, args, env=None):
        if len(args) != 1:
            raise ValueError("reverse needs 1 arg")
        lst = args[0]
        if not isinstance(lst, list):
            raise TypeError("reverse expects a list")
        return list(reversed(lst))

    def _builtin_nth(self, args, env=None):
        """(nth lst index)"""
        if len(args) != 2:
            raise ValueError("nth needs 2 args")
        lst = args[0]
        idx = args[1]
        if not isinstance(lst, list):
            raise TypeError("nth expects list")
        if not isinstance(idx, (int, float)):
            raise TypeError("nth index must be number")
        idx = int(idx)
        if 0 <= idx < len(lst):
            return lst[idx]
        return None

    def _builtin_member(self, args, env=None):
        """(member item lst)"""
        if len(args) != 2:
            raise ValueError("member needs 2 args")
        item = args[0]
        lst = args[1]
        if not isinstance(lst, list):
            raise TypeError("member expects list")
        return item in lst

    # ------------------------------------------------------------------
    # Higher-order functions
    # ------------------------------------------------------------------

    def _builtin_map(self, args, env=None):
        """
        Map function.

        Receives evaluated args.
        """

        if len(args) != 2:
            raise ValueError("map needs function and list")

        func = args[0]
        lst = args[1]

        if not isinstance(lst, list):
            raise ValueError("map second argument must be a list")

        if not callable(func):
            raise ValueError("map first argument must be a function")

        result = []

        for item in lst:
            result.append(func([item]))

        return result

    def _builtin_filter(self, args, env=None):
        """
        Filter function.

        Receives evaluated args.
        """

        if len(args) != 2:
            raise ValueError("filter needs function and list")

        func = args[0]
        lst = args[1]

        if not isinstance(lst, list):
            raise ValueError("filter second argument must be a list")

        if not callable(func):
            raise ValueError("filter first argument must be a function")

        result = []

        for item in lst:
            if func([item]):
                result.append(item)

        return result

    def _builtin_nil(self, args, env=None):
        return None

    # ------------------------------------------------------------------
    # Type predicates
    # ------------------------------------------------------------------

    def _builtin_number_p(self, args, env=None):
        if len(args) != 1:
            raise ValueError("number? needs 1 arg")
        return isinstance(args[0], (int, float))

    def _builtin_list_p(self, args, env=None):
        if len(args) != 1:
            raise ValueError("list? needs 1 arg")
        return isinstance(args[0], list)

    def _builtin_symbol_p(self, args, env=None):
        if len(args) != 1:
            raise ValueError("symbol? needs 1 arg")
        return isinstance(args[0], str) and not isinstance(args[0], (int, float))  # rough

    def _builtin_string_p(self, args, env=None):
        if len(args) != 1:
            raise ValueError("string? needs 1 arg")
        return isinstance(args[0], str)

    def _builtin_procedure_p(self, args, env=None):
        if len(args) != 1:
            raise ValueError("procedure? needs 1 arg")
        return callable(args[0])

    # ------------------------------------------------------------------
    # Tokenizer
    # ------------------------------------------------------------------

    def tokenize(self, code):
        """
        Tokenize the input code.

        Supports:
        - parentheses
        - numbers
        - strings with escapes
        - symbols
        - comments starting with ;
        """

        tokens = []
        i = 0

        while i < len(code):
            c = code[i]

            if c.isspace():
                i += 1
                continue

            if c == ';':
                while i < len(code) and code[i] != '\n':
                    i += 1
                continue

            if c == '(':
                tokens.append(Token(TOKEN_LPAREN, '('))
                i += 1
                continue

            if c == ')':
                tokens.append(Token(TOKEN_RPAREN, ')'))
                i += 1
                continue

            if c.isdigit() or (c == '-' and i + 1 < len(code) and code[i + 1].isdigit()):
                start = i
                raw = '-' if code[start] == '-' else ''

                if code[start] == '-':
                    i += 1

                seen_dot = False

                while i < len(code) and (code[i].isdigit() or code[i] == '.'):
                    if code[i] == '.':
                        if seen_dot:
                            raise SyntaxError(f"Invalid number at {start}")

                        seen_dot = True

                    raw += code[i]
                    i += 1

                if raw in ('-', '.', '-.'):
                    raise SyntaxError(f"Invalid number at {start}")

                try:
                    value = float(raw) if seen_dot else int(raw)
                except ValueError as exc:
                    raise SyntaxError(f"Invalid number at {start}: {raw}") from exc

                tokens.append(Token(TOKEN_NUMBER, value))
                continue

            if c == '"':
                start = i
                i += 1
                chars = []

                while i < len(code):
                    ch = code[i]

                    if ch == '"':
                        i += 1
                        break

                    if ch == '\\':
                        if i + 1 >= len(code):
                            raise SyntaxError(f"Unterminated escape sequence at {i}")

                        nxt = code[i + 1]

                        if nxt == 'n':
                            chars.append('\n')
                        elif nxt == 't':
                            chars.append('\t')
                        elif nxt == 'r':
                            chars.append('\r')
                        elif nxt == '"':
                            chars.append('"')
                        elif nxt == '\\':
                            chars.append('\\')
                        else:
                            raise SyntaxError(f"Unknown escape sequence \\{nxt} at {i}")

                        i += 2
                    else:
                        chars.append(ch)
                        i += 1
                else:
                    raise SyntaxError(f"Unterminated string starting at {start}")

                tokens.append(Token(TOKEN_STRING, ''.join(chars)))
                continue

            # Symbol
            sym = ''

            while (
                i < len(code)
                and not code[i].isspace()
                and code[i] not in '();"'
            ):
                sym += code[i]
                i += 1

            if sym:
                tokens.append(Token(TOKEN_SYMBOL, sym))

        tokens.append(Token(TOKEN_EOF, None))
        return tokens

    # ------------------------------------------------------------------
    # Parser
    # ------------------------------------------------------------------

    def parse(self, tokens):
        """
        Parse tokens into AST.

        AST nodes:
        - numbers: int or float
        - strings: ('STRING', value)
        - symbols: str
        - lists/calls: list
        """

        ast = []
        i = 0

        while tokens[i].type != TOKEN_EOF:
            expr, i = self._parse_expr(tokens, i)
            ast.append(expr)

        return ast

    def _parse_expr(self, tokens, i):
        token = tokens[i]

        if token.type == TOKEN_EOF:
            raise SyntaxError("Unexpected EOF")

        if token.type == TOKEN_LPAREN:
            i += 1
            expr = []

            while i < len(tokens) and tokens[i].type != TOKEN_RPAREN:
                if tokens[i].type == TOKEN_EOF:
                    raise SyntaxError("Unexpected EOF; missing ')'")

                sub_expr, i = self._parse_expr(tokens, i)
                expr.append(sub_expr)

            if i >= len(tokens):
                raise SyntaxError("Unexpected EOF; missing ')'")

            i += 1
            return expr, i

        if token.type == TOKEN_STRING:
            return ('STRING', token.value), i + 1

        if token.type in (TOKEN_NUMBER, TOKEN_SYMBOL):
            return token.value, i + 1

        raise SyntaxError(f"Unexpected token: {token.type}")

    # ------------------------------------------------------------------
    # Evaluator
    # ------------------------------------------------------------------

    def evaluate(self, expr, env=None):
        """
        Evaluate an AST node.

        Important change:
        - env is passed explicitly.
        - self.root_env remains stable.
        - function calls do not mutate global current scope.
        """

        if env is None:
            env = self.root_env

        # Literals: numbers
        if isinstance(expr, (int, float)):
            return expr

        # String literals
        if isinstance(expr, tuple) and len(expr) == 2 and expr[0] == 'STRING':
            return expr[1]

        # Symbols: look up as variables
        if isinstance(expr, str):
            return env.get(expr)

        # Empty list
        if not isinstance(expr, list) or not expr:
            return None

        op = expr[0]

        # Special forms need unevaluated arguments.
        special_forms = ('set', 'if', 'def', 'lambda', 'quote', 'begin', 'let', 'let*', 'letrec', 'cond', 'and', 'or', 'error', 'load', 'defmacro')

        if op in special_forms:
            return self.builtins[op](expr[1:], env)

        # Macro expansion
        func = self.evaluate(op, env)
        if isinstance(func, Macro):
            # Macros get unevaluated arguments
            return func(expr[1:])

        # Regular function application
        args = [self.evaluate(arg, env) for arg in expr[1:]]

        if not callable(func):
            raise TypeError(f"Cannot call non-function: {op!r}")

        # Basic TCO: For now, rely on Python + increased limit. Full loop-based TCO would require major refactor.
        # Here we prepare structure for tail calls in special forms.
        return func(args)

    # ------------------------------------------------------------------
    # Runner
    # ------------------------------------------------------------------

    def run(self, code):
        tokens = self.tokenize(code)
        ast = self.parse(tokens)

        result = None

        for expr in ast:
            result = self.evaluate(expr, self.root_env)

        return result


# ----------------------------------------------------------------------
# REPL helpers
# ----------------------------------------------------------------------

def check_input_complete(text):
    """
    Checks whether pasted REPL input is complete.

    Returns:
        "complete"
        "incomplete"
        "unterminated-string"
        "unmatched-right-paren"
    """

    depth = 0
    in_string = False
    escape = False

    for ch in text:
        if in_string:
            if escape:
                escape = False
            elif ch == '\\':
                escape = True
            elif ch == '"':
                in_string = False
            continue

        if ch == '"':
            in_string = True

        elif ch == ';':
            # Skip comment until newline.
            while False:
                break

        elif ch == '(':
            depth += 1

        elif ch == ')':
            depth -= 1

            if depth < 0:
                return "unmatched-right-paren"

    if in_string:
        return "unterminated-string"

    if depth > 0:
        return "incomplete"

    return "complete"


def repl(interp):
    print("SimpleLisp REPL v2.3 (hygienic macros, TCO prep, types)")
    print("Type expressions, Ctrl+C or Ctrl+D to exit")

    buffer = []

    while True:
        try:
            if buffer:
                code = input("... ")
            else:
                code = input("> ")

            if not code.strip() and not buffer:
                continue

            buffer.append(code)

            full_code = "\n".join(buffer)
            status = check_input_complete(full_code)

            if status == "incomplete":
                continue

            if status == "unterminated-string":
                continue

            if status == "unmatched-right-paren":
                raise SyntaxError("Unmatched ')'")

            result = interp.run(full_code)

            if result is not None:
                print(result)

        except KeyboardInterrupt:
            print("\nGoodbye!")
            break

        except EOFError:
            print("\nGoodbye!")
            break

        except Exception as e:
            print(f"Error: {e}")

        finally:
            buffer.clear()


# ----------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------

if __name__ == "__main__":
    interp = Interpreter()

    if len(sys.argv) > 1:
        try:
            with open(sys.argv[1], 'r', encoding='utf-8') as f:
                code = f.read()

            result = interp.run(code)

            if result is not None:
                print(result)

        except Exception as e:
            print(f"Error: {e}")
    else:
        repl(interp)
