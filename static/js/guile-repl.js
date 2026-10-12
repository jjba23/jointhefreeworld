/* guile-repl.js

Copyright © Josep Bigorra <jjbigorra@gmail.com>

jointhefreeworld.org is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

jointhefreeworld.org is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with jointhefreeworld.org.  If not, see <https://www.gnu.org/licenses/>.
*/

// @ts-check
"use strict";

/*
 * The free world REPL: a small Guile Scheme that runs in the visitor's
 * browser, in one file and with no dependencies.
 *
 * Reading, evaluating and printing all live here; the page only hands over a
 * port to print to and a way to expand the reference. The surface this
 * interpreter provides is described by REFERENCE below, which is what the
 * page renders as the expandable procedure list *and* what `(help)' prints,
 * so the documentation cannot drift away from the implementation.
 *
 * Deliberate simplifications (also stated on the page):
 *   - numbers are exact integers or inexact doubles: no rationals, no bignums
 *   - no macros, no modules, no ports, no exception handling, no `values'
 *   - pairs are immutable, so `set-car!' and `set-cdr!' are absent
 *   - evaluation is capped by steps and by wall clock, so a runaway loop
 *     cannot lock the tab
 *
 * For poking at it from the browser console: window.jfwGuile.run("(+ 1 2)").
 */
(function () {
    /* ------------------------------------------------------------------ */
    /* 1. Values                                                          */
    /* ------------------------------------------------------------------ */

    /** The Guile release this emulation follows. */
    const GUILE_VERSION = "3.0.11";

    /** A Scheme symbol. Interned, so `eq?' on symbols is object identity. */
    class Sym {
        /** @param {string} name */
        constructor(name) {
            this.name = name;
        }
    }

    /** @type {Map<string, Sym>} */
    const symbolTable = new Map();

    /**
     * @param {string} name
     * @returns {Sym}
     */
    const intern = (name) => {
        let symbol = symbolTable.get(name);
        if (!symbol) {
            symbol = new Sym(name);
            symbolTable.set(name, symbol);
        }
        return symbol;
    };

    /** A mutable pair. The empty list is represented by `null'. */
    class Pair {
        /** @param {any} car @param {any} cdr */
        constructor(car, cdr) {
            this.car = car;
            this.cdr = cdr;
        }
    }

    /** A Scheme character. */
    class Char {
        /** @param {number} code */
        constructor(code) {
            this.code = code;
        }
    }

    /**
     * An inexact number: a JavaScript double. Exact numbers are plain
     * integers, so the two kinds never mix by accident and `(eqv? 1.0 1)'
     * can answer #f the way Guile does. Rationals are still not modelled.
     */
    class Inexact {
        /** @param {number} value */
        constructor(value) {
            this.value = value;
        }
    }

    /** A Scheme vector. */
    class Vector {
        /** @param {any[]} items */
        constructor(items) {
            this.items = items;
        }
    }

    /**
     * A compound procedure: parameters, body and the environment it closed
     * over. NAME is only for printing.
     */
    class Closure {
        /**
         * @param {string[]} params
         * @param {string|null} rest
         * @param {any[]} body
         * @param {Frame} env
         * @param {string|null} name
         */
        constructor(params, rest, body, env, name) {
            this.params = params;
            this.rest = rest;
            this.body = body;
            this.env = env;
            this.name = name;
        }

        /** How Guile prints it: #<procedure square (x)> */
        describe() {
            const printed = this.params.slice();
            if (this.rest) printed.push(".");
            if (this.rest) printed.push(this.rest);
            const signature = "(" + printed.join(" ") + ")";
            return "#<procedure " + (this.name ? this.name + " " : "") + signature + ">";
        }
    }

    /** A primitive: SPEC is its entry in REFERENCE, which holds the code. */
    class Primitive {
        /** @param {any} spec */
        constructor(spec) {
            this.spec = spec;
        }

        get name() {
            return this.spec.name;
        }

        /** How Guile prints it: #<procedure car (_)> */
        describe() {
            return "#<procedure " + this.spec.name + " (_)>";
        }
    }

    /** The value of a definition or mutation; Guile's REPL prints nothing. */
    const UNSPECIFIED = Object.freeze({ unspecified: true });

    /** A slot filled in later by `letrec'; reading it early is an error. */
    const UNINITIALIZED = Object.freeze({ uninitialized: true });

    /** Anything the reader or the evaluator refuses to accept. */
    class SchemeError extends Error {}

    /** The chunk ended inside an open form, so the REPL keeps reading. */
    class IncompleteInput extends Error {}

    /* ------------------------------------------------------------------ */
    /* 2. Small helpers                                                   */
    /* ------------------------------------------------------------------ */

    const isPair = (v) => v instanceof Pair;
    const isSym = (v) => v instanceof Sym;
    const isChar = (v) => v instanceof Char;
    const isVector = (v) => v instanceof Vector;
    const isInexact = (v) => v instanceof Inexact;
    const isNumber = (v) => typeof v === "number" || v instanceof Inexact;
    const isProcedure = (v) => v instanceof Closure || v instanceof Primitive;

    /** The double behind a number, exact or not. */
    const num = (v) => (v instanceof Inexact ? v.value : v);

    /** Did any argument carry inexactness? Then the result does too. */
    const anyInexact = (values) => values.some((value) => value instanceof Inexact);

    /**
     * Arithmetic answers with an exact integer when it can, and with an
     * inexact number otherwise: (floor 2.7) is 2.0, (/ 6 3) is 2.
     * @param {number} value
     * @param {boolean} inexact
     * @returns {any}
     */
    const numericResult = (value, inexact) => (inexact || !Number.isInteger(value) ? new Inexact(value) : value);

    /** Only #f is false in Scheme. */
    const isFalse = (v) => v === false;

    /**
     * The elements of LIST. An improper list is an error, as in Guile.
     * @param {any} list
     * @param {any} spec the primitive asking, for the error message
     * @returns {any[]}
     */
    const needList = (list, spec) => {
        const items = [];
        let node = list;
        while (node instanceof Pair) {
            items.push(node.car);
            node = node.cdr;
        }
        if (node !== null) {
            throw new SchemeError("In procedure " + spec.name
                + ": Wrong type (expecting list): " + writeValue(list));
        }
        return items;
    };

    /** @param {any} list @returns {boolean} */
    const isList = (list) => {
        let node = list;
        while (node instanceof Pair) node = node.cdr;
        return node === null;
    };

    /**
     * @param {any[]} items
     * @param {any} tail
     * @returns {any} a list built from ITEMS, ending in TAIL
     */
    const arrayToList = (items, tail = null) => {
        let list = tail;
        for (let i = items.length - 1; i >= 0; i -= 1) list = new Pair(items[i], list);
        return list;
    };

    /* --- Type checks, worded the way Guile words them ---------------- */

    /**
     * @param {any} value
     * @param {string} expected
     * @param {any} spec
     */
    const wrongType = (value, expected, spec) => {
        throw new SchemeError("In procedure " + spec.name
            + ": Wrong type (expecting " + expected + "): " + writeValue(value));
    };

    /** @param {any} v @param {any} spec @returns {any} */
    const needPair = (v, spec) => (v instanceof Pair ? v : wrongType(v, "pair", spec));
    /** @param {any} v @param {any} spec @returns {number} the double behind it */
    const needNumber = (v, spec) => (isNumber(v) ? num(v) : wrongType(v, "number", spec));
    /** Indices and radixes want an exact integer, as in Guile. */
    const needExactInteger = (v, spec) => (typeof v === "number" && Number.isInteger(v) ? v : wrongType(v, "exact integer", spec));
    /** Some procedures also take 3.0 where an integer is meant. */
    const needInteger = (v, spec) => {
        const value = needNumber(v, spec);
        return Number.isInteger(value) ? value : wrongType(v, "integer", spec);
    };
    /** @param {any} v @param {any} spec @returns {string} */
    const needString = (v, spec) => (typeof v === "string" ? v : wrongType(v, "string", spec));
    /** @param {any} v @param {any} spec @returns {Sym} */
    const needSymbol = (v, spec) => (v instanceof Sym ? v : wrongType(v, "symbol", spec));
    /** @param {any} v @param {any} spec @returns {Char} */
    const needChar = (v, spec) => (v instanceof Char ? v : wrongType(v, "char", spec));
    /** @param {any} v @param {any} spec @returns {Vector} */
    const needVector = (v, spec) => (v instanceof Vector ? v : wrongType(v, "vector", spec));
    /** @param {any} v @param {any} spec @returns {any} */
    const needProcedure = (v, spec) => (isProcedure(v) ? v : wrongType(v, "procedure", spec));

    /* --- Printing ---------------------------------------------------- */

    /** @param {number} n @returns {string} */
    const printNumber = (n) => {
        if (Number.isNaN(n)) return "+nan.0";
        if (n === Infinity) return "+inf.0";
        if (n === -Infinity) return "-inf.0";
        return String(n);
    };

    /** Inexact numbers keep their decimal point, as Guile's do. */
    const printInexact = (n) => {
        const text = printNumber(n);
        return /^[-+0-9.]+$/.test(text) && !text.includes(".") ? text + ".0" : text;
    };

    const CHAR_NAMES = { 0: "nul", 7: "alarm", 8: "backspace", 9: "tab", 10: "newline", 13: "return", 27: "escape", 32: "space", 127: "delete" };

    /** The inside of a list's parentheses, dotted tail included. */
    const writeTail = (node) => {
        const parts = [];
        let current = node;
        while (current instanceof Pair) {
            parts.push(writeValue(current.car));
            current = current.cdr;
        }
        if (current !== null) parts.push(".", writeValue(current));
        return parts.join(" ");
    };

    /**
     * `write': machines read this back.
     * @param {any} value
     * @returns {string}
     */
    const writeValue = (value) => {
        if (value === null) return "()";
        if (value === UNSPECIFIED || value === UNINITIALIZED) return "#<unspecified>";
        if (typeof value === "boolean") return value ? "#t" : "#f";
        if (value instanceof Inexact) return printInexact(value.value);
        if (typeof value === "number") return printNumber(value);
        if (typeof value === "string") {
            return '"' + value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')
                .replace(/\n/g, "\\n").replace(/\t/g, "\\t") + '"';
        }
        if (value instanceof Sym) return value.name;
        if (value instanceof Char) {
            const named = CHAR_NAMES[value.code];
            return "#\\" + (named || String.fromCodePoint(value.code));
        }
        if (value instanceof Pair) return "(" + writeTail(value) + ")";
        if (value instanceof Vector) return "#(" + value.items.map(writeValue).join(" ") + ")";
        if (isProcedure(value)) return value.describe();
        return "#<unknown>";
    };

    /**
     * `display': for humans. Strings lose their quotes, chars are raw.
     * @param {any} value
     * @returns {string}
     */
    const displayValue = (value) => {
        if (typeof value === "string") return value;
        if (value instanceof Char) return String.fromCodePoint(value.code);
        return writeValue(value);
    };

    /* --- Equality ---------------------------------------------------- */

    /** @param {any} x @param {any} y @returns {boolean} */
    const eqv = (x, y) => {
        if (isNumber(x) && isNumber(y)) {
            // Exactness is part of the identity: (eqv? 1.0 1) is #f.
            if (isInexact(x) !== isInexact(y)) return false;
            const left = num(x);
            const right = num(y);
            return left === right || (Number.isNaN(left) && Number.isNaN(right));
        }
        if (x instanceof Char && y instanceof Char) return x.code === y.code;
        if (x instanceof Char || y instanceof Char) return false;
        return x === y;
    };

    /** @param {any} x @param {any} y @returns {boolean} */
    const eq = (x, y) => eqv(x, y) || (x instanceof Sym && y instanceof Sym && x.name === y.name);

    /** @param {any} x @param {any} y @returns {boolean} */
    const equal = (x, y) => {
        if (eqv(x, y)) return true;
        if (x instanceof Pair && y instanceof Pair) return equal(x.car, y.car) && equal(x.cdr, y.cdr);
        if (x instanceof Vector && y instanceof Vector) {
            return x.items.length === y.items.length
                && x.items.every((item, index) => equal(item, y.items[index]));
        }
        return false;
    };

    /* ------------------------------------------------------------------ */
    /* 3. The reader                                                      */
    /* ------------------------------------------------------------------ */

    const INTEGER_RE = /^[+-]?[0-9]+$/;
    const DECIMAL_RE = /^[+-]?(?:[0-9]+\.[0-9]*|\.[0-9]+|[0-9]+)(?:[eE][+-]?[0-9]+)?$/;

    /**
     * One numeric tower level: whatever a JavaScript double can hold, plus
     * Guile's infinity and NaN literals.
     * @param {string} text
     * @returns {number|undefined} undefined when TEXT is not a number
     */
    const parseNumberLiteral = (text) => {
        if (INTEGER_RE.test(text)) return parseInt(text, 10);
        if (DECIMAL_RE.test(text)) return new Inexact(parseFloat(text));
        if (text === "+inf.0") return new Inexact(Infinity);
        if (text === "-inf.0") return new Inexact(-Infinity);
        if (text === "+nan.0") return new Inexact(NaN);
        return undefined;
    };

    /** Turns source text into Pairs, and refuses to turn anything else. */
    class Reader {
        /** @param {string} source */
        constructor(source) {
            this.source = source;
            this.pos = 0;
        }

        atEnd() {
            return this.pos >= this.source.length;
        }

        /** Whitespace, `;' comments, `#|…|#' blocks and `#;' datums. */
        skipAtmosphere() {
            for (;;) {
                const ch = this.source[this.pos];
                if (ch === undefined) return;
                if (/\s/.test(ch)) {
                    this.pos += 1;
                } else if (ch === ";") {
                    while (this.pos < this.source.length && this.source[this.pos] !== "\n") this.pos += 1;
                } else if (ch === "#" && this.source[this.pos + 1] === "|") {
                    this.skipBlockComment();
                } else if (ch === "#" && this.source[this.pos + 1] === ";") {
                    this.pos += 2;
                    this.readDatum();
                } else {
                    return;
                }
            }
        }

        skipBlockComment() {
            let depth = 1;
            this.pos += 2;
            while (this.pos < this.source.length && depth > 0) {
                if (this.source.startsWith("#|", this.pos)) {
                    depth += 1;
                    this.pos += 2;
                } else if (this.source.startsWith("|#", this.pos)) {
                    depth -= 1;
                    this.pos += 2;
                } else {
                    this.pos += 1;
                }
            }
            if (depth > 0) throw new IncompleteInput("unterminated block comment");
        }

        /** @returns {any} the next datum */
        readDatum() {
            this.skipAtmosphere();
            if (this.atEnd()) throw new IncompleteInput("unexpected end of input");
            const ch = this.source[this.pos];
            if (ch === "(" || ch === "[") {
                this.pos += 1;
                return this.readList(ch === "(" ? ")" : "]");
            }
            if (ch === ")" || ch === "]") throw new SchemeError("unexpected '" + ch + "'");
            if (ch === "'") {
                this.pos += 1;
                return arrayToList([intern("quote"), this.readDatum()]);
            }
            if (ch === "`") {
                this.pos += 1;
                return arrayToList([intern("quasiquote"), this.readDatum()]);
            }
            if (ch === ",") {
                const splicing = this.source[this.pos + 1] === "@";
                this.pos += splicing ? 2 : 1;
                return arrayToList([intern(splicing ? "unquote-splicing" : "unquote"), this.readDatum()]);
            }
            if (ch === '"') return this.readString();
            if (ch === "#") return this.readHash();
            return this.readAtom();
        }

        /** @param {string} closer @returns {any} */
        readList(closer) {
            const items = [];
            let tail = null;
            for (;;) {
                this.skipAtmosphere();
                if (this.atEnd()) throw new IncompleteInput("missing a closing '" + closer + "'");
                const ch = this.source[this.pos];
                if (ch === closer) {
                    this.pos += 1;
                    break;
                }
                if (ch === ")" || ch === "]") {
                    throw new SchemeError("mismatched '" + ch + "', expected '" + closer + "'");
                }
                // A lone dot introduces the tail of an improper list: (a . b)
                const next = this.source[this.pos + 1];
                if (ch === "." && (next === undefined || /[\s()[\]'`,]/.test(next))) {
                    this.pos += 1;
                    tail = this.readDatum();
                    this.skipAtmosphere();
                    if (this.atEnd()) throw new IncompleteInput("missing a closing '" + closer + "'");
                    if (this.source[this.pos] !== closer) {
                        throw new SchemeError("expected '" + closer + "' after the dotted tail");
                    }
                    this.pos += 1;
                    break;
                }
                items.push(this.readDatum());
            }
            return arrayToList(items, tail);
        }

        /** @returns {string} */
        readString() {
            this.pos += 1;
            let text = "";
            for (;;) {
                if (this.atEnd()) throw new IncompleteInput("unterminated string");
                const ch = this.source[this.pos];
                if (ch === '"') {
                    this.pos += 1;
                    return text;
                }
                if (ch === "\\") {
                    const escape = this.source[this.pos + 1];
                    const simple = { n: "\n", t: "\t", r: "\r", a: "\u0007", b: "\b", "0": "\0", "\\": "\\", '"': '"' };
                    if (escape === undefined) throw new IncompleteInput("unterminated string");
                    if (Object.prototype.hasOwnProperty.call(simple, escape)) {
                        text += simple[escape];
                        this.pos += 2;
                        continue;
                    }
                    const hex = /^\\x([0-9a-fA-F]+);/.exec(this.source.slice(this.pos));
                    if (hex) {
                        text += String.fromCodePoint(parseInt(hex[1], 16));
                        this.pos += hex[0].length;
                        continue;
                    }
                    throw new SchemeError("unknown string escape '\\" + escape + "'");
                }
                text += ch;
                this.pos += 1;
            }
        }

        /** @returns {any} */
        readAtom() {
            const start = this.pos;
            while (this.pos < this.source.length && !/[\s()[\]"'`,;]/.test(this.source[this.pos])) {
                this.pos += 1;
            }
            const text = this.source.slice(start, this.pos);
            if (text === "") throw new SchemeError("unexpected character '" + this.source[this.pos] + "'");
            const number = parseNumberLiteral(text);
            return number === undefined ? intern(text) : number;
        }

        /** @returns {any} */
        readHash() {
            const rest = this.source.slice(this.pos);
            let match = /^#t(?:rue)?(?=[\s()[\]"';]|$)/.exec(rest);
            if (match) {
                this.pos += match[0].length;
                return true;
            }
            match = /^#f(?:alse)?(?=[\s()[\]"';]|$)/.exec(rest);
            if (match) {
                this.pos += match[0].length;
                return false;
            }
            match = /^#\\(.)/.exec(rest);
            if (match) {
                // The captured character is the first character of the name,
                // so consume the whole three-character token here and treat
                // what follows as the rest of a possible name: #\a, #\space.
                this.pos += match[0].length;
                const first = match[1];
                if (/[A-Za-z]/.test(first)) {
                    let name = first;
                    while (this.pos < this.source.length && /[A-Za-z0-9-]/.test(this.source[this.pos])) {
                        name += this.source[this.pos];
                        this.pos += 1;
                    }
                    // A single letter is that character, not a name: #\a.
                    if (name.length === 1) return new Char(first.codePointAt(0) || 0);
                    const lower = name.toLowerCase();
                    const named = Object.keys(CHAR_NAMES).find((code) => CHAR_NAMES[code] === lower);
                    if (named !== undefined) return new Char(Number(named));
                    if (/^x[0-9a-f]+$/.test(lower)) return new Char(parseInt(lower.slice(1), 16));
                    throw new SchemeError("unknown character name: #\\" + name);
                }
                return new Char(first.codePointAt(0) || 0);
            }
            if (rest.startsWith("#(")) {
                this.pos += 2;
                return new Vector(needList(this.readList(")"), { name: "vector" }));
            }
            if (rest.startsWith("#|") || rest.startsWith("#;")) {
                this.skipAtmosphere();
                return this.readDatum();
            }
            throw new SchemeError("unsupported # syntax near '" + rest.slice(0, 12) + "'");
        }
    }

    /* ------------------------------------------------------------------ */
    /* 4. Environments                                                     */
    /* ------------------------------------------------------------------ */

    /** A frame of bindings, with a link to the enclosing frame. */
    class Frame {
        /** @param {Frame|null} parent */
        constructor(parent) {
            this.vars = new Map();
            this.parent = parent;
        }

        /** @param {string} name @param {any} value */
        define(name, value) {
            this.vars.set(name, value);
        }

        /** @param {Sym} symbol @returns {any} */
        lookup(symbol) {
            for (let frame = this; frame; frame = frame.parent) {
                if (frame.vars.has(symbol.name)) {
                    const value = frame.vars.get(symbol.name);
                    if (value === UNINITIALIZED) {
                        throw new SchemeError("letrec: variable used before it was initialised: " + symbol.name);
                    }
                    return value;
                }
            }
            throw new SchemeError("Unbound variable: " + symbol.name);
        }

        /** @param {Sym} symbol @param {any} value */
        assign(symbol, value) {
            for (let frame = this; frame; frame = frame.parent) {
                if (frame.vars.has(symbol.name)) {
                    frame.vars.set(symbol.name, value);
                    return;
                }
            }
            throw new SchemeError("Unbound variable: " + symbol.name);
        }
    }

    /**
     * A parameter list as used by `lambda' and `define': names, an optional
     * rest name, and nothing else.
     * @param {any} spec
     * @returns {{ params: string[], rest: string|null }}
     */
    const splitParams = (spec) => {
        if (isSym(spec)) return { params: [], rest: spec.name };
        const params = [];
        let rest = null;
        let node = spec;
        while (node instanceof Pair) {
            if (!isSym(node.car)) throw new SchemeError("bad parameter list: " + writeValue(spec));
            params.push(node.car.name);
            node = node.cdr;
        }
        if (node !== null) {
            if (!isSym(node)) throw new SchemeError("bad parameter list: " + writeValue(spec));
            rest = node.name;
        }
        return { params, rest };
    };

    /**
     * @param {Closure} proc
     * @param {any[]} args
     * @returns {Frame} a fresh frame with the arguments bound
     */
    const bindArguments = (proc, args) => {
        const frame = new Frame(proc.env);
        if (args.length < proc.params.length || (!proc.rest && args.length > proc.params.length)) {
            throw new SchemeError("Wrong number of arguments to " + proc.describe()
                + ": expected " + proc.params.length + (proc.rest ? " or more" : "") + ", got " + args.length);
        }
        proc.params.forEach((name, index) => frame.define(name, args[index]));
        if (proc.rest) frame.define(proc.rest, arrayToList(args.slice(proc.params.length)));
        return frame;
    };

    /* ------------------------------------------------------------------ */
    /* 5. The evaluator                                                   */
    /* ------------------------------------------------------------------ */

    /** Guards against a runaway loop locking up the visitor's tab. */
    const MAX_STEPS = 20000000;
    const MAX_MILLISECONDS = 1500;
    const STEP_CHECK_MASK = 65535;

    let steps = 0;
    let deadline = 0;

    const tick = () => {
        steps += 1;
        if (steps > MAX_STEPS) {
            throw new SchemeError("Evaluation stopped after " + MAX_STEPS.toLocaleString("en-US")
                + " evaluation steps — is that loop meant to finish?");
        }
        if ((steps & STEP_CHECK_MASK) === 0 && Date.now() > deadline) {
            throw new SchemeError("Evaluation stopped after " + (MAX_MILLISECONDS / 1000).toFixed(1)
                + " s of wall-clock time — is that loop meant to finish?");
        }
    };

    /** Start a fresh budget for one chunk of input. */
    const beginEvaluation = () => {
        steps = 0;
        deadline = Date.now() + MAX_MILLISECONDS;
    };

    /** Forms this emulation knows about and deliberately does not support. */
    const UNSUPPORTED_FORMS = [
        "define-syntax", "let-syntax", "letrec-syntax", "syntax-rules", "define-macro",
        "use-modules", "define-module", "load", "eval", "apply-macro",
        "call/cc", "call-with-current-continuation", "dynamic-wind", "guard", "catch", "throw",
        "with-exception-handler", "values", "call-with-values", "parameterize", "make-parameter",
        "do", "define-record-type", "delay", "force", "promise", "let-values", "call-with-input-file"
    ];

    /**
     * Evaluate FORM in ENV.
     *
     * Calls in tail position reuse this loop instead of the JavaScript stack,
     * so a tail-recursive Scheme program runs in constant stack space — the
     * same promise Guile makes, made by the same trick.
     *
     * @param {any} form
     * @param {Frame} env
     * @param {any} ctx
     * @returns {any}
     */
    const evaluate = (form, env, ctx) => {
        for (;;) {
            tick();

            if (form instanceof Sym) return env.lookup(form);
            if (!(form instanceof Pair)) {
                if (form === null) throw new SchemeError("Empty combination: ()");
                return form;
            }

            const head = form.car;
            if (head instanceof Sym) {
                const form_name = head.name;

                if (form_name === "quote") {
                    const parts = needList(form.cdr, { name: "quote" });
                    if (parts.length !== 1) throw new SchemeError("quote: expected one datum");
                    return parts[0];
                }
                if (form_name === "quasiquote") {
                    const parts = needList(form.cdr, { name: "quasiquote" });
                    if (parts.length !== 1) throw new SchemeError("quasiquote: expected one template");
                    return quasi(parts[0], env, ctx, 1);
                }
                if (form_name === "unquote" || form_name === "unquote-splicing") {
                    throw new SchemeError(form_name + ": not in a quasiquote");
                }
                if (form_name === "if") {
                    const parts = needList(form.cdr, { name: "if" });
                    if (parts.length < 2 || parts.length > 3) {
                        throw new SchemeError("if: expected (if test then [else])");
                    }
                    const test = evaluate(parts[0], env, ctx);
                    if (isFalse(test)) {
                        if (parts.length === 3) {
                            form = parts[2];
                            continue;
                        }
                        return UNSPECIFIED;
                    }
                    form = parts[1];
                    continue;
                }
                if (form_name === "define") {
                    return evaluateDefine(form, env, ctx);
                }
                if (form_name === "set!") {
                    const parts = needList(form.cdr, { name: "set!" });
                    if (parts.length !== 2 || !isSym(parts[0])) {
                        throw new SchemeError("set!: expected (set! name value)");
                    }
                    env.assign(parts[0], evaluate(parts[1], env, ctx));
                    return UNSPECIFIED;
                }
                if (form_name === "lambda") {
                    const parts = needList(form.cdr, { name: "lambda" });
                    if (parts.length < 2) throw new SchemeError("lambda: expected (lambda params body …)");
                    const { params, rest } = splitParams(parts[0]);
                    return new Closure(params, rest, parts.slice(1), env, null);
                }
                if (form_name === "begin") {
                    const parts = needList(form.cdr, { name: "begin" });
                    if (parts.length === 0) return UNSPECIFIED;
                    for (let i = 0; i < parts.length - 1; i += 1) evaluate(parts[i], env, ctx);
                    form = parts[parts.length - 1];
                    continue;
                }
                if (form_name === "when" || form_name === "unless") {
                    const parts = needList(form.cdr, { name: form_name });
                    if (parts.length < 1) throw new SchemeError(form_name + ": expected a test");
                    const test = evaluate(parts[0], env, ctx);
                    const run = form_name === "when" ? !isFalse(test) : isFalse(test);
                    if (!run || parts.length === 1) return UNSPECIFIED;
                    for (let i = 1; i < parts.length - 1; i += 1) evaluate(parts[i], env, ctx);
                    form = parts[parts.length - 1];
                    continue;
                }
                if (form_name === "and" || form_name === "or") {
                    const parts = needList(form.cdr, { name: form_name });
                    if (parts.length === 0) return form_name === "and";
                    for (let i = 0; i < parts.length - 1; i += 1) {
                        const value = evaluate(parts[i], env, ctx);
                        if (form_name === "and" && isFalse(value)) return false;
                        if (form_name === "or" && !isFalse(value)) return value;
                    }
                    form = parts[parts.length - 1];
                    continue;
                }
                if (form_name === "let" || form_name === "let*" || form_name === "letrec") {
                    const parts = needList(form.cdr, { name: form_name });
                    // A named let is a recursive procedure: desugar it.
                    if (form_name === "let" && parts.length >= 2 && isSym(parts[0])) {
                        const name = parts[0];
                        const bindings = needList(parts[1], { name: "let" }).map((binding) => {
                            const pair = needList(binding, { name: "let" });
                            if (pair.length !== 2 || !isSym(pair[0])) {
                                throw new SchemeError("let: bad binding " + writeValue(binding));
                            }
                            return pair;
                        });
                        const lambda = arrayToList([intern("lambda"), arrayToList(bindings.map((pair) => pair[0]))].concat(parts.slice(2)));
                        const recursive = arrayToList([arrayToList([name, lambda])]);
                        const call = arrayToList([name].concat(bindings.map((pair) => pair[1])));
                        form = arrayToList([intern("letrec"), recursive, call]);
                        continue;
                    }
                    if (parts.length < 2) throw new SchemeError(form_name + ": expected bindings and a body");
                    const bindings = needList(parts[0], { name: form_name });
                    const frame = new Frame(env);
                    const each = (binding) => {
                        const pair = needList(binding, { name: form_name });
                        if (pair.length !== 2 || !isSym(pair[0])) {
                            throw new SchemeError(form_name + ": bad binding " + writeValue(binding));
                        }
                        return pair;
                    };
                    if (form_name === "letrec") {
                        bindings.forEach((binding) => frame.define(each(binding)[0].name, UNINITIALIZED));
                        bindings.forEach((binding) => {
                            const pair = each(binding);
                            frame.assign(pair[0], evaluate(pair[1], frame, ctx));
                        });
                    } else {
                        bindings.forEach((binding) => {
                            const pair = each(binding);
                            // `let' evaluates every initialiser outside the new
                            // frame; `let*' sees the bindings made so far.
                            frame.define(pair[0].name, evaluate(pair[1], form_name === "let*" ? frame : env, ctx));
                        });
                    }
                    const body = parts.slice(1);
                    for (let i = 0; i < body.length - 1; i += 1) evaluate(body[i], frame, ctx);
                    form = body[body.length - 1];
                    env = frame;
                    continue;
                }
                if (form_name === "cond") {
                    const clauses = needList(form.cdr, { name: "cond" });
                    if (clauses.length === 0) throw new SchemeError("cond: expected at least one clause");
                    let chosen = null;
                    for (const clause of clauses) {
                        const pair = needList(clause, { name: "cond" });
                        if (pair.length === 0) throw new SchemeError("cond: empty clause");
                        const isElse = isSym(pair[0]) && pair[0].name === "else";
                        const value = isElse ? true : evaluate(pair[0], env, ctx);
                        if (isFalse(value)) continue;
                        const body = pair.slice(1);
                        if (body.length === 0) return value;
                        if (isSym(body[0]) && body[0].name === "=>") {
                            if (body.length !== 2) throw new SchemeError("cond: '=>' takes one receiver");
                            return callProcedure(evaluate(body[1], env, ctx), [value], ctx);
                        }
                        for (let i = 0; i < body.length - 1; i += 1) evaluate(body[i], env, ctx);
                        chosen = body[body.length - 1];
                        break;
                    }
                    if (chosen === null) return UNSPECIFIED;
                    form = chosen;
                    continue;
                }
                if (form_name === "case") {
                    const parts = needList(form.cdr, { name: "case" });
                    if (parts.length < 2) throw new SchemeError("case: expected a key and at least one clause");
                    const key = evaluate(parts[0], env, ctx);
                    let chosen = null;
                    for (const clause of parts.slice(1)) {
                        const pair = needList(clause, { name: "case" });
                        if (pair.length === 0) throw new SchemeError("case: empty clause");
                        const datums = pair[0];
                        const isElse = isSym(datums) && datums.name === "else";
                        const matches = isElse || needList(datums, { name: "case" }).some((d) => eqv(key, d));
                        if (!matches) continue;
                        const body = pair.slice(1);
                        if (body.length === 0) return UNSPECIFIED;
                        for (let i = 0; i < body.length - 1; i += 1) evaluate(body[i], env, ctx);
                        chosen = body[body.length - 1];
                        break;
                    }
                    if (chosen === null) return UNSPECIFIED;
                    form = chosen;
                    continue;
                }
                if (UNSUPPORTED_FORMS.indexOf(form_name) !== -1) {
                    throw new SchemeError(form_name + ": not available in this browser emulation"
                        + ((form_name === "do" || form_name === "values" || form_name === "guard")
                            ? " — see the reference below for what is" : ""));
                }
            }

            // A procedure call. The operator is evaluated first, as in Scheme.
            const proc = evaluate(head, env, ctx);
            const args = needList(form.cdr, { name: "application" }).map((arg) => evaluate(arg, env, ctx));
            if (proc instanceof Closure) {
                const frame = bindArguments(proc, args);
                const body = proc.body;
                for (let i = 0; i < body.length - 1; i += 1) evaluate(body[i], frame, ctx);
                form = body[body.length - 1];
                env = frame;
                continue;
            }
            return callProcedure(proc, args, ctx);
        }
    };

    /**
     * @param {any} form a (define …) form
     * @param {Frame} env
     * @param {any} ctx
     * @returns {any}
     */
    const evaluateDefine = (form, env, ctx) => {
        const parts = needList(form.cdr, { name: "define" });
        if (parts.length === 0) throw new SchemeError("define: expected a name");
        if (isPair(parts[0])) {
            const signature = parts[0];
            if (!isSym(signature.car)) throw new SchemeError("define: expected a procedure name");
            if (parts.length < 2) throw new SchemeError("define: missing the body of " + signature.car.name);
            const { params, rest } = splitParams(signature.cdr);
            env.define(signature.car.name, new Closure(params, rest, parts.slice(1), env, signature.car.name));
            return UNSPECIFIED;
        }
        if (!isSym(parts[0]) || parts.length !== 2) {
            throw new SchemeError("define: expected (define name value)");
        }
        const value = evaluate(parts[1], env, ctx);
        if (value instanceof Closure) value.name = value.name || parts[0].name;
        env.define(parts[0].name, value);
        return UNSPECIFIED;
    };

    /**
     * Apply an already-evaluated procedure. Loops in JavaScript rather than
     * recursing, so `map' over a long list stays cheap.
     * @param {any} proc
     * @param {any[]} args
     * @param {any} ctx
     * @returns {any}
     */
    const callProcedure = (proc, args, ctx) => {
        if (proc instanceof Closure) {
            const frame = bindArguments(proc, args);
            let result = UNSPECIFIED;
            for (const expression of proc.body) result = evaluate(expression, frame, ctx);
            return result;
        }
        if (proc instanceof Primitive) {
            const spec = proc.spec;
            const min = spec.min === undefined ? 0 : spec.min;
            const max = spec.max === undefined ? Infinity : spec.max;
            if (args.length < min || args.length > max) {
                const expected = max === Infinity ? "at least " + min : (min === max ? String(min) : min + " to " + max);
                throw new SchemeError("In procedure " + spec.name + ": Wrong number of arguments (expected "
                    + expected + ", got " + args.length + ")");
            }
            return spec.fn(args, ctx, spec);
        }
        throw new SchemeError("Wrong type to apply: " + writeValue(proc));
    };

    /**
     * Expand QUASI at DEPTH, evaluating `,' and splicing `,@'.
     * @param {any} template
     * @param {Frame} env
     * @param {any} ctx
     * @param {number} depth
     * @returns {any}
     */
    const quasi = (template, env, ctx, depth) => {
        if (!(template instanceof Pair)) return template;
        if (isSym(template.car) && template.car.name === "unquote") {
            const parts = needList(template.cdr, { name: "unquote" });
            if (parts.length !== 1) throw new SchemeError("unquote: expected one expression");
            if (depth === 1) return evaluate(parts[0], env, ctx);
            return arrayToList([intern("unquote"), quasi(parts[0], env, ctx, depth - 1)]);
        }
        if (isSym(template.car) && template.car.name === "quasiquote") {
            const parts = needList(template.cdr, { name: "quasiquote" });
            return arrayToList([intern("quasiquote"), quasi(parts[0], env, ctx, depth + 1)]);
        }
        const items = [];
        let node = template;
        while (node instanceof Pair) {
            const item = node.car;
            if (depth === 1 && item instanceof Pair && isSym(item.car) && item.car.name === "unquote-splicing") {
                const parts = needList(item.cdr, { name: "unquote-splicing" });
                if (parts.length !== 1) throw new SchemeError("unquote-splicing: expected one expression");
                const spliced = evaluate(parts[0], env, ctx);
                needList(spliced, { name: "unquote-splicing" }).forEach((value) => items.push(value));
            } else {
                items.push(quasi(item, env, ctx, depth));
            }
            node = node.cdr;
        }
        if (node !== null) throw new SchemeError("quasiquote: cannot splice into an improper list");
        return arrayToList(items);
    };

    /* ------------------------------------------------------------------ */
    /* 6. The reference — and the primitives it documents                 */
    /* ------------------------------------------------------------------ */

    /**
     * Every primitive this interpreter binds, plus the syntax the evaluator
     * above implements. Entries with `fn' are bound as procedures; entries
     * without it document syntax. The page renders this list as the
     * expandable reference and `(help)' prints its table of contents, so
     * there is exactly one place to keep the docs honest.
     *
     * `fn(args, ctx, spec)' receives evaluated arguments, the host context
     * (the output port, and a way to expand the reference) and the spec
     * itself, which carries the name used in error messages.
     */
    const REFERENCE = [];

    /**
     * @param {string} title
     * @param {any[]} entries
     */
    const group = (title, entries) => {
        REFERENCE.push({ title, entries });
    };

    /* --- Syntax ------------------------------------------------------ */

    group("Special forms (not procedures)", [
        { name: "define", usage: "(define name value) · (define (name args …) body …)", doc: "Bind a value, or a procedure with a shorthand.", example: "(define (square x) (* x x))" },
        { name: "lambda", usage: "(lambda (args …) body …) · (lambda args body …)", doc: "A procedure. Use (a b . rest) for a rest list.", example: "((lambda (x y) (* x y)) 6 7)" },
        { name: "if", usage: "(if test then [else])", doc: "Only #f is false; the missing else gives an unspecified value.", example: "(if (> 3 2) 'yes 'no)" },
        { name: "cond", usage: "(cond (test body …) … (else body …))", doc: "Clauses in order; (test => proc) passes on the test value.", example: "(cond ((> 1 2) 'no) (else 'yes))" },
        { name: "case", usage: "(case key ((datum …) body …) … (else …))", doc: "Compare key with eqv? against each datum list.", example: "(case 2 ((1) 'one) ((2 3) 'few) (else 'many))" },
        { name: "when", usage: "(when test body …)", doc: "Run the body once if test is true.", example: "(when #t 'ran)" },
        { name: "unless", usage: "(unless test body …)", doc: "Run the body once if test is false.", example: "(unless #f 'ran)" },
        { name: "begin", usage: "(begin body …)", doc: "Sequence, in the order written.", example: "(begin 1 2 3)" },
        { name: "let", usage: "(let ((name value) …) body …)", doc: "Local bindings, evaluated outside the new frame.", example: "(let ((x 2) (y 3)) (* x y))" },
        { name: "let*", usage: "(let* ((name value) …) body …)", doc: "Like let, but each binding sees the previous ones.", example: "(let* ((x 2) (y (* x 3))) (+ x y))" },
        { name: "letrec", usage: "(letrec ((name value) …) body …)", doc: "Recursive bindings; (let name (…) …) is sugar for this.", example: "(let loop ((i 0)) (if (= i 3) i (loop (+ i 1))))" },
        { name: "set!", usage: "(set! name value)", doc: "Assign to an existing binding.", example: "(let ((x 1)) (set! x 2) x)" },
        { name: "quote", usage: "(quote datum) · 'datum", doc: "Return datum without evaluating it.", example: "'(1 2 3)" },
        { name: "quasiquote", usage: "(quasiquote template) · `template with , and ,@", doc: "Build lists, evaluating the unquoted holes.", example: "`(1 ,(+ 1 1) ,@(list 3 4))" },
        { name: "and", usage: "(and expr …)", doc: "Short-circuit; the last value wins, (and) is #t.", example: "(and 1 2 3)" },
        { name: "or", usage: "(or expr …)", doc: "Short-circuit; the first true value wins, (or) is #f.", example: "(or #f 'first-true)" }
    ]);

    /* --- Numbers ----------------------------------------------------- */

    group("Numbers", [
        { name: "+", usage: "(+ n …)", doc: "Sum; (+) is 0.", example: "(+ 1 2 3 4)", min: 0, fn: (a, ctx, spec) => numericResult(a.map((value) => needNumber(value, spec)).reduce((x, y) => x + y, 0), anyInexact(a)) },
        { name: "-", usage: "(- n …)", doc: "(- n) negates; otherwise subtract the rest from the first.", example: "(- 10 4 1)", min: 1, fn: (a, ctx, spec) => {
            const numbers = a.map((value) => needNumber(value, spec));
            const value = numbers.length === 1 ? -numbers[0] : numbers.slice(1).reduce((x, y) => x - y, numbers[0]);
            return numericResult(value, anyInexact(a));
        } },
        { name: "*", usage: "(* n …)", doc: "Product; (*) is 1.", example: "(* 6 7)", min: 0, fn: (a, ctx, spec) => numericResult(a.map((value) => needNumber(value, spec)).reduce((x, y) => x * y, 1), anyInexact(a)) },
        { name: "/", usage: "(/ n …)", doc: "(- n) is 1/n; otherwise divide. Inexact: 1/3 is a decimal here.", example: "(/ 22 7)", min: 1, fn: (a, ctx, spec) => {
            const numbers = a.map((value) => needNumber(value, spec));
            const divide = (x, y) => {
                if (y === 0) throw new SchemeError("In procedure /: Division by zero");
                return x / y;
            };
            const value = numbers.length === 1 ? divide(1, numbers[0]) : numbers.slice(1).reduce(divide, numbers[0]);
            return numericResult(value, anyInexact(a));
        } },
        { name: "quotient", usage: "(quotient n m)", doc: "Integer division, truncated toward zero.", example: "(quotient 22 7)", min: 2, max: 2, fn: (a, ctx, spec) => numericResult(Math.trunc(needNumber(a[0], spec) / needNumber(a[1], spec)), anyInexact(a)) },
        { name: "remainder", usage: "(remainder n m)", doc: "The leftover, with the sign of n.", example: "(remainder -7 3)", min: 2, max: 2, fn: (a, ctx, spec) => { const x = needNumber(a[0], spec); const y = needNumber(a[1], spec); return numericResult(x - y * Math.trunc(x / y), anyInexact(a)); } },
        { name: "modulo", usage: "(modulo n m)", doc: "Like remainder, but with the sign of m.", example: "(modulo -7 3)", min: 2, max: 2, fn: (a, ctx, spec) => { const x = needNumber(a[0], spec); const y = needNumber(a[1], spec); return numericResult(x - y * Math.floor(x / y), anyInexact(a)); } },
        { name: "abs", usage: "(abs n)", doc: "Absolute value.", example: "(abs -3)", min: 1, max: 1, fn: (a, ctx, spec) => numericResult(Math.abs(needNumber(a[0], spec)), anyInexact(a)) },
        { name: "min", usage: "(min n …)", doc: "Smallest argument.", example: "(min 3 1 2)", min: 1, fn: (a, ctx, spec) => numericResult(Math.min.apply(null, a.map((value) => needNumber(value, spec))), anyInexact(a)) },
        { name: "max", usage: "(max n …)", doc: "Largest argument.", example: "(max 3 1 2)", min: 1, fn: (a, ctx, spec) => numericResult(Math.max.apply(null, a.map((value) => needNumber(value, spec))), anyInexact(a)) },
        { name: "expt", usage: "(expt n m)", doc: "n to the power m. Inexact when m is negative: no rationals here.", example: "(expt 2 10)", min: 2, max: 2, fn: (a, ctx, spec) => numericResult(Math.pow(needNumber(a[0], spec), needNumber(a[1], spec)), anyInexact(a)) },
        { name: "sqrt", usage: "(sqrt n)", doc: "Square root, exact for a perfect square.", example: "(sqrt 16)", min: 1, max: 1, fn: (a, ctx, spec) => numericResult(Math.sqrt(needNumber(a[0], spec)), anyInexact(a)) },
        { name: "floor", usage: "(floor n)", doc: "Round down.", example: "(floor 2.7)", min: 1, max: 1, fn: (a, ctx, spec) => numericResult(Math.floor(needNumber(a[0], spec)), anyInexact(a)) },
        { name: "ceiling", usage: "(ceiling n)", doc: "Round up.", example: "(ceiling 2.1)", min: 1, max: 1, fn: (a, ctx, spec) => numericResult(Math.ceil(needNumber(a[0], spec)), anyInexact(a)) },
        { name: "truncate", usage: "(truncate n)", doc: "Drop the fraction, toward zero.", example: "(truncate -2.7)", min: 1, max: 1, fn: (a, ctx, spec) => numericResult(Math.trunc(needNumber(a[0], spec)), anyInexact(a)) },
        { name: "round", usage: "(round n)", doc: "Round to nearest, halves to even, as in Guile.", example: "(round 3.5)", min: 1, max: 1, fn: (a, ctx, spec) => {
            const value = needNumber(a[0], spec);
            const below = Math.floor(value);
            const rest = value - below;
            const rounded = rest < 0.5 ? below : (rest > 0.5 ? below + 1 : (below % 2 === 0 ? below : below + 1));
            return numericResult(rounded, anyInexact(a));
        } },
        { name: "1+", usage: "(1+ n)", doc: "Add one.", example: "(1+ 41)", min: 1, max: 1, fn: (a, ctx, spec) => numericResult(needNumber(a[0], spec) + 1, anyInexact(a)) },
        { name: "1-", usage: "(1- n)", doc: "Subtract one.", example: "(1- 43)", min: 1, max: 1, fn: (a, ctx, spec) => numericResult(needNumber(a[0], spec) - 1, anyInexact(a)) },
        { name: "gcd", usage: "(gcd n …)", doc: "Greatest common divisor.", example: "(gcd 12 18)", min: 0, fn: (a, ctx, spec) => numericResult(a.map((value) => Math.abs(needInteger(value, spec))).reduce((x, y) => { let left = x; let right = y; while (right) { const next = left % right; left = right; right = next; } return left; }, 0), anyInexact(a)) },
        { name: "lcm", usage: "(lcm n …)", doc: "Least common multiple.", example: "(lcm 4 6)", min: 0, fn: (a, ctx, spec) => numericResult(a.map((value) => Math.abs(needInteger(value, spec))).reduce((x, y) => (x === 0 || y === 0 ? 0 : Math.abs(x * y) / gcdOf(x, y)), 1), anyInexact(a)) },
        { name: "number->string", usage: "(number->string n [radix])", doc: "Print a number in the given radix (2–36).", example: "(number->string 255 16)", min: 1, max: 2, fn: (a, ctx, spec) => {
            const radix = a.length > 1 ? needExactInteger(a[1], spec) : 10;
            if (radix === 10) {
                needNumber(a[0], spec);
                return writeValue(a[0]);
            }
            return needExactInteger(a[0], spec).toString(radix);
        } },
        { name: "string->number", usage: "(string->number string [radix])", doc: "Read a number, or return #f when the text is not one.", example: "(string->number \"ff\" 16)", min: 1, max: 2, fn: (a, ctx, spec) => {
            const text = needString(a[0], spec).trim();
            const radix = a.length > 1 ? needExactInteger(a[1], spec) : 10;
            if (radix === 10) {
                const parsed = parseNumberLiteral(text);
                return parsed === undefined ? false : parsed;
            }
            const parsed = parseInt(text, radix);
            return Number.isNaN(parsed) ? false : parsed;
        } },
        { name: "exact->inexact", usage: "(exact->inexact n)", doc: "Make a number inexact, so it prints with a decimal point.", example: "(exact->inexact 3)", min: 1, max: 1, fn: (a, ctx, spec) => new Inexact(needNumber(a[0], spec)) },
        { name: "exact?", usage: "(exact? n)", doc: "Is n exact (a whole number here)?", example: "(exact? 3)", min: 1, max: 1, fn: (a, ctx, spec) => !isInexact(a[0]) && needNumber(a[0], spec) === num(a[0]) },
        { name: "inexact?", usage: "(inexact? n)", doc: "Is n inexact?", example: "(inexact? 3.0)", min: 1, max: 1, fn: (a, ctx, spec) => { needNumber(a[0], spec); return isInexact(a[0]); } },
        { name: "=", usage: "(= n m …)", doc: "Numeric equality, comparing every neighbouring pair.", example: "(= 1 1 1)", min: 1, fn: (a, ctx, spec) => chain(a.map((value) => needNumber(value, spec)), (x, y) => x === y) },
        { name: "<", usage: "(< n m …)", doc: "Strictly increasing.", example: "(< 1 2 3)", min: 1, fn: (a, ctx, spec) => chain(a.map((value) => needNumber(value, spec)), (x, y) => x < y) },
        { name: ">", usage: "(> n m …)", doc: "Strictly decreasing.", example: "(> 3 2 1)", min: 1, fn: (a, ctx, spec) => chain(a.map((value) => needNumber(value, spec)), (x, y) => x > y) },
        { name: "<=", usage: "(<= n m …)", doc: "Non-decreasing.", example: "(<= 1 1 2)", min: 1, fn: (a, ctx, spec) => chain(a.map((value) => needNumber(value, spec)), (x, y) => x <= y) },
        { name: ">=", usage: "(>= n m …)", doc: "Non-increasing.", example: "(>= 3 3 1)", min: 1, fn: (a, ctx, spec) => chain(a.map((value) => needNumber(value, spec)), (x, y) => x >= y) },
        { name: "zero?", usage: "(zero? n)", doc: "Is n zero?", example: "(zero? 0)", min: 1, max: 1, fn: (a, ctx, spec) => needNumber(a[0], spec) === 0 },
        { name: "positive?", usage: "(positive? n)", doc: "Is n above zero?", example: "(positive? 1)", min: 1, max: 1, fn: (a, ctx, spec) => needNumber(a[0], spec) > 0 },
        { name: "negative?", usage: "(negative? n)", doc: "Is n below zero?", example: "(negative? -1)", min: 1, max: 1, fn: (a, ctx, spec) => needNumber(a[0], spec) < 0 },
        { name: "odd?", usage: "(odd? n)", doc: "Is n an odd integer?", example: "(odd? 7)", min: 1, max: 1, fn: (a, ctx, spec) => needInteger(a[0], spec) % 2 !== 0 },
        { name: "even?", usage: "(even? n)", doc: "Is n an even integer?", example: "(even? 8)", min: 1, max: 1, fn: (a, ctx, spec) => needInteger(a[0], spec) % 2 === 0 },
        { name: "nan?", usage: "(nan? n)", doc: "Is n a NaN?", example: "(nan? +nan.0)", min: 1, max: 1, fn: (a, ctx, spec) => Number.isNaN(needNumber(a[0], spec)) },
        { name: "infinite?", usage: "(infinite? n)", doc: "Is n ±inf.0? Not in Guile's default environment, but handy here.", example: "(infinite? +inf.0)", min: 1, max: 1, fn: (a, ctx, spec) => !Number.isFinite(needNumber(a[0], spec)) }
    ]);

    /* --- Booleans, equality, predicates ------------------------------- */

    group("Predicates and equality", [
        { name: "not", usage: "(not value)", doc: "True only for #f.", example: "(not #f)", min: 1, max: 1, fn: (a) => isFalse(a[0]) },
        { name: "eq?", usage: "(eq? x y)", doc: "Same object (or symbol); the cheapest test.", example: "(eq? 'a 'a)", min: 2, max: 2, fn: (a) => eq(a[0], a[1]) },
        { name: "eqv?", usage: "(eqv? x y)", doc: "Same object, or the same number or character.", example: "(eqv? 2 2)", min: 2, max: 2, fn: (a) => eqv(a[0], a[1]) },
        { name: "equal?", usage: "(equal? x y)", doc: "Same structure, element by element.", example: "(equal? '(1 (2)) '(1 (2)))", min: 2, max: 2, fn: (a) => equal(a[0], a[1]) },
        { name: "boolean?", usage: "(boolean? value)", doc: "Is it #t or #f?", example: "(boolean? #t)", min: 1, max: 1, fn: (a) => typeof a[0] === "boolean" },
        { name: "number?", usage: "(number? value)", doc: "Is it a number?", example: "(number? 3)", min: 1, max: 1, fn: (a) => isNumber(a[0]) },
        { name: "integer?", usage: "(integer? value)", doc: "Is it a whole number, exact or not?", example: "(integer? 3)", min: 1, max: 1, fn: (a) => isNumber(a[0]) && Number.isInteger(num(a[0])) },
        { name: "symbol?", usage: "(symbol? value)", doc: "Is it a symbol?", example: "(symbol? 'joe)", min: 1, max: 1, fn: (a) => isSym(a[0]) },
        { name: "string?", usage: "(string? value)", doc: "Is it a string?", example: "(string? \"hi\")", min: 1, max: 1, fn: (a) => typeof a[0] === "string" },
        { name: "char?", usage: "(char? value)", doc: "Is it a character?", example: "(char? #\\a)", min: 1, max: 1, fn: (a) => isChar(a[0]) },
        { name: "pair?", usage: "(pair? value)", doc: "Is it a pair?", example: "(pair? '(1 . 2))", min: 1, max: 1, fn: (a) => isPair(a[0]) },
        { name: "null?", usage: "(null? value)", doc: "Is it the empty list?", example: "(null? '())", min: 1, max: 1, fn: (a) => a[0] === null },
        { name: "list?", usage: "(list? value)", doc: "Is it a proper list?", example: "(list? '(1 2))", min: 1, max: 1, fn: (a) => isList(a[0]) },
        { name: "vector?", usage: "(vector? value)", doc: "Is it a vector?", example: "(vector? (vector 1))", min: 1, max: 1, fn: (a) => isVector(a[0]) },
        { name: "procedure?", usage: "(procedure? value)", doc: "Is it callable?", example: "(procedure? car)", min: 1, max: 1, fn: (a) => isProcedure(a[0]) }
    ]);

    /* --- Pairs and lists --------------------------------------------- */

    group("Pairs and lists", [
        { name: "cons", usage: "(cons car cdr)", doc: "A new pair.", example: "(cons 1 2)", min: 2, max: 2, fn: (a) => new Pair(a[0], a[1]) },
        { name: "car", usage: "(car pair)", doc: "The first half of a pair.", example: "(car '(1 2 3))", min: 1, max: 1, fn: (a, ctx, spec) => needPair(a[0], spec).car },
        { name: "cdr", usage: "(cdr pair)", doc: "The second half of a pair.", example: "(cdr '(1 2 3))", min: 1, max: 1, fn: (a, ctx, spec) => needPair(a[0], spec).cdr },
        { name: "c…r", usage: "(cadr p) · (caddr p) · (cddr p) · any c[ad]{2,4}r", doc: "Compositions of car and cdr, right to left: (cadr x) is (car (cdr x)).", example: "(caddr '(1 2 3 4))" },
        { name: "list", usage: "(list value …)", doc: "Build a list from its arguments.", example: "(list 1 2 3)", min: 0, fn: (a) => arrayToList(a) },
        { name: "length", usage: "(length list)", doc: "How many elements.", example: "(length '(a b c))", min: 1, max: 1, fn: (a, ctx, spec) => needList(a[0], spec).length },
        { name: "append", usage: "(append list …)", doc: "Concatenate; the last argument may be anything and becomes the tail.", example: "(append '(1 2) '(3) '(4 5))", min: 0, fn: (a, ctx, spec) => {
            if (a.length === 0) return null;
            const head = a.slice(0, -1).flatMap((value) => needList(value, spec));
            return arrayToList(head, a[a.length - 1]);
        } },
        { name: "reverse", usage: "(reverse list)", doc: "The same elements, backwards.", example: "(reverse '(1 2 3))", min: 1, max: 1, fn: (a, ctx, spec) => arrayToList(needList(a[0], spec).reverse()) },
        { name: "list-ref", usage: "(list-ref list k)", doc: "The k-th element, counting from 0.", example: "(list-ref '(a b c) 1)", min: 2, max: 2, fn: (a, ctx, spec) => {
            const items = needList(a[0], spec);
            const index = needExactInteger(a[1], spec);
            if (index < 0 || index >= items.length) throw new SchemeError("In procedure list-ref: Value out of range: " + index);
            return items[index];
        } },
        { name: "list-tail", usage: "(list-tail list k)", doc: "The sublist after the first k elements.", example: "(list-tail '(1 2 3) 1)", min: 2, max: 2, fn: (a, ctx, spec) => {
            let node = a[0];
            const count = needExactInteger(a[1], spec);
            for (let i = 0; i < count; i += 1) node = needPair(node, spec).cdr;
            return node;
        } },
        { name: "last-pair", usage: "(last-pair list)", doc: "The pair whose cdr is ().", example: "(last-pair '(1 2 3))", min: 1, max: 1, fn: (a, ctx, spec) => {
            let node = needPair(a[0], spec);
            while (node.cdr instanceof Pair) node = node.cdr;
            return node;
        } },
        { name: "member", usage: "(member value list)", doc: "The sublist starting at value, or #f.", example: "(member 2 '(1 2 3))", min: 2, max: 2, fn: (a) => member(a[0], a[1], equal) },
        { name: "memq", usage: "(memq value list)", doc: "member, comparing with eq?.", example: "(memq 'b '(a b c))", min: 2, max: 2, fn: (a) => member(a[0], a[1], eq) },
        { name: "memv", usage: "(memv value list)", doc: "member, comparing with eqv?.", example: "(memv 2 '(1 2 3))", min: 2, max: 2, fn: (a) => member(a[0], a[1], eqv) },
        { name: "assoc", usage: "(assoc key alist)", doc: "The first pair whose car equals key, or #f.", example: "(assoc 2 '((1 a) (2 b)))", min: 2, max: 2, fn: (a) => assoc(a[0], a[1], equal) },
        { name: "assq", usage: "(assq key alist)", doc: "assoc, comparing with eq?.", example: "(assq 'b '((a 1) (b 2)))", min: 2, max: 2, fn: (a) => assoc(a[0], a[1], eq) },
        { name: "assv", usage: "(assv key alist)", doc: "assoc, comparing with eqv?.", example: "(assv 2 '((1 a) (2 b)))", min: 2, max: 2, fn: (a) => assoc(a[0], a[1], eqv) },
        { name: "list-copy", usage: "(list-copy list)", doc: "A fresh spine with the same elements.", example: "(list-copy '(1 2))", min: 1, max: 1, fn: (a, ctx, spec) => arrayToList(needList(a[0], spec)) }
    ]);

    /* --- Higher-order procedures ------------------------------------- */

    group("Higher-order procedures", [
        { name: "map", usage: "(map proc list …)", doc: "Apply proc to the elements of one or more lists.", example: "(map (lambda (n) (* n n)) '(1 2 3))", min: 2, fn: (a, ctx, spec) => {
            const proc = needProcedure(a[0], spec);
            const lists = a.slice(1).map((value) => needList(value, spec));
            const shortest = Math.min.apply(null, lists.map((list) => list.length));
            const out = [];
            for (let i = 0; i < shortest; i += 1) {
                out.push(callProcedure(proc, lists.map((list) => list[i]), ctx));
            }
            return arrayToList(out);
        } },
        { name: "for-each", usage: "(for-each proc list …)", doc: "Like map, but called for effect; returns nothing.", example: "(for-each display '(1 2 3))", min: 2, fn: (a, ctx, spec) => {
            const proc = needProcedure(a[0], spec);
            const lists = a.slice(1).map((value) => needList(value, spec));
            const shortest = Math.min.apply(null, lists.map((list) => list.length));
            for (let i = 0; i < shortest; i += 1) {
                callProcedure(proc, lists.map((list) => list[i]), ctx);
            }
            return UNSPECIFIED;
        } },
        { name: "filter", usage: "(filter pred list)", doc: "Keep the elements the predicate accepts.", example: "(filter odd? '(1 2 3 4))", min: 2, max: 2, fn: (a, ctx, spec) => {
            const proc = needProcedure(a[0], spec);
            const kept = needList(a[1], spec).filter((value) => !isFalse(callProcedure(proc, [value], ctx)));
            return arrayToList(kept);
        } },
        { name: "apply", usage: "(apply proc arg … list)", doc: "Call proc with the leading arguments plus the last list, spread out.", example: "(apply + 1 2 '(3 4))", min: 2, fn: (a, ctx, spec) => {
            const proc = needProcedure(a[0], spec);
            const spread = needList(a[a.length - 1], spec);
            return callProcedure(proc, a.slice(1, -1).concat(spread), ctx);
        } },
        { name: "sort", usage: "(sort list less?)", doc: "A new list in order; the comparator is required, as in Guile.", example: "(sort '(3 1 2) <)", min: 2, max: 2, fn: (a, ctx, spec) => {
            const proc = needProcedure(a[1], spec);
            const items = needList(a[0], spec).slice();
            items.sort((x, y) => {
                if (!isFalse(callProcedure(proc, [x, y], ctx))) return -1;
                if (!isFalse(callProcedure(proc, [y, x], ctx))) return 1;
                return 0;
            });
            return arrayToList(items);
        } }
    ]);

    /* --- Strings ----------------------------------------------------- */

    group("Strings", [
        { name: "string-append", usage: "(string-append string …)", doc: "Join strings end to end.", example: "(string-append \"free \" \"world\")", min: 0, fn: (a, ctx, spec) => a.map((value) => needString(value, spec)).join("") },
        { name: "string-length", usage: "(string-length string)", doc: "How many characters.", example: "(string-length \"hello\")", min: 1, max: 1, fn: (a, ctx, spec) => needString(a[0], spec).length },
        { name: "string-ref", usage: "(string-ref string k)", doc: "The k-th character.", example: "(string-ref \"hello\" 1)", min: 2, max: 2, fn: (a, ctx, spec) => {
            const text = needString(a[0], spec);
            const index = needExactInteger(a[1], spec);
            if (index < 0 || index >= text.length) {
                throw new SchemeError("In procedure string-ref: Value out of range 0 to< " + text.length + ": " + index);
            }
            return new Char(text.codePointAt(index));
        } },
        { name: "substring", usage: "(substring string start [end])", doc: "A slice, end exclusive.", example: "(substring \"hello\" 1 3)", min: 2, max: 3, fn: (a, ctx, spec) => {
            const text = needString(a[0], spec);
            const start = needExactInteger(a[1], spec);
            const end = a.length > 2 ? needExactInteger(a[2], spec) : text.length;
            if (start < 0 || end > text.length || start > end) {
                throw new SchemeError("In procedure substring: Value out of range: " + start + " to " + end);
            }
            return text.slice(start, end);
        } },
        { name: "string-upcase", usage: "(string-upcase string)", doc: "Upper case.", example: "(string-upcase \"free\")", min: 1, max: 1, fn: (a, ctx, spec) => needString(a[0], spec).toUpperCase() },
        { name: "string-downcase", usage: "(string-downcase string)", doc: "Lower case.", example: "(string-downcase \"FREE\")", min: 1, max: 1, fn: (a, ctx, spec) => needString(a[0], spec).toLowerCase() },
        { name: "string=?", usage: "(string=? a b …)", doc: "Same characters.", example: "(string=? \"a\" \"a\")", min: 1, fn: (a, ctx, spec) => chain(a.map((value) => needString(value, spec)), (x, y) => x === y) },
        { name: "string<?", usage: "(string<? a b …)", doc: "Ordered, case sensitively.", example: "(string<? \"a\" \"b\")", min: 1, fn: (a, ctx, spec) => chain(a.map((value) => needString(value, spec)), (x, y) => x < y) },
        { name: "string-contains", usage: "(string-contains haystack needle)", doc: "Index of needle, or #f.", example: "(string-contains \"hello\" \"ll\")", min: 2, max: 2, fn: (a, ctx, spec) => {
            const index = needString(a[0], spec).indexOf(needString(a[1], spec));
            return index === -1 ? false : index;
        } },
        { name: "string-split", usage: "(string-split string separator)", doc: "Split on every separator; runs are not collapsed, as in Guile.", example: "(string-split \"a,b,c\" #\\,)", min: 2, max: 2, fn: (a, ctx, spec) => {
            const text = needString(a[0], spec);
            const separator = a[1];
            const separatorText = typeof separator === "string" ? separator : displayValue(needChar(separator, spec));
            return arrayToList(text.split(separatorText));
        } },
        { name: "string-join", usage: "(string-join list [separator])", doc: "Join strings with a separator (nothing by default).", example: "(string-join '(\"a\" \"b\" \"c\") \"-\")", min: 1, max: 2, fn: (a, ctx, spec) => {
            const separator = a.length > 1 ? needString(a[1], spec) : "";
            return needList(a[0], spec).map((value) => needString(value, spec)).join(separator);
        } },
        { name: "string->list", usage: "(string->list string)", doc: "The characters, as a list.", example: "(string->list \"abc\")", min: 1, max: 1, fn: (a, ctx, spec) => arrayToList(Array.from(needString(a[0], spec)).map((ch) => new Char(ch.codePointAt(0) || 0))) },
        { name: "list->string", usage: "(list->string list)", doc: "A string from a list of characters.", example: "(list->string '(#\\a #\\b))", min: 1, max: 1, fn: (a, ctx, spec) => needList(a[0], spec).map((value) => String.fromCodePoint(needChar(value, spec).code)).join("") },
        { name: "string->symbol", usage: "(string->symbol string)", doc: "The symbol with this name.", example: "(string->symbol \"free\")", min: 1, max: 1, fn: (a, ctx, spec) => intern(needString(a[0], spec)) },
        { name: "symbol->string", usage: "(symbol->string symbol)", doc: "A symbol's name.", example: "(symbol->string 'free)", min: 1, max: 1, fn: (a, ctx, spec) => needSymbol(a[0], spec).name }
    ]);

    /* --- Characters -------------------------------------------------- */

    group("Characters", [
        { name: "char->integer", usage: "(char->integer char)", doc: "The code point.", example: "(char->integer #\\a)", min: 1, max: 1, fn: (a, ctx, spec) => needChar(a[0], spec).code },
        { name: "integer->char", usage: "(integer->char n)", doc: "The character with this code point.", example: "(integer->char 97)", min: 1, max: 1, fn: (a, ctx, spec) => new Char(needExactInteger(a[0], spec)) },
        { name: "char=?", usage: "(char=? a b …)", doc: "Same character.", example: "(char=? #\\a #\\a)", min: 1, fn: (a, ctx, spec) => chain(a.map((value) => needChar(value, spec).code), (x, y) => x === y) },
        { name: "char-alphabetic?", usage: "(char-alphabetic? char)", doc: "A letter?", example: "(char-alphabetic? #\\a)", min: 1, max: 1, fn: (a, ctx, spec) => /[A-Za-z]/.test(String.fromCodePoint(needChar(a[0], spec).code)) }
    ]);

    /* --- Vectors ----------------------------------------------------- */

    group("Vectors", [
        { name: "vector", usage: "(vector value …)", doc: "A vector of its arguments.", example: "(vector 1 2 3)", min: 0, fn: (a) => new Vector(a.slice()) },
        { name: "make-vector", usage: "(make-vector k [fill])", doc: "A vector of k copies of fill (unspecified by default).", example: "(make-vector 3 'x)", min: 1, max: 2, fn: (a, ctx, spec) => {
            const length = needExactInteger(a[0], spec);
            if (length < 0) throw new SchemeError("In procedure make-vector: Value out of range: " + length);
            return new Vector(new Array(length).fill(a.length > 1 ? a[1] : UNSPECIFIED));
        } },
        { name: "vector-length", usage: "(vector-length vector)", doc: "How many elements.", example: "(vector-length (vector 1 2))", min: 1, max: 1, fn: (a, ctx, spec) => needVector(a[0], spec).items.length },
        { name: "vector-ref", usage: "(vector-ref vector k)", doc: "The k-th element.", example: "(vector-ref (vector 10 20) 1)", min: 2, max: 2, fn: (a, ctx, spec) => {
            const items = needVector(a[0], spec).items;
            const index = needExactInteger(a[1], spec);
            if (index < 0 || index >= items.length) throw new SchemeError("In procedure vector-ref: Value out of range: " + index);
            return items[index];
        } },
        { name: "vector-set!", usage: "(vector-set! vector k value)", doc: "Replace the k-th element.", example: "(vector-set! (make-vector 2 0) 1 'x)", min: 3, max: 3, fn: (a, ctx, spec) => {
            const items = needVector(a[0], spec).items;
            const index = needExactInteger(a[1], spec);
            if (index < 0 || index >= items.length) throw new SchemeError("In procedure vector-set!: Value out of range: " + index);
            items[index] = a[2];
            return UNSPECIFIED;
        } },
        { name: "vector->list", usage: "(vector->list vector)", doc: "The elements as a list.", example: "(vector->list (vector 1 2 3))", min: 1, max: 1, fn: (a, ctx, spec) => arrayToList(needVector(a[0], spec).items) },
        { name: "list->vector", usage: "(list->vector list)", doc: "The elements as a vector.", example: "(list->vector '(1 2 3))", min: 1, max: 1, fn: (a, ctx, spec) => new Vector(needList(a[0], spec)) }
    ]);

    /* --- Output and errors ------------------------------------------- */

    group("Output and errors", [
        { name: "display", usage: "(display value)", doc: "Print for humans: no quotes on strings.", example: "(display \"hello, free world\")", min: 1, max: 2, fn: (a, ctx) => {
            ctx.port.write(displayValue(a[0]));
            return UNSPECIFIED;
        } },
        { name: "write", usage: "(write value)", doc: "Print for machines: strings and chars come out readable.", example: "(write '(1 \"two\" #\\3))", min: 1, max: 2, fn: (a, ctx) => {
            ctx.port.write(writeValue(a[0]));
            return UNSPECIFIED;
        } },
        { name: "newline", usage: "(newline)", doc: "End the current line of output.", example: "(begin (display \"a\") (newline) (display \"b\"))", min: 0, max: 1, fn: (a, ctx) => {
            ctx.port.newline();
            return UNSPECIFIED;
        } },
        { name: "simple-format", usage: "(simple-format destination template arg …)", doc: "Fill in ~a (display), ~s (write) and ~%; destination #t prints, #f returns a string.", example: "(simple-format #f \"~a + ~a = ~a~%\" 1 2 3)", min: 2, fn: (a, ctx, spec) => format_(a, ctx, spec) },
        { name: "format", usage: "(format destination template arg …)", doc: "Same as simple-format here: Guile's extended directives need (ice-9 format).", example: "(format #f \"~s is a string~%\" \"hi\")", min: 2, fn: (a, ctx, spec) => format_(a, ctx, spec) },
        { name: "error", usage: "(error message irritant …)", doc: "Raise an error with a message and any number of irritants.", example: "(error \"something went sideways\" 42)", min: 1, fn: (a) => {
            const message = displayValue(a[0]);
            const irritants = a.slice(1).map(writeValue);
            throw new SchemeError(irritants.length === 0 ? message : message + ": " + irritants.join(" "));
        } }
    ]);

    /* --- The free world ---------------------------------------------- */

    group("The free world", [
        { name: "free-world", usage: "(free-world)", doc: "What this page is about, in one line.", example: "(free-world)", min: 0, max: 0, fn: () => "Welcome, friend. The four freedoms are yours: run, study, share, improve." },
        { name: "freedoms", usage: "(freedoms)", doc: "The four freedoms, as a list.", example: "(freedoms)", min: 0, max: 0, fn: () => arrayToList([intern("run"), intern("study"), intern("share"), intern("improve")]) },
        { name: "jfw", usage: "(jfw)", doc: "Spell out the abbreviation of this site.", example: "(jfw)", min: 0, max: 0, fn: () => "just one interesting new tweak, hours evaporate, fiddling, recompiling, and Emacs for almost everything, workflow is optimal, rice looks dope" },
        { name: "parens", usage: "(parens)", doc: "A word to the wise about parentheses.", example: "(parens)", min: 0, max: 0, fn: () => "(((((((((( there is no such thing as too many parentheses ))))))))))" },
        { name: "guile-version", usage: "(guile-version)", doc: "The Guile release this emulation follows.", example: "(guile-version)", min: 0, max: 0, fn: () => GUILE_VERSION },
        { name: "help", usage: "(help) · ,help", doc: "Print an index of this reference and expand it below the prompt.", example: "(help)", min: 0, max: 0, fn: (a, ctx) => { printHelp(ctx); return UNSPECIFIED; } }
    ]);

    /* ------------------------------------------------------------------ */
    /* 7. Helpers the reference above leans on                            */
    /* ------------------------------------------------------------------ */

    /**
     * @param {number} x @param {number} y @returns {number}
     */
    const gcdOf = (x, y) => {
        let left = Math.abs(x);
        let right = Math.abs(y);
        while (right) {
            const next = left % right;
            left = right;
            right = next;
        }
        return left;
    };

    /**
     * @param {any[]} values
     * @param {(x: any, y: any) => boolean} predicate
     * @returns {boolean} true when PREDICATE holds for every neighbouring pair
     */
    const chain = (values, predicate) => {
        for (let i = 0; i + 1 < values.length; i += 1) {
            if (!predicate(values[i], values[i + 1])) return false;
        }
        return true;
    };

    /**
     * @param {any} value
     * @param {any} list
     * @param {(x: any, y: any) => boolean} same
     * @returns {any} the sublist starting at the match, or #f
     */
    const member = (value, list, same) => {
        let node = list;
        while (node instanceof Pair) {
            if (same(node.car, value)) return node;
            node = node.cdr;
        }
        return false;
    };

    /**
     * @param {any} key
     * @param {any} alist
     * @param {(x: any, y: any) => boolean} same
     * @returns {any} the matching pair, or #f
     */
    const assoc = (key, alist, same) => {
        let node = alist;
        while (node instanceof Pair) {
            if (node.car instanceof Pair && same(node.car.car, key)) return node.car;
            node = node.cdr;
        }
        return false;
    };

    /**
     * `simple-format' and `format': destination, template, arguments.
     * @param {any[]} a
     * @param {any} ctx
     * @param {any} spec
     * @returns {any}
     */
    const format_ = (a, ctx, spec) => {
        const destination = a[0];
        const template = needString(a[1], spec);
        const values = a.slice(2);
        let filled = 0;
        let text = "";
        for (let i = 0; i < template.length; i += 1) {
            if (template[i] !== "~") {
                text += template[i];
                continue;
            }
            i += 1;
            const directive = template[i];
            if (directive === undefined) throw new SchemeError("format: template ends with a lone ~");
            if (directive === "~") {
                text += "~";
            } else if (directive === "%" || directive === "&") {
                text += "\n";
            } else if (directive === "a" || directive === "s") {
                if (filled >= values.length) throw new SchemeError("format: no argument left for ~" + directive);
                text += directive === "a" ? displayValue(values[filled]) : writeValue(values[filled]);
                filled += 1;
            } else {
                throw new SchemeError("format: unsupported directive ~" + directive
                    + " (only ~a, ~s, ~% and ~~ here)");
            }
        }
        if (isFalse(destination)) return text;
        ctx.port.write(text);
        return UNSPECIFIED;
    };

    /** @param {any} ctx */
    const printHelp = (ctx) => {
        ctx.port.write("free world REPL — Guile " + GUILE_VERSION + " flavoured, emulated in the browser\n\n");
        REFERENCE.forEach((entry) => {
            const names = entry.entries.map((item) => item.name);
            const shown = names.slice(0, 8).join(", ") + (names.length > 8 ? ", …" : "");
            ctx.port.write("  " + entry.title + " (" + names.length + ")\n    " + shown + "\n");
        });
        ctx.port.write("\nexpand the reference below the prompt for usage and examples\n");
        ctx.openReference();
    };

    /* ------------------------------------------------------------------ */
    /* 8. The global environment                                          */
    /* ------------------------------------------------------------------ */

    /**
     * Bind everything in REFERENCE, plus the whole c…r family, which is one
     * documented entry but twenty-eight procedures.
     * @param {any} ctx
     * @returns {Frame}
     */
    const createGlobalEnv = (ctx) => {
        const global = new Frame(null);
        REFERENCE.forEach((entry) => {
            entry.entries.forEach((item) => {
                if (item.fn) global.define(item.name, new Primitive(item));
            });
        });
        // Depth 1 would be plain car and cdr, which are already bound above.
        for (let depth = 2; depth <= 4; depth += 1) {
            for (let mask = 0; mask < (1 << depth); mask += 1) {
                let letters = "";
                for (let bit = 0; bit < depth; bit += 1) {
                    letters += ((mask >> bit) & 1) ? "d" : "a";
                }
                const spec = {
                    name: "c" + letters + "r",
                    usage: "(c" + letters + "r pair)",
                    doc: "car/cdr composition",
                    min: 1,
                    max: 1,
                    fn: (a, context, self) => {
                        let value = a[0];
                        // The rightmost letter applies first: (cadr x) = (car (cdr x)).
                        for (let i = letters.length - 1; i >= 0; i -= 1) {
                            const pair = needPair(value, self);
                            value = letters[i] === "a" ? pair.car : pair.cdr;
                        }
                        return value;
                    }
                };
                global.define(spec.name, new Primitive(spec));
            }
        }
        return global;
    };

    /* ------------------------------------------------------------------ */
    /* 9. Reading and running a chunk                                     */
    /* ------------------------------------------------------------------ */

    /**
     * Read and evaluate every form in SOURCE, writing values to the port.
     * Throws IncompleteInput when SOURCE ends inside an open form, which is
     * how the REPL knows to keep reading on the next line.
     * @param {string} source
     * @param {Frame} env
     * @param {any} ctx
     * @returns {number} how many forms were evaluated
     */
    const evaluateSource = (source, env, ctx) => {
        const reader = new Reader(source);
        const forms = [];
        for (;;) {
            reader.skipAtmosphere();
            if (reader.atEnd()) break;
            forms.push(reader.readDatum());
        }
        forms.forEach((form) => {
            const value = evaluate(form, env, ctx);
            // Guile's REPL prints nothing for an unspecified value.
            if (value !== UNSPECIFIED) ctx.port.value(writeValue(value));
        });
        return forms.length;
    };

    /** Turn any thrown value into one line a visitor can act on. */
    const describeError = (error) => {
        if (error instanceof RangeError) return "recursion too deep for this JavaScript stack";
        if (error instanceof IncompleteInput) return "incomplete form: " + error.message;
        if (error instanceof Error) return error.message;
        return String(error);
    };

    /** A port that collects text, for tests and for window.jfwGuile. */
    const createStringPort = () => {
        let text = "";
        return {
            write: (chunk) => { text += chunk; },
            newline: () => { text += "\n"; },
            value: (chunk) => { text += chunk + "\n"; },
            meta: (chunk) => { text += "; " + chunk + "\n"; },
            error: (chunk) => { text += "; error: " + chunk + "\n"; },
            echo: () => {},
            clear: () => {},
            toString: () => text
        };
    };

    /* ------------------------------------------------------------------ */
    /* 10. The page: a port, the reference, the read-eval-print loop      */
    /* ------------------------------------------------------------------ */

    /** Guile's prompt shape, with the free world as the module. */
    const PROMPT = "scheme@(free-world)> ";
    /** What it looks like while a form is still open. */
    const CONTINUATION = "...> ";

    /**
     * The port the interpreter prints to: one DOM node per output line.
     * Value lines are numbered the way Guile numbers them ($1 = 3).
     * @param {HTMLElement} output
     */
    const createDomPort = (output) => {
        const MAX_LINES = 240;
        let line = null;
        let values = 0;

        const trim = () => {
            while (output.childElementCount > MAX_LINES) output.removeChild(output.firstElementChild);
        };

        const put = (kind, text) => {
            if (!line) {
                line = document.createElement("div");
                line.className = "jfw-repl-line jfw-repl-" + kind;
                output.appendChild(line);
                trim();
            }
            line.textContent += text;
            output.scrollTop = output.scrollHeight;
        };

        const endLine = () => {
            line = null;
        };

        return {
            write: (text) => put("text", text),
            newline: endLine,
            value: (text) => {
                values += 1;
                put("value", "$" + values + " = " + text);
                endLine();
            },
            meta: (text) => {
                put("meta", "; " + text);
                endLine();
            },
            error: (text) => {
                put("error", "; error: " + text);
                endLine();
            },
            echo: (text) => {
                put("echo", text);
                endLine();
            },
            clear: () => {
                output.textContent = "";
                line = null;
                // The transcript is gone, so the value counter starts over.
                values = 0;
            }
        };
    };

    /**
     * Fill the expandable reference from REFERENCE itself, so the panel and
     * the interpreter can never describe different things.
     * @param {HTMLElement} body
     * @param {(example: string) => void} insert
     */
    const buildReference = (body, insert) => {
        body.textContent = "";
        REFERENCE.forEach((entry) => {
            const section = document.createElement("section");
            section.className = "jfw-ref-group";
            const title = document.createElement("h3");
            title.className = "jfw-ref-group-title";
            title.textContent = entry.title;
            const list = document.createElement("ul");
            list.className = "jfw-ref-list";
            entry.entries.forEach((item) => {
                const element = document.createElement("li");
                const button = document.createElement("button");
                button.type = "button";
                button.className = "jfw-ref-item";
                const usage = document.createElement("code");
                usage.className = "jfw-ref-usage";
                usage.textContent = item.usage;
                const doc = document.createElement("span");
                doc.className = "jfw-ref-doc";
                doc.textContent = item.doc;
                if (item.example) {
                    button.setAttribute("data-jfw-ref-example", item.example);
                    button.title = "Insert " + item.example;
                } else {
                    button.disabled = true;
                }
                button.append(usage, doc);
                element.appendChild(button);
                list.appendChild(element);
            });
            section.append(title, list);
            body.appendChild(section);
        });
        body.addEventListener("click", (event) => {
            const target = event.target;
            if (!(target instanceof Element)) return;
            const button = target.closest("[data-jfw-ref-example]");
            if (!button) return;
            insert(button.getAttribute("data-jfw-ref-example") || "");
        });
    };

    const HELP_LINES = [
        "Help Commands [abbrev]:",
        "",
        " ,help                  [,h] - Show this help.",
        " ,ref                   [,r] - Expand the procedure reference below.",
        " ,version               [,v] - Show the emulated Guile version.",
        " ,clear                 [,c] - Clear the transcript.",
        " ,show [w | c]                - Warranty, and copying conditions.",
        " ,quit                  [,q] - Leave the REPL.",
        "",
        "Expressions: press RET to evaluate one. An unclosed `(' keeps reading on",
        "the next line, and the arrow keys walk back through what you typed."
    ];

    const WARRANTY_LINES = [
        "THERE IS NO WARRANTY FOR THIS EMULATION, TO THE EXTENT PERMITTED BY",
        "APPLICABLE LAW.",
        "",
        "This page is free software under the GNU Affero General Public License v3",
        "or newer; the real GNU Guile is under the GNU LGPL v3 or newer. The texts:",
        "  <https://www.gnu.org/licenses/agpl-3.0.html>",
        "  <https://www.gnu.org/licenses/lgpl-3.0.html>"
    ];

    const COPYING_LINES = [
        "You may redistribute and/or modify this page under the terms of the GNU",
        "Affero General Public License as published by the Free Software Foundation,",
        "either version 3 of the License, or (at your option) any later version.",
        "",
        "Source: <https://codeberg.org/jjba23/jointhefreeworld>"
    ];

    /**
     * Turn one .jfw-repl section into a live REPL.
     * @param {Element} section
     */
    const wireRepl = (section) => {
        const form = section.querySelector(".jfw-repl-form");
        const input = section.querySelector(".jfw-repl-input");
        const output = section.querySelector(".jfw-repl-output");
        const label = section.querySelector(".jfw-repl-label");
        const details = section.querySelector("[data-jfw-repl-reference]");
        const referenceBody = section.querySelector("[data-jfw-repl-reference-body]");
        if (!(form instanceof HTMLFormElement) || !(input instanceof HTMLInputElement)) return;
        if (!(output instanceof HTMLElement) || !(label instanceof HTMLElement)) return;

        const port = createDomPort(output);
        const openReference = () => {
            if (details instanceof HTMLDetailsElement) details.open = true;
        };
        const ctx = { port, openReference };
        const env = createGlobalEnv(ctx);

        // The prose on the page states how many primitives there are; take
        // the number from the environment itself rather than from memory.
        section.querySelectorAll("[data-jfw-repl-count]").forEach((node) => {
            node.textContent = String(env.vars.size);
        });

        /* --- the reference: built once, and only when first opened ------ */

        let built = false;
        const ensureReference = () => {
            if (built || !(referenceBody instanceof HTMLElement)) return;
            built = true;
            buildReference(referenceBody, (example) => {
                input.value = example;
                input.focus();
                input.setSelectionRange(example.length, example.length);
            });
        };
        if (details instanceof HTMLDetailsElement) {
            details.addEventListener("toggle", () => {
                if (details.open) ensureReference();
            });
        }

        /* --- the transcript -------------------------------------------- */

        const writeLines = (lines) => {
            lines.forEach((text) => port.write(text + "\n"));
        };
        writeLines([
            "GNU Guile " + GUILE_VERSION + " — emulated in your browser by static/js/guile-repl.js",
            "Copyright (C) 1995-2024 Free Software Foundation, Inc.",
            "",
            "Guile comes with ABSOLUTELY NO WARRANTY; for details type `,show w'.",
            "",
            "Enter `,help' for help."
        ]);
        port.meta("a subset of Guile: no macros, no modules, no rationals, no ports");
        port.meta("an unclosed `(' keeps reading on the next line; the reference is below");

        /* --- reading, evaluating, printing ----------------------------- */

        let pending = "";
        /** @type {string[]} */
        const history = [];
        let cursor = 0;

        const setPrompt = () => {
            label.textContent = pending === "" ? PROMPT : CONTINUATION;
            label.classList.toggle("is-continuation", pending !== "");
        };

        const runMetaCommand = (source) => {
            const parts = source.slice(1).trim().split(/\s+/);
            const name = parts[0];
            const argument = parts.slice(1).join(" ");
            if (name === "help" || name === "h") {
                writeLines(HELP_LINES);
                ensureReference();
                openReference();
                return;
            }
            if (name === "ref" || name === "r") {
                ensureReference();
                openReference();
                port.meta("the procedure reference is below the prompt");
                return;
            }
            if (name === "version" || name === "v") {
                port.value('"' + GUILE_VERSION + '"');
                return;
            }
            if (name === "clear" || name === "c") {
                port.clear();
                return;
            }
            if (name === "show") {
                writeLines(argument === "c" ? COPYING_LINES : WARRANTY_LINES);
                return;
            }
            if (name === "quit" || name === "q") {
                port.meta("there is no leaving the free world from here — closing the tab is your ,quit");
                return;
            }
            port.error("Unrecognized REPL command: ," + name + " — try ,help");
        };

        const submit = (source) => {
            const reading = pending;
            if (source.trim() === "" && reading === "") return;
            const chunk = reading === "" ? source : reading + "\n" + source;
            port.echo((reading === "" ? PROMPT : CONTINUATION) + source);
            if (reading === "" && source.trim().charAt(0) === ",") {
                pending = "";
                setPrompt();
                runMetaCommand(source.trim());
                return;
            }
            beginEvaluation();
            try {
                evaluateSource(chunk, env, ctx);
                pending = "";
            } catch (error) {
                if (error instanceof IncompleteInput) {
                    // Keep reading: the next line continues this form.
                    pending = chunk;
                    setPrompt();
                    return;
                }
                pending = "";
                port.error(describeError(error));
            }
            setPrompt();
        };

        form.addEventListener("submit", (event) => {
            event.preventDefault();
            const source = input.value;
            if (source.trim() !== "") {
                history.push(source);
                cursor = history.length;
            }
            input.value = "";
            submit(source);
        });

        input.addEventListener("keydown", (event) => {
            if (event.key === "ArrowUp") {
                event.preventDefault();
                cursor = Math.max(0, cursor - 1);
                input.value = history[cursor] || "";
            } else if (event.key === "ArrowDown") {
                event.preventDefault();
                cursor = Math.min(history.length, cursor + 1);
                input.value = history[cursor] || "";
            }
        });

        section.querySelectorAll(".jfw-example").forEach((example) => {
            example.addEventListener("click", () => {
                submit(example.textContent || "");
                input.focus();
            });
        });

        setPrompt();
    };

    if (typeof document !== "undefined") {
        document.querySelectorAll(".jfw-repl").forEach((section) => wireRepl(section));
    }

    /* ------------------------------------------------------------------ */
    /* 11. A handle for the console (and for tests)                       */
    /* ------------------------------------------------------------------ */

    if (typeof window !== "undefined") {
        /**
         * window.jfwGuile.run("(map 1+ '(1 2 3))") evaluates in a fresh
         * environment and returns what a terminal would have shown.
         */
        /** @type {any} */ (window).jfwGuile = {
            version: GUILE_VERSION,
            reference: () => REFERENCE.map((entry) => ({
                title: entry.title,
                entries: entry.entries.map((item) => ({
                    name: item.name,
                    usage: item.usage,
                    doc: item.doc,
                    example: item.example || null,
                    bound: Boolean(item.fn)
                }))
            })),
            run: (source) => {
                const port = createStringPort();
                const local = { port, openReference: () => {} };
                const env = createGlobalEnv(local);
                beginEvaluation();
                try {
                    evaluateSource(source, env, local);
                } catch (error) {
                    port.error(describeError(error));
                }
                return port.toString();
            }
        };
    }
})();
