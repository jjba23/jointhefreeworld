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
 * the theme chooser, a typewriter tagline, an interactive acronym and a
 * "free" easter egg. Everything degrades gracefully when JavaScript is
 * unavailable or the visitor prefers reduced motion.
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
