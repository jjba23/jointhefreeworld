/*
 * freeworld
 *
 * SPDX-License-Identifier: MIT
 * Copyright © Josep Bigorra <jjbigorra@gmail.com>
 */

// @ts-check
"use strict";

/*
 * Small, dependency-free sprinkles for jointhefreeworld.org:
 * the theme chooser, the nav's "more" menu, the reading-progress hairline,
 * the mark that follows the reader down the rail the build wrote, copy
 * buttons on code blocks, a scroll reveal, a typewriter tagline, an
 * interactive acronym and a "free" easter egg. Everything degrades
 * gracefully when JavaScript is unavailable or the visitor prefers reduced
 * motion: none of these adds content, so a page without scripting still says
 * everything it has to say.
 *
 * The home page's Guile Scheme REPL lives apart, in guile-repl.js, because
 * it is a small interpreter with a reference attached rather than a sprinkle.
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
    /* Reading progress                                                   */
    /* ------------------------------------------------------------------ */

    /*
     * A hairline of gold across the top of the window that fills as the
     * reader moves down the page. The stylesheet draws it from a single
     * custom property, and this only writes that property: no element is
     * created and nothing is measured twice.
     *
     * The measurement happens in the scroll handler rather than in an
     * animation frame it schedules. Reading one number and writing one
     * property is cheaper than the frame it would wait for, and the value is
     * right the first time the reader looks at it.
     */
    (function () {
        const bar = document.querySelector("[data-jfw-progress]");
        if (!bar) return;

        const root = document.documentElement;

        const paint = () => {
            const scrollable = root.scrollHeight - root.clientHeight;
            // A short page has nothing to report, so the line stays empty
            // rather than claiming to be complete.
            const ratio = scrollable > 0 ? root.scrollTop / scrollable : 0;
            const clamped = Math.min(1, Math.max(0, ratio));
            root.style.setProperty("--jfw-progress", clamped.toFixed(4));
        };

        window.addEventListener("scroll", paint, { passive: true });
        window.addEventListener("resize", paint, { passive: true });
        paint();
    })();

    /* ------------------------------------------------------------------ */
    /* Copy buttons on code blocks                                        */
    /* ------------------------------------------------------------------ */

    /*
     * The build writes a copy button into the corner of every code block, so
     * the button is part of the page a reader receives and does not wait for
     * a script to appear. What is left here is the click: read the block
     * beside the button, put it on the clipboard and say so. The label is
     * outside the block, so it can never end up in what is copied.
     */
    (function () {
        const buttons = Array.from(document.querySelectorAll(".jfw-code .jfw-copy"));
        if (buttons.length === 0) return;

        /** Put TEXT on the clipboard, with a fallback for older engines. */
        const copyText = (/** @type {string} */ text) => {
            if (navigator.clipboard && navigator.clipboard.writeText) {
                return navigator.clipboard.writeText(text).catch(() => legacyCopy(text));
            }
            return legacyCopy(text);
        };

        /**
         * The clipboard API needs a secure context; a development server on
         * plain HTTP is not one, so a hidden textarea keeps the button
         * working there.
         * @param {string} text
         */
        const legacyCopy = (text) => {
            const field = document.createElement("textarea");
            field.value = text;
            field.setAttribute("readonly", "true");
            field.style.position = "fixed";
            field.style.top = "-1000px";
            field.style.opacity = "0";
            document.body.appendChild(field);
            field.select();
            try {
                document.execCommand("copy");
            } catch (error) {
                // Nothing to report: the button simply will not say "copied".
            }
            field.remove();
            return Promise.resolve();
        };

        buttons.forEach((button) => {
            const wrapper = button.closest(".jfw-code");
            const pre = wrapper ? wrapper.querySelector("pre") : null;
            if (!pre) return;
            const text = (pre.textContent || "").replace(/\s+$/, "");
            if (text.trim() === "") return;

            let reset = 0;
            button.addEventListener("click", () => {
                copyText(text).then(() => {
                    button.textContent = "copied";
                    button.classList.add("is-copied");
                    window.clearTimeout(reset);
                    reset = window.setTimeout(() => {
                        button.textContent = "copy";
                        button.classList.remove("is-copied");
                    }, 1600);
                });
            });
        });
    })();

    /* ------------------------------------------------------------------ */
    /* Sections arrive as they are reached                                */
    /* ------------------------------------------------------------------ */

    /*
     * The blocks of the article fade and rise a few pixels as they come into
     * view, one just behind the other, which makes a long page feel like it
     * is being laid down rather than dumped. The class is added here rather
     * than written in the stylesheet, so with scripting off nothing is ever
     * hidden, and a visitor who asked for less motion gets the whole page at
     * once without a single transition to sit through.
     */
    if (!prefersReducedMotion && typeof IntersectionObserver === "function") {
        const container = document.getElementById("content");
        const blocks = container ? Array.from(container.children) : [];
        if (blocks.length > 0) {
            let revealed = 0;

            const observer = new IntersectionObserver((entries) => {
                let shown = 0;
                entries.forEach((entry) => {
                    if (!entry.isIntersecting) return;
                    const element = /** @type {HTMLElement} */ (entry.target);
                    // Elements entering together are staggered, so a page
                    // does not arrive as one flat wall of fading text, but
                    // only just: a reader should never wait for the page.
                    element.style.setProperty("--jfw-reveal-delay", `${Math.min(shown, 3) * 40}ms`);
                    shown += 1;
                    element.classList.add("is-visible");
                    revealed += 1;
                    observer.unobserve(element);
                });
                // The frame reaches a fifth of the window below the fold, so
                // a block begins to arrive while it is still just out of
                // sight and is already there when the eye reaches it. A
                // negative margin would do the opposite and make the page
                // feel like it is catching up with the reader.
            }, { rootMargin: "0px 0px 20% 0px", threshold: 0 });

            blocks.forEach((element) => {
                element.classList.add("jfw-reveal");
                observer.observe(element);
            });

            // Anything still hidden once the page has finished loading is
            // content nobody asked to have hidden, so the fallback reveals
            // everything the observer has not reached. It only runs when the
            // observer has not revealed a single block, which is the case
            // worth protecting against.
            window.addEventListener("load", () => {
                window.setTimeout(() => {
                    if (revealed > 0) return;
                    blocks.forEach((element) => element.classList.add("is-visible"));
                }, 900);
            });
        }
    }

    /* ------------------------------------------------------------------ */
    /* The "more" menu                                                    */
    /* ------------------------------------------------------------------ */

    /*
     * The bar keeps five places and folds the rest behind a disclosure, so
     * the disclosure has to behave like a menu: a click anywhere else, or
     * Escape, puts it away. Both behaviours are additions to a `details'
     * element that already opens and closes on its own, so a reader without
     * scripting still has every link.
     */
    (function () {
        const more = document.querySelector("[data-jfw-nav-more]");
        if (!more) return;

        document.addEventListener("click", (event) => {
            if (!more.open) return;
            const target = event.target;
            if (target instanceof Node && more.contains(target)) return;
            more.open = false;
        });

        document.addEventListener("keydown", (event) => {
            if (!more.open || event.key !== "Escape") return;
            more.open = false;
            const summary = more.querySelector("summary");
            if (summary instanceof HTMLElement) summary.focus();
        });
    })();

    /* ------------------------------------------------------------------ */
    /* On this page: following the reader down the rail                   */
    /* ------------------------------------------------------------------ */

    /*
     * The rail itself is written by the build, out of the page's own
     * headings, so it is there for a reader without scripting and the layout
     * does not shift when a script arrives. What is left for the browser is
     * the mark that follows the reader down a list that already exists: the
     * last entry whose heading has passed the upper third of the screen.
     *
     * It is driven by the scroll rather than observed, because it answers the
     * question at every scroll position instead of only at the moment a
     * heading crosses a boundary, and because a page can sit between two
     * headings for a long time. A rail of six entries costs six measurements
     * per scroll event.
     */
    (function () {
        const links = Array.from(document.querySelectorAll(".article-rail-link"));
        if (links.length < 2) return;

        // An entry points at the identifier of the anchor its heading
        // carries, so the two are matched by id rather than by position.
        const entries = links
            .map((link) => ({
                link,
                target: document.getElementById(decodeURIComponent(link.hash.replace(/^#/, ""))),
            }))
            .filter((entry) => entry.target !== null);
        if (entries.length < 2) return;

        const markCurrent = () => {
            const line = window.innerHeight * 0.32;
            let current = entries[0];
            entries.forEach((entry) => {
                if (entry.target.getBoundingClientRect().top <= line) current = entry;
            });
            entries.forEach((entry) => entry.link.classList.remove("is-current"));
            current.link.classList.add("is-current");
        };

        window.addEventListener("scroll", markCurrent, { passive: true });
        window.addEventListener("resize", markCurrent, { passive: true });
        markCurrent();
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
