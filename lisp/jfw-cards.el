;;; jfw-cards.el --- jointhefreeworld build  -*- lexical-binding: t -*-

;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:

;; Part of the site build.  The entry point is ./jointhefreeworld-site.el,
;; which installs the packages and requires this file after them; nothing
;; here is meant to be loaded on its own.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'jfw-core)
(require 'jfw-pages)



;;; ---------------------------------------------------------------------
;;; Social cards
;;; ---------------------------------------------------------------------
;; A shared link should say what it is about before anybody clicks it.
;; Every blog article therefore gets a card of its own, composed from its
;; own title and its own category while the site is exported, and
;; rasterised, because the social platforms do not render SVG.

(defconst jfw/og-cards-directory "og"
  "Directory below ./public holding the generated social cards.
It is deliberately not ./public/static, which the build owns as a copy
of ./static and would overwrite.")

(defconst jfw/og-rasterizer "rsvg-convert"
  "Program that turns a card's SVG into the PNG the platforms fetch.
It comes from librsvg, which manifest.scm provides.  When it is absent
the build says so once and the articles keep the site-wide card, so a
checkout without the tool still publishes a site with no broken image.")

(defconst jfw/og-card-font-family
  "'DejaVu Sans', 'Bitstream Vera Sans', 'Liberation Sans', sans-serif"
  "Family stack of the cards, all of them freely available.
The text is rasterised by whoever runs the build, so a proprietary face
would make the card depend on what happens to be installed there.")

(defconst jfw/og-card-mono-family
  "'DejaVu Sans Mono', 'Bitstream Vera Sans Mono', monospace"
  "Monospaced stack, used for the parenthesis ornament.")

(defconst jfw/og-card-colours
  '(("background" . "#0e0a09")
    ("glow" . "#d4914e")
    ("frame" . "#3a2a20")
    ("ink" . "#f2e8de")
    ("accent" . "#d4914e")
    ("faded" . "#b39c86"))
  "Card palette, shared with the stylesheet's design tokens.
An alist of names to colours, because the SVG builder reads them by name
and a typo in a colour should be a missing value rather than a silence.")

(defconst jfw/og-card-text-width 880
  "Widest a title line may be, in pixels, on a 1200 pixel card.")

(defconst jfw/og-card-title-sizes '(62 54 46 40 34)
  "Title sizes to try, largest first, until the title fits its lines.
A title too long for the largest size steps down rather than shrinking
past legibility, which is what a card in a timeline needs.")

(defconst jfw/og-card-title-band '(240 . 520)
  "Vertical band the title is centred in, between its label and the footer.
A title is centred rather than dropped from a fixed baseline so that one
line and four lines both look deliberate on the card.")

(defconst jfw/og-card-footer-rule-y 520
  "Y of the rule above the footer, anchored near the frame's bottom edge.")

(defconst jfw/og-card-footer-baseline 568
  "Baseline of the footer line, shared by every card.")

(defconst jfw/og-card-title-lines '(3 4 5 6 6)
  "How many lines each size in `jfw/og-card-title-sizes' may use.
The budget is vertical as well as horizontal: a line is 1.14 sizes tall
and the block is centred on a band of about three hundred pixels, so
three lines at the largest size leave air above and below, while four
lines at that size would touch the label and the footer rule.")

(defconst jfw/og-card-escapes
  '((?& . "&amp;") (?< . "&lt;") (?> . "&gt;") (?\" . "&quot;") (?\' . "&apos;"))
  "Characters that must not reach the SVG as themselves.")

(defun jfw/og-card-colour (name)
  "Return the card colour called NAME."
  (or (cdr (assoc name jfw/og-card-colours))
      (error "no such card colour: %s" name)))

(defun jfw/og-card-escape (text)
  "Return TEXT with the characters XML reserves replaced by entities."
  (replace-regexp-in-string
   "[&<>\"']"
   (lambda (match) (cdr (assq (string-to-char match) jfw/og-card-escapes)))
   text t t))

(defun jfw/og-card-text (text)
  "Return TEXT as a card can draw it.
HTML is stripped, pictographs are dropped, and runs of whitespace are
collapsed.  A card is rasterised with freely available fonts, and those
do not carry the emoji an Org title is allowed to use; a drawn box would
be worse than a missing glyph."
  (let ((text (jfw/plain-text (or text ""))))
    (setq text (replace-regexp-in-string
                "[\u2190-\u2BFF\U0001F000-\U0001FAFF]" "" text t))
    (string-trim (replace-regexp-in-string "[[:space:]]+" " " text))))

(defconst jfw/og-card-glyph-widths
  ;; DejaVu Sans Bold advances, in units of 1/1000 em: printable ASCII
  ;; first (32..126), then Latin-1 (160..255).  They come from the font
  ;; that manifest.scm installs, which is the face the rasteriser draws
  ;; the cards with.  Emacs cannot measure text from a batch build, and an
  ;; average glyph width guessed generously enough to be safe made the
  ;; wrapping ragged, while one guessed tightly let cards overflow their
  ;; own frame, so the metrics travel with the build script instead.
  [    348  456  521  838  696 1002  872  306  457  457  523  838  380  415  380  365
    696  696  696  696  696  696  696  696  696  696  400  400  838  838  838  580
   1000  774  762  734  830  683  683  821  837  372  372  775  637  995  837  850
    733  850  770  720  682  812  774 1103  771  724  725  457  365  457  838  500
    500  675  716  593  716  678  435  716  712  343  343  665  343 1042  712  687
    716  716  493  595  478  712  652  924  645  652  582  712  365  712  838  348
    456  696  696  636  696  365  500  500 1000  564  646  838  415 1000  500  500
    838  438  438  500  736  636  380  500  438  564  646 1035 1035 1035  580  774
    774  774  774  774  774 1085  734  683  683  683  683  372  372  372  372  838
    837  850  850  850  850  850  838  850  812  812  812  812  724  738  719  675
    675  675  675  675  675 1048  593  678  678  678  678  343  343  343  343  687
    712  687  687  687  687  687  838  687  712  712  712  712  652  716  652]
  "Advances of the card's title face, in units of 1/1000 em.")

(defconst jfw/og-card-fallback-width 620
  "Advance assumed for a character the width table does not cover.")

(defun jfw/og-card-char-width (char)
  "Return the advance of CHAR in the card's title face, in 1/1000 em."
  (cond
   ((and (>= char 32) (<= char 126))
    (aref jfw/og-card-glyph-widths (- char 32)))
   ((and (>= char 160) (<= char 255))
    (aref jfw/og-card-glyph-widths (+ 95 (- char 160))))
   (t jfw/og-card-fallback-width)))

(defun jfw/og-card-estimate (text size)
  "Return the width in pixels of TEXT set at SIZE in the title face.
The sum of the declared advances, so a line is measured the way the
rasteriser will draw it rather than estimated from a guess."
  (let ((units (apply #'+ 0 (mapcar #'jfw/og-card-char-width
                                    (string-to-list text)))))
    (/ (* (float units) size) 1000.0)))

(defun jfw/og-card-wrap (text size width)
  "Return TEXT as a list of lines no wider than WIDTH at SIZE.
A single word too long for WIDTH keeps a line to itself."
  (let ((lines '())
        (line ""))
    (dolist (word (split-string text "[ \t\n]+" t))
      (let ((candidate (if (string-empty-p line) word (concat line " " word))))
        (if (or (string-empty-p line) (<= (jfw/og-card-estimate candidate size) width))
            (setq line candidate)
          (push line lines)
          (setq line word))))
    (unless (string-empty-p line)
      (push line lines))
    (nreverse lines)))

(defun jfw/og-card-break-sets (from up-to count)
  "Return every sorted list of COUNT break positions in [FROM, UP-TO).
A break position i means \"start a new line after word i\", so a title of
n words has n-1 gaps and a list of COUNT of them is COUNT+1 lines."
  (cond
   ((zerop count) (list nil))
   ((> count (- up-to from)) nil)
   (t (cl-loop for position from from to (- up-to count)
               append (mapcar (lambda (rest) (cons position rest))
                              (jfw/og-card-break-sets (1+ position) up-to (1- count)))))))

(defun jfw/og-card-ranges (breaks word-count)
  "Return the (FROM . TO) word ranges that BREAKS divide WORD-COUNT words into."
  (let ((ranges '())
        (start 0))
    (dolist (break breaks)
      (push (cons start (1+ break)) ranges)
      (setq start (1+ break)))
    (push (cons start word-count) ranges)
    (nreverse ranges)))

(defun jfw/og-card-balance (text size limit)
  "Return TEXT at SIZE wrapped into balanced lines, or nil when it will not fit.
Balanced is decided by search rather than by a greedy pass: the splits
that fit the card are all measured, and the one whose lines differ least
in width wins, with the fewest lines preferred.  Greedy wrapping fills
the first lines to the brim and leaves a stub at the end, which on a card
with room for three lines is what makes a title look like a mistake."
  (let* ((words (split-string text "[ \t\n]+" t))
         (n (length words))
         (space (jfw/og-card-estimate " " size))
         (widths (mapcar (lambda (word) (jfw/og-card-estimate word size)) words)))
    (cl-block balanced
      ;; Fewest lines wins, so the counts are tried in order and the first
      ;; one that fits anything is the one whose candidates are compared.
      (cl-loop for count from 0 below (min limit n)
               do (let ((candidates
                         (cl-loop for breaks in (jfw/og-card-break-sets 0 (1- n) count)
                                  for ranges = (jfw/og-card-ranges breaks n)
                                  for widths-of-lines
                                  = (mapcar (lambda (range)
                                              (+ (cl-reduce #'+ (cl-subseq widths (car range) (cdr range)))
                                                 (* space (- (cdr range) (car range) 1))))
                                            ranges)
                                  when (cl-every (lambda (width)
                                                   (<= width jfw/og-card-text-width))
                                                 widths-of-lines)
                                  collect (let ((mean (/ (cl-reduce #'+ widths-of-lines)
                                                         (float (length widths-of-lines)))))
                                            (cons (cl-reduce #'+ (mapcar (lambda (width)
                                                                           (expt (- width mean) 2))
                                                                         widths-of-lines))
                                                  (mapcar (lambda (range)
                                                            (mapconcat #'identity
                                                                       (cl-subseq words (car range) (cdr range))
                                                                       " "))
                                                          ranges))))))
                    (when candidates
                      (cl-return-from balanced
                        (cdr (car (sort candidates (lambda (a b) (< (car a) (car b)))))))))))))

(defun jfw/og-card-title-layout (title)
  "Return (SIZE . LINES) laying TITLE out on a card.
The largest size whose allowed number of lines is enough wins.  A title
that no size can hold keeps the smallest size and says so with an
ellipsis rather than shrinking past legibility."
  (let ((sizes jfw/og-card-title-sizes)
        (limits jfw/og-card-title-lines)
        layout)
    (while (and sizes (not layout))
      (let* ((size (car sizes))
             (strict (jfw/og-card-wrap title size jfw/og-card-text-width))
             (lines (when (<= (length strict) (car limits))
                      (or (jfw/og-card-balance title size (car limits)) strict))))
        (if lines
            (setq layout (cons size lines))
          (setq sizes (cdr sizes)
                limits (cdr limits)))))
    (or layout
        (let* ((size (car (last jfw/og-card-title-sizes)))
               (lines (jfw/og-card-wrap title size jfw/og-card-text-width))
               (kept (cl-subseq lines 0 (car (last jfw/og-card-title-lines)))))
          (setcar (last kept)
                  (concat (string-trim-right (car (last kept)) "[.,;:] ") "…"))
          (cons size kept)))))

(defun jfw/og-card-title-svg (layout)
  "Return the title's SVG lines for LAYOUT, a (SIZE . LINES) pair.
The block is centred on `jfw/og-card-title-band'.  A line whose measured
width would reach past the text width is clamped with `textLength', which
can only happen for a word the wrap could not break."
  (let* ((size (car layout))
         (lines (cdr layout))
         (line-height (round (* size 1.14)))
         ;; Centre the whole block on the band, using a rough ascender and
         ;; descender: what a reader sees is the ink, not the baselines.
         (centre (/ (+ (car jfw/og-card-title-band) (cdr jfw/og-card-title-band)) 2.0))
         (first-baseline
          (round (- centre (/ (- (* (1- (length lines)) line-height)
                                 (* 0.53 size))
                              2.0)))))
    (cl-loop for line in lines
             for index from 0
             concat
             (let ((width (jfw/og-card-estimate line size))
                   (y (+ first-baseline (* index line-height))))
               (format "  <text class=\"title\" x=\"90\" y=\"%d\"%s>%s</text>\n"
                       y
                       (if (> width jfw/og-card-text-width)
                           (format " textLength=\"%d\" lengthAdjust=\"spacingAndGlyphs\""
                                   jfw/og-card-text-width)
                         "")
                       (jfw/og-card-escape line))))))

(defun jfw/og-card-svg (title label)
  "Return the SVG source of the card for TITLE in LABEL.
TITLE is the article's title and LABEL the category it belongs to: the
label is what makes two cards about the same subject distinguishable at
a glance in a timeline."
  (let* ((title (jfw/og-card-text title))
         (label (upcase (jfw/og-card-text label)))
         (layout (jfw/og-card-title-layout title))
         (title-svg (jfw/og-card-title-svg layout))
         (aria (format "jointhefreeworld.org — %s, in %s" title (jfw/og-card-text label))))
    (concat
     "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1200\" height=\"630\" "
     "viewBox=\"0 0 1200 630\" role=\"img\" aria-label=\"" (jfw/og-card-escape aria) "\">\n"
     "  <title>" (jfw/og-card-escape title) "</title>\n"
     "  <desc>" (jfw/og-card-escape (format "%s, in the %s section of jointhefreeworld.org" title label)) "</desc>\n"
     "  <defs>\n"
     "    <radialGradient id=\"glow\" cx=\"0.84\" cy=\"0.16\" r=\"0.75\">\n"
     "      <stop offset=\"0\" stop-color=\"" (jfw/og-card-colour "glow") "\" stop-opacity=\"0.34\"/>\n"
     "      <stop offset=\"0.5\" stop-color=\"#8a5a3c\" stop-opacity=\"0.12\"/>\n"
     "      <stop offset=\"1\" stop-color=\"" (jfw/og-card-colour "background") "\" stop-opacity=\"0\"/>\n"
     "    </radialGradient>\n"
     "    <linearGradient id=\"rule\" x1=\"0\" y1=\"0\" x2=\"1\" y2=\"0\">\n"
     "      <stop offset=\"0\" stop-color=\"" (jfw/og-card-colour "accent") "\"/>\n"
     "      <stop offset=\"1\" stop-color=\"" (jfw/og-card-colour "accent") "\" stop-opacity=\"0\"/>\n"
     "    </linearGradient>\n"
     "    <style>\n"
     "      .eyebrow { font: 700 24px " jfw/og-card-font-family "; letter-spacing: 5px; fill: " (jfw/og-card-colour "faded") "; }\n"
     "      .label { font: 700 30px " jfw/og-card-font-family "; letter-spacing: 6px; fill: " (jfw/og-card-colour "accent") "; }\n"
     "      .title { font: 700 " (number-to-string (car layout)) "px " jfw/og-card-font-family "; fill: " (jfw/og-card-colour "ink") "; }\n"
     "      .foot { font: 400 25px " jfw/og-card-font-family "; fill: " (jfw/og-card-colour "faded") "; }\n"
     "      .lisp { font: 400 30px " jfw/og-card-mono-family "; fill: \"#c9a884\"; }\n"
     "    </style>\n"
     "  </defs>\n"
     "\n"
     "  <rect width=\"1200\" height=\"630\" fill=\"" (jfw/og-card-colour "background") "\"/>\n"
     "  <rect width=\"1200\" height=\"630\" fill=\"url(#glow)\"/>\n"
     "  <rect x=\"24\" y=\"24\" width=\"1152\" height=\"582\" rx=\"20\" fill=\"none\" stroke=\""
     (jfw/og-card-colour "frame") "\" stroke-width=\"2\"/>\n"
     "\n"
     "  <g fill=\"none\" stroke=\"" (jfw/og-card-colour "accent")
     "\" stroke-opacity=\"0.5\" stroke-width=\"8\" stroke-linecap=\"round\">\n"
     "    <path d=\"M 1046 178 C 984 246 984 384 1046 452\"/>\n"
     "    <path d=\"M 1120 178 C 1182 246 1182 384 1120 452\"/>\n"
     "  </g>\n"
     "  <text class=\"lisp\" x=\"1083\" y=\"330\" text-anchor=\"middle\" transform=\"rotate(90 1083 330)\" opacity=\"0.8\">(λ (free world))</text>\n"
     "\n"
     "  <text class=\"eyebrow\" x=\"90\" y=\"134\">JOINTHEFREEWORLD.ORG</text>\n"
     "  <text class=\"label\" x=\"90\" y=\"196\">" (jfw/og-card-escape label) "</text>\n"
     "  <rect x=\"90\" y=\"222\" width=\"240\" height=\"5\" rx=\"2.5\" fill=\"url(#rule)\"/>\n"
     "\n"
     title-svg
     "\n"
     "  <rect x=\"90\" y=\"" (number-to-string jfw/og-card-footer-rule-y)
     "\" width=\"420\" height=\"5\" rx=\"2.5\" fill=\"url(#rule)\"/>\n"
     "  <text class=\"foot\" x=\"90\" y=\"" (number-to-string jfw/og-card-footer-baseline)
     "\">Josep Bigorra (jjba23) · MIT License</text>\n"
     "</svg>\n")))

(defun jfw/og-card-file (path extension)
  "Return the absolute file name of the card for PATH with EXTENSION.
The path of a card mirrors the address of its article: the category
becomes a directory and the file name becomes the card's name, so a card
is where a reader would look for it."
  (when-let* ((parts (jfw/og-card-parts path)))
    (expand-file-name (concat jfw/og-cards-directory "/" (car parts) "/" (cdr parts) "." extension)
                      (expand-file-name "public/" jfw/project-root))))

(defun jfw/og-card-parts (path)
  "Return (CATEGORY . SLUG) for the article at PATH, or nil.
Only blog articles get a card of their own; every other page keeps the
site-wide card, which is a fair description of a landing or index page."
  (when (jfw/article-path-p path)
    (let ((parts (split-string (string-trim path "/" "/") "/" t)))
      (when (and (nth 2 parts) (nth 3 parts))
        (cons (nth 2 parts) (nth 3 parts))))))

(defun jfw/og-card-url (path)
  "Return the site-relative URL of the card of the article at PATH."
  (when-let* ((parts (jfw/og-card-parts path)))
    (concat "/" jfw/og-cards-directory "/" (car parts) "/" (cdr parts) ".png")))

(defun jfw/og-card-write (file content)
  "Write CONTENT to FILE, and return non-nil when the file changed.
Rewriting an identical file would leave the PNG looking older than its
source for no reason, and would rasterise the same card again on every
build.  The comparison is the cache."
  (let* ((coding-system-for-read 'utf-8)
         (existing (when (file-exists-p file)
                     (with-temp-buffer (insert-file-contents file) (buffer-string)))))
    (unless (equal existing content)
      (make-directory (file-name-directory file) t)
      (let ((coding-system-for-write 'utf-8))
        (with-temp-file file (insert content)))
      t)))

(defvar jfw/og-card-rasterizer-cache 'unknown
  "Memoised answer to \"which program rasterises the cards?\".
The answer cannot change during a build, and looking it up once keeps a
build with sixty-nine articles to sixty-nine file tests.")

(defun jfw/og-card-rasterizer-program ()
  "Return the card rasteriser's executable, or nil when it is absent."
  (when (eq jfw/og-card-rasterizer-cache 'unknown)
    (setq jfw/og-card-rasterizer-cache
          (or (executable-find jfw/og-rasterizer) 'missing)))
  (unless (eq jfw/og-card-rasterizer-cache 'missing)
    jfw/og-card-rasterizer-cache))

(defvar jfw/og-cards-rasterised 0)
(defvar jfw/og-cards-up-to-date 0)
(defvar jfw/og-cards-without-rasterizer 0)

(defun jfw/og-card-rasterize (svg png)
  "Render the SVG at SVG into the PNG at PNG, and return non-nil on success.
The rasteriser's own complaints are captured rather than left to pollute
the build log, and a failure is reported once per card with the article's
name, because a card that quietly does not exist is a card that quietly
does not work."
  (when-let* ((program (jfw/og-card-rasterizer-program)))
    (let ((log (generate-new-buffer " *jfw rsvg-convert*")))
      (unwind-protect
          (let ((status (call-process program nil log nil
                                      "--format" "png"
                                      "--width" "1200"
                                      "--height" "630"
                                      "--output" png svg)))
            (if (and (numberp status) (zerop status) (file-exists-p png))
                (progn (cl-incf jfw/og-cards-rasterised) t)
              (message "social card: %s could not rasterise %s: %s"
                       program (file-name-nondirectory svg)
                       (string-trim (with-current-buffer log (buffer-string))))
              nil))
        (kill-buffer log)))))

(defun jfw/og-card (path title &optional label)
  "Generate the social card of the page at PATH and return its URL.
TITLE is the page's title and LABEL the category or ring it belongs to.
The card is written below ./public when its content changed, and a
rasteriser turns it into the PNG that platforms fetch.

Two situations return nil, and both leave the page with the site-wide
card rather than pointing a crawler at a file that is not there: a page
that is not an article, and an article whose PNG could not be produced."
  (when-let* ((svg (jfw/og-card-file path "svg"))
              (png (jfw/og-card-file path "png"))
              (url (jfw/og-card-url path)))
    (let ((changed (jfw/og-card-write
                    svg (jfw/og-card-svg title (or label (jfw/section-label path) "journal")))))
      (cond
       ;; The card's own drawing is the cache: an article whose title and
       ;; category did not change keeps the PNG an earlier build drew.
       ((and (not changed) (file-exists-p png) (not (file-newer-than-file-p svg png)))
        (cl-incf jfw/og-cards-up-to-date)
        url)
       ((jfw/og-card-rasterize svg png) url)
       (t
        ;; Either the rasteriser is missing or it failed on this card, and
        ;; in both cases the page is better off with the site-wide card
        ;; than with a link to a file that is not there.
        (cl-incf jfw/og-cards-without-rasterizer)
        nil)))))

(defun jfw/report-og-cards ()
  "Report how the cards fared, once, at the end of a build."
  (message "social cards: %d rasterised, %d already current%s"
           jfw/og-cards-rasterised
           jfw/og-cards-up-to-date
           (if (> jfw/og-cards-without-rasterizer 0)
               (format ", %d left to the site-wide card because %s is not installed"
                       jfw/og-cards-without-rasterizer jfw/og-rasterizer)
             ".")))

(provide 'jfw-cards)

;;; lisp/jfw-cards.el ends here
