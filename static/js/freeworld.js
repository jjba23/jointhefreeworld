/* freeworld
*
* Copyright © Josep Bigorra <jjbigorra@gmail.com>
*
* freeworld is free software: you can redistribute it and/or modify
* it under the terms of the GNU Affero General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*
* freeworld is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU Affero General Public License for more details.
*
* You should have received a copy of the GNU Affero General Public License
* along with freeworld.  If not, see <https://www.gnu.org/licenses/>.
*/

// @ts-check
"use strict";

/*
 * Small, dependency-free sprinkles for jointhefreeworld.org:
 * a typewriter tagline, an interactive acronym, a tiny browser-side Lisp
 * REPL, and a "free" easter egg. Everything degrades gracefully when
 * JavaScript is unavailable or the visitor prefers reduced motion.
 */
(function () {
    const prefersReducedMotion = window.matchMedia
        && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    /* ------------------------------------------------------------------ */
    /* Theme chooser: light / dark / follow the system                    */
    /* ------------------------------------------------------------------ */

    (function () {
        // Must match jfw/theme-storage-key in jointhefreeworld-site.el and
        // the inline script that restores the theme before first paint.
        const STORAGE_KEY = "jfw-theme";
        // Added to <html> for the lifetime of a theme cross-fade so the
        // stylesheet can give it a longer duration than a page navigation.
        const TRANSITION_CLASS = "theme-transition";
        const root = document.documentElement;
        const group = document.querySelector("[data-jfw-theme-toggle]");
        if (!group) return;

        /** @type {HTMLInputElement[]} */
        const inputs = Array.from(group.querySelectorAll(".theme-toggle-input"))
            .filter((el) => el instanceof HTMLInputElement);
        if (inputs.length === 0) return;

        /** The visitor's explicit choice, or "system" when none was made. */
        const currentChoice = () => root.getAttribute("data-theme") || "system";

        // Keep the native radios in step with the resolved theme. The visible
        // highlight is driven by CSS from data-theme, so it is already correct
        // on first paint and never flashes the wrong option.
        const syncInputs = () => {
            const choice = currentChoice();
            inputs.forEach((input) => {
                input.checked = input.value === choice;
            });
        };

        const applyChoice = (choice) => {
            // "system" means: drop the attribute and follow the OS again.
            if (choice === "system") {
                root.removeAttribute("data-theme");
            } else {
                root.setAttribute("data-theme", choice);
            }
            try {
                if (choice === "system") {
                    localStorage.removeItem(STORAGE_KEY);
                } else {
                    localStorage.setItem(STORAGE_KEY, choice);
                }
            } catch (error) {
                // Private windows can make localStorage unavailable; the
                // choice still applies for the current page view.
            }
            syncInputs();
        };

        // Apply the choice inside a view transition so the palette cross-fades
        // instead of snapping. Browsers without the API, and visitors who ask
        // for reduced motion, simply get the change applied immediately.
        const applyWithCrossFade = (choice) => {
            if (typeof document.startViewTransition !== "function" || prefersReducedMotion) {
                applyChoice(choice);
                return;
            }
            try {
                root.classList.add(TRANSITION_CLASS);
                document.startViewTransition(() => applyChoice(choice)).finished
                    .finally(() => root.classList.remove(TRANSITION_CLASS));
            } catch (error) {
                // A failed transition must never leave the theme unapplied.
                root.classList.remove(TRANSITION_CLASS);
                applyChoice(choice);
            }
        };

        inputs.forEach((input) => {
            input.addEventListener("change", () => {
                if (input.checked) applyWithCrossFade(input.value);
            });
        });

        syncInputs();
    })();

    /* ------------------------------------------------------------------ */
    /* Typewriter tagline                                                  */
    /* ------------------------------------------------------------------ */

    /**
     * Reveal the text of an element one character at a time. The full text
     * lives in a data attribute so the original markup can be restored once
     * typing finishes.
     * @param {HTMLElement} el
     */
    const typewrite = (el) => {
        const fullText = el.getAttribute("data-jfw-typewriter");
        if (!fullText) return;
        const target = /** @type {HTMLElement} */ (el.querySelector("em") || el);
        const originalHTML = el.innerHTML;
        let index = 0;
        target.textContent = "";
        const step = () => {
            index += 1;
            target.textContent = fullText.slice(0, index);
            if (index < fullText.length) {
                // Type fast at first, then settle into a natural rhythm.
                const delay = index < 12 ? 40 : 22;
                window.setTimeout(step, delay);
            } else {
                // Restore the original markup (e.g. the <em> wrapper).
                el.innerHTML = originalHTML;
            }
        };
        step();
    };

    if (!prefersReducedMotion) {
        document.querySelectorAll("[data-jfw-typewriter]").forEach((el) => {
            typewrite(/** @type {HTMLElement} */ (el));
        });
    }

    /* ------------------------------------------------------------------ */
    /* Interactive acronym                                                */
    /* ------------------------------------------------------------------ */

    document.querySelectorAll("[data-jfw-acronym]").forEach((widget) => {
        const letters = Array.from(widget.querySelectorAll(".jfw-letter"));
        const fullPhrase = widget.querySelector(".jfw-acronym-full");

        const setOpen = (/** @type {Element} */ letter, /** @type {boolean} */ open) => {
            letter.classList.toggle("is-open", open);
            letter.setAttribute("aria-expanded", String(open));
        };

        letters.forEach((letter) => {
            letter.setAttribute("aria-expanded", "false");
            letter.addEventListener("click", () => {
                setOpen(letter, !letter.classList.contains("is-open"));
            });
        });

        widget.querySelectorAll("[data-action]").forEach((button) => {
            button.addEventListener("click", () => {
                const expand = button.getAttribute("data-action") === "expand";
                letters.forEach((letter) => setOpen(letter, expand));
                if (fullPhrase instanceof HTMLElement) {
                    fullPhrase.hidden = !expand;
                }
            });
        });
    });

    /* ------------------------------------------------------------------ */
    /* Tiny Lisp REPL                                                      */
    /* ------------------------------------------------------------------ */

    class ReplError extends Error {}

    /**
     * Read every form in SOURCE, returning them as a flat array.
     * @param {string} source
     * @returns {any[]}
     */
    const readAll = (source) => {
        let i = 0;
        const n = source.length;

        const skipWhitespace = () => {
            while (i < n && /\s/.test(source[i])) i += 1;
        };

        /** @returns {any} */
        const readForm = () => {
            skipWhitespace();
            if (i >= n) throw new ReplError("unexpected end of input");
            const ch = source[i];
            if (ch === "(") {
                i += 1;
                /** @type {any[]} */
                const list = [];
                skipWhitespace();
                while (i < n && source[i] !== ")") {
                    list.push(readForm());
                    skipWhitespace();
                }
                if (i >= n) throw new ReplError("missing a closing ')'");
                i += 1;
                return list;
            }
            if (ch === ")") throw new ReplError("unexpected ')'");
            if (ch === "\"") {
                i += 1;
                let text = "";
                while (i < n && source[i] !== "\"") {
                    if (source[i] === "\\" && i + 1 < n) {
                        i += 1;
                        text += source[i];
                    } else {
                        text += source[i];
                    }
                    i += 1;
                }
                if (i >= n) throw new ReplError("unterminated string");
                i += 1;
                return text;
            }
            let atom = "";
            while (i < n && !/[\s()"']/.test(source[i])) {
                atom += source[i];
                i += 1;
            }
            if (atom === "") throw new ReplError("unexpected character '" + source[i] + "'");
            const asNumber = Number(atom);
            return Number.isNaN(asNumber) ? atom : asNumber;
        };

        const forms = [];
        skipWhitespace();
        while (i < n) {
            forms.push(readForm());
            skipWhitespace();
        }
        return forms;
    };

    /**
     * Format a value the way a Lisp REPL would print it.
     * @param {any} value
     * @returns {string}
     */
    const print = (value) => {
        if (typeof value === "string") return "\"" + value + "\"";
        if (Array.isArray(value)) return "(" + value.map(print).join(" ") + ")";
        return String(value);
    };

    /**
     * @param {number[]} nums
     * @returns {boolean}
     */
    const allNumbers = (nums) => nums.every((x) => typeof x === "number");

    const commands = {
        "help": () => [
            "Try (+ 1 2), (- 10 4), (* 6 7), (/ 22 7).",
            "Play with (parens), (free-world) and (conses).",
            "Arithmetic is variadic: (+ 1 2 3 4)."
        ].join(" "),
        "parens": () => "(((((((((( there is no such thing as too many parentheses ))))))))))",
        "free-world": () => "Welcome, friend. The four freedoms are yours: run, study, share, improve.",
        "conses": () => ["a", ["b", ["c", "()"]]],
        "freedoms": () => ["run", "study", "share", "improve"],
        "jfw": () => "jointhefreeworld — just one interesting new tweak, hours evaporate, fiddling, recompiling, and Emacs for almost everything, workflow is optimal, rice looks dope."
    };

    /**
     * Evaluate a single form in a deliberately tiny, safe subset of Lisp.
     * There is no `eval`: only the operations registered below can run.
     * @param {any} form
     * @returns {any}
     */
    const evaluate = (form) => {
        if (typeof form === "number" || typeof form === "string") return form;

        if (Array.isArray(form)) {
            if (form.length === 0) return [];
            const operator = form[0];

            if (Array.isArray(operator)) {
                // Evaluating the operator's own result, e.g. ((+ 1 2) 3).
                return evaluate(operator);
            }

            const args = form.slice(1).map(evaluate);

            if (operator === "+" || operator === "-" || operator === "*" || operator === "/") {
                if (!allNumbers(args)) throw new ReplError(operator + " expects numbers");
                if (args.length === 0 && operator !== "+" && operator !== "*") {
                    throw new ReplError(operator + " needs at least one argument");
                }
                return args.reduce((acc, value) => {
                    switch (operator) {
                        case "+": return acc + value;
                        case "-": return acc - value;
                        case "*": return acc * value;
                        default:
                            if (value === 0) throw new ReplError("division by zero");
                            return acc / value;
                    }
                });
            }

            if (typeof operator === "string" && Object.prototype.hasOwnProperty.call(commands, operator)) {
                // @ts-ignore - commands is a small, known table.
                return commands[operator](args);
            }

            if (typeof operator === "string" && operator === "quote") {
                return form.slice(1);
            }

            throw new ReplError(
                typeof operator === "string"
                    ? operator + " is not defined here"
                    : "that is not a callable expression"
            );
        }

        throw new ReplError(form + " is not defined here");
    };

    /**
     * @param {string} source
     * @returns {string[]}
     */
    const runSource = (source) => {
        const trimmed = source.trim();
        if (trimmed === "") return [];
        return readAll(trimmed).map((form) => print(evaluate(form)));
    };

    document.querySelectorAll(".jfw-repl").forEach((repl) => {
        const form = repl.querySelector(".jfw-repl-form");
        const input = repl.querySelector(".jfw-repl-input");
        const output = repl.querySelector(".jfw-repl-output");
        if (!(form instanceof HTMLFormElement) || !(input instanceof HTMLInputElement) || !output) {
            return;
        }

        /** @type {string[]} */
        const history = [];
        let cursor = 0;

        const write = (/** @type {string} */ text, /** @type {string} */ kind) => {
            const line = document.createElement("div");
            line.className = "jfw-repl-line jfw-repl-" + kind;
            line.textContent = text;
            output.appendChild(line);
            output.scrollTop = output.scrollHeight;
        };

        const submit = (/** @type {string} */ source) => {
            if (source.trim() === "") return;
            history.push(source);
            cursor = history.length;
            write("(free)> " + source, "echo");
            try {
                const results = runSource(source);
                if (results.length === 0) {
                    write("; no value", "meta");
                } else {
                    results.forEach((result) => write(result, "value"));
                }
            } catch (error) {
                write("; " + (error instanceof Error ? error.message : String(error)), "error");
            }
        };

        form.addEventListener("submit", (event) => {
            event.preventDefault();
            submit(input.value);
            input.value = "";
        });

        input.addEventListener("keydown", (event) => {
            if (event.key === "ArrowUp" && history.length > 0) {
                event.preventDefault();
                cursor = Math.max(0, cursor - 1);
                input.value = history[cursor] || "";
            } else if (event.key === "ArrowDown" && history.length > 0) {
                event.preventDefault();
                cursor = Math.min(history.length, cursor + 1);
                input.value = history[cursor] || "";
            }
        });

        repl.querySelectorAll(".jfw-example").forEach((example) => {
            example.addEventListener("click", () => {
                // @ts-ignore - textContent is a string.
                submit(example.textContent);
                input.focus();
            });
        });

        write("; the free world REPL — type (help) to begin", "meta");
    });

    /* ------------------------------------------------------------------ */
    /* "free" easter egg                                                   */
    /* ------------------------------------------------------------------ */

    if (!prefersReducedMotion) {
        let buffer = "";
        const GLYPHS = ["(", ")"];
        document.addEventListener("keydown", (event) => {
            if (event.key.length !== 1) return;
            const target = event.target;
            if (target instanceof HTMLElement
                && (target.tagName === "INPUT" || target.tagName === "TEXTAREA")) {
                return;
            }
            buffer = (buffer + event.key.toLowerCase()).slice(-4);
            if (buffer !== "free") return;

            const layer = document.createElement("div");
            layer.className = "jfw-paren-rain";
            layer.setAttribute("aria-hidden", "true");
            for (let i = 0; i < 32; i += 1) {
                const glyph = document.createElement("span");
                glyph.className = "jfw-paren";
                glyph.textContent = GLYPHS[i % GLYPHS.length];
                glyph.style.left = (Math.random() * 100).toFixed(2) + "%";
                glyph.style.animationDelay = (Math.random() * 0.6).toFixed(2) + "s";
                glyph.style.fontSize = (1 + Math.random() * 1.6).toFixed(2) + "rem";
                layer.appendChild(glyph);
            }
            document.body.appendChild(layer);
            window.setTimeout(() => layer.remove(), 2600);
        });
    }
})();
