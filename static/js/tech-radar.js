/* tech-radar
*
* Copyright © Josep Bigorra <jjbigorra@gmail.com>
*
* tech-radar is free software: you can redistribute it and/or modify
* it under the terms of the GNU Affero General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*
* tech-radar is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU Affero General Public License for more details.
*
* You should have received a copy of the GNU Affero General Public License
* along with tech-radar.  If not, see <https://www.gnu.org/licenses/>.
*/

// @ts-check
"use strict";

/*
 * Draws the tech radar from the article it sits on.
 *
 * The Org source stays the only source of truth: each quadrant is a
 * `section.jfw-radar-quadrant`, each ring is the sub-heading under it, and
 * each blip is a list item. Nothing here hard-codes a technology, a ring
 * name or a count, so editing the article is what changes the radar — there
 * is no second data file to drift away from the prose.
 *
 * Loaded only on pages that ask for it with `#+SCRIPTS: radar`.
 */
(function () {
    const container = document.querySelector("[data-jfw-radar]");
    if (!container) return;

    const canvas = container.querySelector("[data-jfw-radar-canvas]");
    if (!canvas) return;

    const legend = container.querySelector("[data-jfw-radar-legend]");
    const quadrantLegend = container.querySelector("[data-jfw-radar-quadrants]");
    const labelsButton = container.querySelector("[data-jfw-radar-labels]");
    const prefersReducedMotion = window.matchMedia
        && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    const SVG_NS = "http://www.w3.org/2000/svg";
    const SIZE = 1000;
    const CENTER = SIZE / 2;
    /* Leaves room for the blip labels that stick out past the last ring. */
    const OUTER_RADIUS = 450;
    /* How much of a sector is left empty on either side, so neighbouring
       layers never touch. A share of the sector rather than a fixed angle,
       so a page cutting four layers and a page cutting six both get even
       gaps and the same comfortable amount of room for their blips. */
    const SECTOR_GAP_SHARE = 0.06;
    /* The widest a gap is allowed to grow, in degrees. */
    const SECTOR_GAP_MAX = 5;

    /* Drawn from the middle outwards, whatever order the article lists them in. */
    const RING_ORDER = ["adopt", "trial", "assess", "deprecate"];

    /* How a movement marker is drawn and explained. */
    const MOVEMENTS = {
        "new": { slug: "new", hint: "new since the last revision" },
        "moved in": { slug: "in", hint: "closer to the middle than before" },
        "moved out": { slug: "out", hint: "further from the middle than before" },
        "no change": { slug: "same", hint: "unchanged since the last revision" }
    };

    const MOVEMENT_PATTERN = new RegExp(
        "\\s*\\(\\s*(" + Object.keys(MOVEMENTS).join("|") + ")\\s*\\)\\s*$", "i");

    /* ------------------------------------------------------------------ */
    /* Read the article                                                   */
    /* ------------------------------------------------------------------ */

    /**
     * Return the readable text of a heading, with its anchor link and the
     * ring's leading emoji removed ("✅ Adopt" -> "Adopt").
     * @param {Element | null} heading
     * @returns {string}
     */
    function headingText(heading) {
        if (!heading) return "";
        const clone = /** @type {Element} */ (heading.cloneNode(true));
        clone.querySelectorAll(".anchor").forEach((anchor) => anchor.remove());
        return (clone.textContent || "")
            .replace(/^[^\p{L}\p{N}]+/u, "")
            .replace(/\s+/g, " ")
            .trim();
    }

    /**
     * Return a stable key for a label, used to match a heading against the
     * known rings and to hang CSS off it: "Adopt" -> "adopt".
     * @param {string} label
     * @returns {string}
     */
    function slugify(label) {
        return label.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
    }

    /**
     * Shorten a caption to something that fits beside a blip. A few entries
     * are whole sentences; the tooltip, the aria label and the list below
     * all keep the full text.
     * @param {string} text
     * @param {number} limit
     * @returns {string}
     */
    function shorten(text, limit) {
        if (text.length <= limit) return text;
        const cut = text.slice(0, limit);
        const space = cut.lastIndexOf(" ");
        return (space > limit * 0.5 ? cut.slice(0, space) : cut).trim() + "…";
    }

    /**
     * Describe one list item: its label, its link, its note and how it moved.
     * @param {Element} item
     * @param {string} quadrant
     * @param {string} ring
     * @param {number} index
     * @returns {any}
     */
    function readBlip(item, quadrant, ring, index) {
        const text = (item.textContent || "").replace(/\s+/g, " ").trim();
        /* A note trails the entry after an em dash; anything else stays put. */
        const parts = text.split(/\s*—\s*/, 2);
        let label = parts[0];
        const note = parts.length > 1 ? parts[1] : "";
        let movement = null;
        const match = label.match(MOVEMENT_PATTERN);
        if (match) {
            movement = MOVEMENTS[/** @type {keyof MOVEMENTS} */ (match[1].toLowerCase())];
            label = label.slice(0, match.index).trim();
        }
        const link = item.querySelector("a");
        return {
            label: label,
            note: note,
            movement: movement,
            href: link ? link.getAttribute("href") : null,
            quadrant: quadrant,
            ring: ring,
            index: index,
            element: item
        };
    }

    /**
     * Read every quadrant, ring and blip from the article.
     * @returns {{ quadrants: any[], rings: any[], blips: any[] }}
     */
    function readRadar() {
        /** @type {any[]} */
        const quadrants = [];
        /** @type {any[]} */
        const rings = [];
        /** @type {any[]} */
        const blips = [];
        let blipIndex = 0;

        document.querySelectorAll("section.jfw-radar-quadrant").forEach((section) => {
            const name = headingText(section.querySelector("h2"));
            if (!name) return;
            const quadrant = { label: name, slug: slugify(name), index: quadrants.length, count: 0, section: section, details: null };
            quadrants.push(quadrant);

            /* Walk in document order rather than over direct children: the
               exporter wraps each sub-heading's list in its own container
               div, so the lists are grandchildren of the section. */
            const walker = document.createTreeWalker(section, NodeFilter.SHOW_ELEMENT);
            /** @type {any} */
            let currentRing = null;
            while (walker.nextNode()) {
                const node = /** @type {Element} */ (walker.currentNode);
                if (node.tagName === "H3") {
                    const ringName = headingText(node);
                    if (!ringName) continue;
                    const slug = slugify(ringName);
                    currentRing = rings.find((ring) => ring.slug === slug);
                    if (!currentRing) {
                        currentRing = { label: ringName, slug: slug, count: 0 };
                        rings.push(currentRing);
                    }
                    continue;
                }
                if (node.tagName !== "UL" || !currentRing) continue;
                /* A nested list belongs to the entry above it, not to the
                   ring, so it is left alone. */
                if (node.parentElement && node.parentElement.closest("li")) continue;
                node.querySelectorAll(":scope > li").forEach((item) => {
                    const blip = readBlip(item, quadrant, currentRing, blipIndex);
                    blipIndex += 1;
                    currentRing.count += 1;
                    quadrant.count += 1;
                    blips.push(blip);
                });
            }
        });

        /* Draw the known rings from the middle outwards, and keep anything
           unrecognised after them rather than silently dropping it. */
        rings.sort((a, b) => {
            const ia = RING_ORDER.indexOf(a.slug);
            const ib = RING_ORDER.indexOf(b.slug);
            return (ia < 0 ? RING_ORDER.length : ia) - (ib < 0 ? RING_ORDER.length : ib);
        });

        return { quadrants: quadrants, rings: rings, blips: blips };
    }

    const radar = readRadar();
    if (radar.blips.length === 0 || radar.quadrants.length === 0) return;

    /* ------------------------------------------------------------------ */
    /* Geometry                                                           */
    /* ------------------------------------------------------------------ */

    /* The rings are not equal bands.

       A ring's share of the radius is the average of two claims on it: the
       inner rings are the ones worth looking at first, and a ring has to be
       wide enough for the dots standing in it. Believing only the first
       would grind twenty-six entries into the smallest band on the picture,
       which is where this radar started; believing only the second would
       delete the difference between the rings. The blend keeps both, and
       normalising below means a page with fewer rings still comes out
       right. */
    const RING_WEIGHTS = { adopt: 0.34, trial: 0.26, assess: 0.22, deprecate: 0.18 };

    /** SVG units a dot needs before a neighbour crowds it. */
    const MIN_BLIP_GAP = 30;

    /** Inner and outer radius of each ring, in drawing order. */
    const ringBands = (function () {
        const counted = radar.rings.reduce((sum, ring) => sum + ring.count, 0);
        const weights = radar.rings.map((ring) =>
            ((RING_WEIGHTS[ring.slug] || 1 / radar.rings.length)
             + ring.count / counted) / 2);
        const total = weights.reduce((sum, weight) => sum + weight, 0);
        let inner = 0;
        return weights.map((weight) => {
            const band = { inner: inner, outer: inner + (OUTER_RADIUS * weight) / total };
            inner = band.outer;
            return band;
        });
    })();

    const sectorStep = 360 / radar.quadrants.length;
    const sectorGap = Math.min(SECTOR_GAP_MAX, sectorStep * SECTOR_GAP_SHARE);

    /**
     * Return the point on the radar for an angle measured in degrees
     * clockwise from straight up.
     * @param {number} degrees
     * @param {number} radius
     * @returns {{ x: number, y: number }}
     */
    function pointAt(degrees, radius) {
        const radians = (degrees * Math.PI) / 180;
        return { x: CENTER + radius * Math.sin(radians), y: CENTER - radius * Math.cos(radians) };
    }

    /**
     * Return the path of one ring inside one quadrant: an annular sector.
     * @param {number} startDegrees
     * @param {number} endDegrees
     * @param {number} inner
     * @param {number} outer
     * @returns {string}
     */
    function annularSector(startDegrees, endDegrees, inner, outer) {
        const startOuter = pointAt(startDegrees, outer);
        const endOuter = pointAt(endDegrees, outer);
        const largeArc = endDegrees - startDegrees > 180 ? 1 : 0;
        /* A wedge runs to the middle; an arc of radius zero is not portable,
           so the pie is closed through the centre point explicitly. */
        if (inner <= 0) {
            return [
                "M", startOuter.x, startOuter.y,
                "A", outer, outer, 0, largeArc, 1, endOuter.x, endOuter.y,
                "L", CENTER, CENTER,
                "Z"
            ].join(" ");
        }
        const startInner = pointAt(startDegrees, inner);
        const endInner = pointAt(endDegrees, inner);
        return [
            "M", startOuter.x, startOuter.y,
            "A", outer, outer, 0, largeArc, 1, endOuter.x, endOuter.y,
            "L", endInner.x, endInner.y,
            "A", inner, inner, 0, largeArc, 0, startInner.x, startInner.y,
            "Z"
        ].join(" ");
    }

    /**
     * Work out where every blip sits.
     *
     * The dots are seeded evenly across their wedge and band, then allowed to
     * settle: any pair closer than MIN_BLIP_GAP pushes apart, and every dot is
     * tethered back inside its own ring and quadrant. A dozen technologies in
     * the innermost ring would otherwise collapse into one unreadable knot,
     * because the arc available at that radius is short.
     * @returns {Map<any, { x: number, y: number, radius: number, angle: number }>}
     */
    function layoutBlips() {
        const usableDegrees = sectorStep - sectorGap * 2;
        /** @type {any[]} */
        const dots = [];

        radar.quadrants.forEach((quadrant) => {
            const start = quadrant.index * sectorStep + sectorGap;
            radar.rings.forEach((ring) => {
                const band = ringBands[radar.rings.indexOf(ring)];
                const width = band.outer - band.inner;
                const siblings = radar.blips.filter((other) =>
                    other.ring === ring && other.quadrant === quadrant);
                siblings.forEach((blip, index) => {
                    dots.push({
                        blip: blip,
                        angle: start + (usableDegrees * (index + 0.5)) / siblings.length,
                        /* Stagger the starting radii so the settle has less to do. */
                        radius: band.inner + width * (0.3 + 0.45 * ((index % 3) / 2)),
                        minAngle: start,
                        maxAngle: start + usableDegrees,
                        minRadius: band.inner + width * 0.12,
                        maxRadius: band.outer - width * 0.1,
                        x: 0,
                        y: 0
                    });
                });
            });
        });

        for (let pass = 0; pass < 60; pass += 1) {
            dots.forEach((dot) => {
                const point = pointAt(dot.angle, dot.radius);
                dot.x = point.x;
                dot.y = point.y;
            });
            let close = 0;
            for (let i = 0; i < dots.length; i += 1) {
                for (let j = i + 1; j < dots.length; j += 1) {
                    const a = dots[i];
                    const b = dots[j];
                    let dx = b.x - a.x;
                    let dy = b.y - a.y;
                    let distance = Math.hypot(dx, dy);
                    if (distance >= MIN_BLIP_GAP) continue;
                    if (distance === 0) {
                        dx = 0;
                        dy = 0.01;
                        distance = 0.01;
                    }
                    const push = (MIN_BLIP_GAP - distance) / 2;
                    const ux = dx / distance;
                    const uy = dy / distance;
                    a.x -= ux * push;
                    a.y -= uy * push;
                    b.x += ux * push;
                    b.y += uy * push;
                    close += 1;
                }
            }
            /* The push is free to wander, so every dot is brought back to its
               own slot before it can drift into a neighbour's territory. */
            dots.forEach((dot) => {
                const radius = Math.hypot(dot.x - CENTER, dot.y - CENTER);
                let angle = (Math.atan2(dot.x - CENTER, CENTER - dot.y) * 180) / Math.PI;
                if (angle < 0) angle += 360;
                dot.radius = Math.min(dot.maxRadius, Math.max(dot.minRadius, radius));
                dot.angle = Math.min(dot.maxAngle, Math.max(dot.minAngle, angle));
            });
            if (close === 0) break;
        }

        return new Map(dots.map((dot) => {
            const point = pointAt(dot.angle, dot.radius);
            return [dot.blip, { x: point.x, y: point.y, radius: dot.radius, angle: dot.angle }];
        }));
    }

    const blipPositions = layoutBlips();

    /* ------------------------------------------------------------------ */
    /* Draw                                                               */
    /* ------------------------------------------------------------------ */

    /** @param {string} name @param {object} [attributes] */
    function svgElement(name, attributes) {
        const element = document.createElementNS(SVG_NS, name);
        Object.keys(attributes || {}).forEach((key) => {
            element.setAttribute(key, String(attributes[key]));
        });
        return element;
    }

    const svg = svgElement("svg", {
        viewBox: "0 0 " + SIZE + " " + SIZE,
        class: "jfw-radar-svg",
        role: "img",
        /* The page calls its sectors layers, so the picture does too. */
        "aria-label": "Tech radar: " + radar.blips.length + " technologies across "
            + radar.quadrants.length + " layers and " + radar.rings.length
            + " rings. Each blip is a link to its entry; every layer and ring is"
            + " listed in full below."
    });

    /* Quadrant wedges and their names, drawn underneath everything else. */
    const wedgeLayer = svgElement("g", { class: "jfw-radar-quadrants" });
    radar.quadrants.forEach((quadrant) => {
        const start = quadrant.index * sectorStep + sectorGap;
        const end = (quadrant.index + 1) * sectorStep - sectorGap;
        wedgeLayer.appendChild(svgElement("path", {
            d: annularSector(start, end, 0, OUTER_RADIUS),
            class: "jfw-radar-wedge jfw-radar-wedge-" + (quadrant.index % 4)
        }));
    });

    /* Ring boundaries and the names written along them. */
    const ringLayer = svgElement("g", { class: "jfw-radar-rings" });
    radar.rings.forEach((ring, ringIndex) => {
        const outer = ringBands[ringIndex].outer;
        ringLayer.appendChild(svgElement("circle", {
            cx: CENTER, cy: CENTER, r: outer, class: "jfw-radar-ring-edge"
        }));
        radar.quadrants.forEach((quadrant) => {
            const middle = (ringBands[ringIndex].inner + outer) / 2;
            /* Twelve degrees into the wedge, so the label sits near the gap
               rather than on top of the blips in the middle of the band. */
            const angle = quadrant.index * sectorStep + sectorGap + 12;
            const position = pointAt(angle, middle);
            /* Text is written along the tangent; on the left half of the
               radar that would read upside down, so turn those around. */
            const flip = angle > 90 && angle < 270;
            const label = svgElement("text", {
                x: position.x,
                y: position.y,
                class: "jfw-radar-ring-label",
                "text-anchor": flip ? "end" : "start",
                /* One label per ring carries the ring's name when every blip
                   is named at once; the stylesheet hides the rest, which
                   would otherwise be folded under fifty names. */
                "data-jfw-radar-ring-name": quadrant.index === 0 ? "first" : "repeat",
                transform: "rotate(" + (flip ? angle + 180 : angle) + " " + position.x + " " + position.y + ")"
            });
            label.textContent = ring.label;
            ringLayer.appendChild(label);
        });
    });

    /* Blips, each a real link so keyboard and middle-click work for free. */
    const blipLayer = svgElement("g", { class: "jfw-radar-blips" });
    radar.blips.forEach((blip, position) => {
        const spot = blipPositions.get(blip);
        const itemId = "jfw-radar-item-" + position;
        blip.element.id = itemId;
        const movementClass = blip.movement ? " jfw-radar-moved-" + blip.movement.slug : "";
        const group = svgElement("a", {
            href: "#" + itemId,
            "data-ring-order": String(radar.rings.indexOf(blip.ring)),
            class: "jfw-radar-blip jfw-radar-blip-" + blip.ring.slug
                + " jfw-radar-blip-quadrant-" + (blip.quadrant.index % 4) + movementClass,
            "aria-label": blip.label + " — " + blip.ring.label + " ring, "
                + blip.quadrant.label + (blip.movement ? ", " + blip.movement.hint : "")
        });
        /* A dot nine units across is a hard thing to point at, and the name
           beside it is only there while the pointer is already on the blip.
           This invisible disc is the real target: as wide as the gap the
           layout keeps between two blips, so aiming at a blip works from a
           comfortable distance without stealing its neighbour's clicks. */
        group.appendChild(svgElement("circle", {
            cx: spot.x, cy: spot.y, r: MIN_BLIP_GAP / 2, class: "jfw-radar-hit"
        }));
        group.appendChild(svgElement("circle", {
            cx: spot.x, cy: spot.y, r: 9, class: "jfw-radar-dot"
        }));
        const caption = svgElement("text", {
            x: spot.x, y: spot.y, class: "jfw-radar-blip-label",
            "text-anchor": spot.x >= CENTER ? "start" : "end",
            dx: spot.x >= CENTER ? 14 : -14,
            dy: 4
        });
        caption.textContent = shorten(blip.label, 30);
        group.appendChild(caption);
        blip.spot = spot;
        blip.group = group;
        blipLayer.appendChild(group);
    });

    /* Everything is drawn inside one group so the whole picture can be
       shrunk to make room for the labels, without moving a single blip
       relative to its neighbours. */
    const art = svgElement("g", { class: "jfw-radar-art" });
    art.appendChild(wedgeLayer);
    art.appendChild(ringLayer);
    art.appendChild(blipLayer);
    svg.appendChild(art);

    /**
     * Keep only the labels that fit on the picture.
     *
     * Names are long and the radar is small, so fifty of them at once would
     * be a grey smear. The inner rings win the space they need, and a label
     * that would land on one already kept steps aside: it still appears when
     * its blip is hovered or focused, and it is always in the list below.
     * Measurements are taken in the drawing's own units, so the picture does
     * not have to be re-cluttered when the window changes size.
     */
    function declutterLabels() {
        const labels = Array.from(blipLayer.querySelectorAll(".jfw-radar-blip-label"));
        /* A label that is not rendered has no box, so clear the previous
           verdict before asking for new measurements. */
        labels.forEach((label) => label.classList.remove("jfw-radar-label-cramped"));
        /* The ring names left on the picture are taken ground: a blip name
           lands beside them rather than on top of them. */
        const kept = Array.from(svg.querySelectorAll(".jfw-radar-ring-label"))
            .filter((ringLabel) => getComputedStyle(ringLabel).display !== "none")
            .map((ringLabel) => ringLabel.getBBox())
            /* Generous clearance: a name that merely touches a ring name
               still reads as printed over it. */
            .map((box) => ({ x: box.x - 7, y: box.y - 7, w: box.width + 14, h: box.height + 14 }));
        labels
            .sort((a, b) => Number(a.parentElement.getAttribute("data-ring-order"))
                - Number(b.parentElement.getAttribute("data-ring-order")))
            .forEach((label) => {
                const box = label.getBBox();
                const candidate = {
                    x: box.x - 2, y: box.y - 2, w: box.width + 4, h: box.height + 4
                };
                const collides = kept.some((other) =>
                    candidate.x < other.x + other.w && other.x < candidate.x + candidate.w
                    && candidate.y < other.y + other.h && other.y < candidate.y + candidate.h);
                label.classList.toggle("jfw-radar-label-cramped", collides);
                if (!collides) kept.push(candidate);
            });
    }

    /** How far the drawing pulls back when every label is shown at once. */
    const LABELS_SCALE = 0.82;
    /** Shrink the drawing about its own centre, leaving the frame alone. */
    function scaleArt(on) {
        if (!on) {
            art.removeAttribute("transform");
            return;
        }
        art.setAttribute("transform",
            "translate(" + CENTER + " " + CENTER + ") scale(" + LABELS_SCALE + ") "
            + "translate(" + -CENTER + " " + -CENTER + ")");
    }

    /* A styled tooltip beats the native one: it can carry the note, the ring
       and the movement, and it stays inside the frame near the edges. */
    const tooltip = document.createElement("div");
    tooltip.className = "jfw-radar-tooltip";
    tooltip.setAttribute("role", "status");
    tooltip.hidden = true;

    canvas.appendChild(svg);
    canvas.appendChild(tooltip);

    /**
     * Show the tooltip for a blip, aligned to the blip's on-screen position.
     * @param {any} blip
     */
    function showTooltip(blip) {
        const scale = svg.getBoundingClientRect().width / SIZE;
        tooltip.textContent = "";
        const title = document.createElement("strong");
        title.textContent = blip.label;
        tooltip.appendChild(title);
        const where = document.createElement("span");
        where.className = "jfw-radar-tooltip-where";
        where.textContent = blip.quadrant.label + " · " + blip.ring.label + " ring"
            + (blip.movement ? " · " + blip.movement.hint : "");
        tooltip.appendChild(where);
        if (blip.note) {
            const note = document.createElement("span");
            note.className = "jfw-radar-tooltip-note";
            note.textContent = blip.note;
            tooltip.appendChild(note);
        }
        if (blip.href) {
            const more = document.createElement("span");
            more.className = "jfw-radar-tooltip-more";
            more.textContent = "click to read more";
            tooltip.appendChild(more);
        }
        tooltip.hidden = false;
        /* The tooltip follows the drawing, which shrinks when labels are on. */
        const shrink = container.classList.contains("jfw-radar-labels-on")
            ? LABELS_SCALE : 1;
        const left = (CENTER + (blip.spot.x - CENTER) * shrink) * scale;
        const top = (CENTER + (blip.spot.y - CENTER) * shrink) * scale;
        tooltip.style.left = left + "px";
        tooltip.style.top = top + "px";
        /* Turn the tooltip around when it would hang off an edge. */
        tooltip.classList.toggle("jfw-radar-tooltip-left",
            left > svg.getBoundingClientRect().width * 0.62);
        tooltip.classList.toggle("jfw-radar-tooltip-below",
            top < svg.getBoundingClientRect().height * 0.3);
        /* Turning it around is not always enough on a narrow screen, so the
           box is nudged back inside the frame once its size is known. */
        const frame = canvas.getBoundingClientRect();
        const box = tooltip.getBoundingClientRect();
        if (box.left < frame.left) {
            tooltip.style.left = (left + (frame.left - box.left)) + "px";
        } else if (box.right > frame.right) {
            tooltip.style.left = (left - (box.right - frame.right)) + "px";
        }
    }

    function hideTooltip() {
        tooltip.hidden = true;
    }

    /* ------------------------------------------------------------------ */
    /* The keyboard cursor                                                 */
    /* ------------------------------------------------------------------ */

    /* Which blip a keyboard visitor is standing on.

       Blink raises no focus event for a link inside SVG, and never matches
       :focus or :focus-visible on one, so the focused blip cannot be found,
       styled or described from the focus itself. Tab still reaches every
       blip and Enter still follows it; what the browser withholds is the
       pointer, so the script keeps its own and dresses that. */
    /** @type {any} */
    let cursor = null;

    /**
     * Stand on a blip: mark it, and describe it the way hovering does.
     * @param {any} blip
     */
    function setCursor(blip) {
        const next = blip || null;
        if (cursor === next) {
            if (next) showTooltip(next);
            return;
        }
        if (cursor) cursor.group.classList.remove("jfw-radar-blip-cursor");
        cursor = next;
        if (!cursor) {
            hideTooltip();
            return;
        }
        cursor.group.classList.add("jfw-radar-blip-cursor");
        showTooltip(cursor);
    }

    radar.blips.forEach((blip) => {
        ["pointerenter", "focus"].forEach((event) => {
            blip.group.addEventListener(event, () => showTooltip(blip));
        });
        ["pointerleave", "blur"].forEach((event) => {
            blip.group.addEventListener(event, hideTooltip);
        });
        /* Keep the entry the blip points at visible, as the link itself only
           moves the viewport. */
        blip.group.addEventListener("click", () => {
            /* The catalogue folds away, so the entry a blip points at has to
               be revealed before the jump can land on it. */
            if (blip.quadrant.details) blip.quadrant.details.open = true;
            blip.element.classList.add("jfw-radar-target");
            window.setTimeout(() => blip.element.classList.remove("jfw-radar-target"), 2400);
        });
        /* Walking the picture with the arrow keys beats tabbing through fifty
           links to reach the blip next door. */
        blip.group.addEventListener("keydown", (event) => {
            const directions = {
                ArrowUp: [0, -1], ArrowDown: [0, 1], ArrowLeft: [-1, 0], ArrowRight: [1, 0]
            };
            const direction = directions[event.key];
            if (!direction) return;
            event.preventDefault();
            focusNeighbour(blip, direction[0], direction[1]);
        });
        /* Hovering an entry in the catalogue names and lights its blip, so the
           two halves of the page answer to each other in both directions. */
        ["pointerenter", "focusin"].forEach((event) => {
            blip.element.addEventListener(event, () => {
                blip.group.classList.add("jfw-radar-blip-lit");
            });
        });
        ["pointerleave", "focusout"].forEach((event) => {
            blip.element.addEventListener(event, () => {
                blip.group.classList.remove("jfw-radar-blip-lit");
            });
        });
    });

    /**
     * Move focus to the nearest blip in one direction from another.
     *
     * Straight ahead counts for little and sideways drift counts for a lot, so
     * walking right lands on the blip that is right, not on the one that
     * happens to be closest but sits two rings further out.
     * @param {any} from
     * @param {number} dx
     * @param {number} dy
     */
    function focusNeighbour(from, dx, dy) {
        let best = null;
        let bestScore = Infinity;
        radar.blips.forEach((other) => {
            if (other === from) return;
            const vx = other.spot.x - from.spot.x;
            const vy = other.spot.y - from.spot.y;
            const forward = vx * dx + vy * dy;
            if (forward <= 1) return;
            const sideways = Math.abs(vx * -dy + vy * dx);
            const score = forward + sideways * 2;
            if (score < bestScore) {
                bestScore = score;
                best = other;
            }
        });
        if (!best) return;
        best.group.focus();
        setCursor(best);
    }

    /* ------------------------------------------------------------------ */
    /* Legend, and isolating one ring or quadrant                          */
    /* ------------------------------------------------------------------ */

    /** @type {any} */
    let isolation = null;

    /**
     * Dim everything that the visitor has not asked to see.
     * @param {"ring" | "quadrant" | null} kind
     * @param {any} value
     */
    function setIsolation(kind, value) {
        isolation = kind ? { kind: kind, value: value } : null;
        radar.blips.forEach((blip) => {
            const match = !isolation
                || (isolation.kind === "ring" && blip.ring === isolation.value)
                || (isolation.kind === "quadrant" && blip.quadrant === isolation.value);
            blip.group.classList.toggle("jfw-radar-dimmed", !match);
            /* The catalogue below is the same radar in another shape, so it
               dims the same way rather than leaving the reader to reconcile
               two disagreeing views. */
            blip.element.classList.toggle("jfw-radar-entry-muted", !match);
        });
        /* Isolating a layer in the picture opens that layer's catalogue, as
           the entries it highlights are otherwise folded away. */
        if (isolation && isolation.kind === "quadrant" && value.details) {
            value.details.open = true;
        }
        container.querySelectorAll("[data-jfw-radar-filter]").forEach((button) => {
            const on = isolation
                && isolation.kind === button.getAttribute("data-jfw-radar-filter-kind")
                && isolation.value.label === button.getAttribute("data-jfw-radar-filter-label");
            button.setAttribute("aria-pressed", on ? "true" : "false");
        });
    }

    /**
     * Fill a legend list with one toggle button per entry.
     * @param {Element | null} list
     * @param {"ring" | "quadrant"} kind
     * @param {any[]} entries
     */
    function fillLegend(list, kind, entries) {
        if (!list) return;
        entries.forEach((entry) => {
            const item = document.createElement("li");
            const button = document.createElement("button");
            button.type = "button";
            button.className = "jfw-radar-legend-button jfw-radar-" + kind + "-" + entry.slug;
            button.setAttribute("data-jfw-radar-filter", "true");
            button.setAttribute("data-jfw-radar-filter-kind", kind);
            button.setAttribute("data-jfw-radar-filter-label", entry.label);
            button.setAttribute("aria-pressed", "false");
            const name = document.createElement("span");
            name.textContent = entry.label;
            const count = document.createElement("span");
            count.className = "jfw-radar-legend-count";
            count.textContent = String(entry.count);
            button.appendChild(name);
            button.appendChild(count);
            button.addEventListener("click", () => {
                const on = isolation && isolation.kind === kind && isolation.value === entry;
                setIsolation(on ? null : kind, entry);
            });
            item.appendChild(button);
            list.appendChild(item);
        });
    }

    fillLegend(legend, "ring", radar.rings);
    fillLegend(quadrantLegend, "quadrant", radar.quadrants);

    /* ------------------------------------------------------------------ */
    /* Fold the catalogue away                                             */
    /* ------------------------------------------------------------------ */

    /**
     * Put one layer's entries behind a summary.
     *
     * The page should open on the radar, not on six screens of lists, but the
     * entries are what the blips point at and what a reader without
     * JavaScript gets in full. So the folding happens here, at run time: the
     * markup keeps every entry, this script only hides them behind a control
     * that opens on demand.
     * @param {any} quadrant
     */
    function foldCatalogue(quadrant) {
        const section = quadrant.section;
        const heading = section.querySelector("h2");
        if (!heading) return;
        const details = document.createElement("details");
        details.className = "jfw-radar-catalogue";
        const summary = document.createElement("summary");
        summary.className = "jfw-radar-catalogue-summary";
        /* The heading itself moves into the summary, so the layer keeps its
           own place in the document outline while being the control that
           opens it. */
        summary.appendChild(heading);
        const count = document.createElement("span");
        count.className = "jfw-radar-catalogue-count";
        count.textContent = quadrant.count + (quadrant.count === 1 ? " entry" : " entries");
        summary.appendChild(count);
        details.appendChild(summary);
        Array.from(section.childNodes).forEach((node) => details.appendChild(node));
        section.appendChild(details);
        quadrant.details = details;
    }

    radar.quadrants.forEach(foldCatalogue);

    if (labelsButton) {
        labelsButton.addEventListener("click", () => {
            /* The state hangs off the whole radar, not just the drawing, so
               the stylesheet can give the labels the full width of the page
               and drop the legend underneath them. */
            const on = !container.classList.contains("jfw-radar-labels-on");
            container.classList.toggle("jfw-radar-labels-on", on);
            scaleArt(on);
            /* Hovering a blip names it whether or not the labels are on, so
               the verdict only stands while they are shown. */
            if (on) declutterLabels();
            else blipLayer.querySelectorAll(".jfw-radar-label-cramped")
                .forEach((label) => label.classList.remove("jfw-radar-label-cramped"));
            labelsButton.setAttribute("aria-pressed", on ? "true" : "false");
            labelsButton.textContent = on ? "hide labels" : "show labels";
        });
    }

    /* Escape clears whatever the visitor was looking at. */
    container.addEventListener("keydown", (event) => {
        if (event.key === "Escape") setIsolation(null, null);
    });

    /* A tab that arrives from somewhere else on the page is heard on the
       document, not on the blip it lands on, and the cursor is read from
       where the tab actually ended up. Tabbing out of the picture, into the
       legend or on down the page, puts the cursor away again. */
    document.addEventListener("keydown", (event) => {
        if (event.key !== "Tab") return;
        window.setTimeout(() => {
            setCursor(radar.blips.find((blip) => blip.group === document.activeElement));
        }, 0);
    });

    container.setAttribute("data-jfw-radar-ready", "true");
    if (prefersReducedMotion) container.classList.add("jfw-radar-reduced-motion");
})();
