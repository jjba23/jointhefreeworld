;;; jfw-radar.el --- draw the tech radar while the page is published  -*- lexical-binding: t -*-

;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; This file is part of jointhefreeworld, free software under the GNU
;; Affero General Public License v3 or newer.  See COPYING.

;;; Commentary:

;; The tech radar used to be drawn by a browser script that read the article
;; out of the DOM and laid the picture out at run time.  It is now drawn
;; here, while the page is exported, from the very same Org source.  Three
;; things follow from that move, and all three are why it was made:
;;
;; - The picture is part of the page a reader receives.  It needs no script,
;;   no download and no layout shift, and a reader who blocks JavaScript
;;   still sees the radar.
;; - The article stays the only source of truth.  The rings are the sections
;;   that ask for `jfw-radar-ring' containers, the layers are the headings
;;   inside them, and the blips are their list items; nothing here knows the
;;   name of a single technology.
;; - The geometry is testable.  Bands, wedges, settling and labelling are
;;   ordinary functions with ordinary answers, so ERT can state what the
;;   picture must satisfy instead of a browser having to look at it.
;;
;; A page asks for the radar with
;;
;;   #+begin_radar
;;   #+end_radar
;;
;; and `jfw/org-html-special-block' writes the drawing and its legend there.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'org-element)
(require 'jfw-core)
(require 'jfw-pages)

;;; ---------------------------------------------------------------------
;;; The drawing's constants
;;; ---------------------------------------------------------------------
;; These are the numbers the JavaScript renderer used, kept because the
;; picture they describe is the one the site already showed.  Each is named
;; for the thing it decides rather than for its value.

(defconst jfw/radar-size 1000
  "Side of the drawing's own coordinate system, in SVG units.")

(defconst jfw/radar-center 500
  "The centre of the drawing, in SVG units.")

(defconst jfw/radar-outer-radius 450
  "Radius of the outermost ring, in SVG units.
The remaining fifty units on each side leave room for the labels that
stick out past the last ring.")

(defconst jfw/radar-sector-gap-share 0.06
  "Share of a layer's sector left empty on either side.
A share rather than a fixed angle, so a page cutting four layers and a
page cutting six both get even gaps.")

(defconst jfw/radar-sector-gap-max 5
  "The widest a gap between two layers may grow, in degrees.")

(defconst jfw/radar-ring-order '("adopt" "trial" "assess" "deprecate")
  "Rings from the middle outwards, whatever order the article lists them in.")

(defconst jfw/radar-ring-weights
  '(("adopt" . 0.34) ("trial" . 0.26) ("assess" . 0.22) ("deprecate" . 0.18))
  "How much of the radius each known ring would like.
The band a ring actually gets is the average of this claim and its share
of the entries, so a ring with many entries is wide enough to hold them
without erasing the difference between the rings.")

(defconst jfw/radar-min-blip-gap 30
  "SVG units two blips keep between them before a neighbour crowds them.")

(defconst jfw/radar-movements
  '(("new" . "new since the last revision")
    ("moved in" . "closer to the middle than before")
    ("moved out" . "further from the middle than before")
    ("no change" . "unchanged since the last revision"))
  "How a movement note is spelled in the article, and what it means.")

(defconst jfw/radar-ring-class "jfw-radar-ring"
  "The container class that marks a section as one of the radar's rings.")

;;; ---------------------------------------------------------------------
;;; Reading the article
;;; ---------------------------------------------------------------------

(defun jfw/radar--heading-text (headline)
  "Return HEADLINE's own words, without the emoji or glyphs it opens with.
The article decorates its headings (\"✅ Adopt\", \"🧬 Languages\") for the
reader's eye; the picture wants the word alone."
  (let ((title (string-trim
                (replace-regexp-in-string "[[:space:]]+" " "
                                          (org-element-interpret-data
                                           (org-element-property :title headline))))))
    (substring-no-properties
     (string-trim (replace-regexp-in-string "\\`[^[:alnum:]]+" "" title)))))

(defun jfw/radar--slug (label)
  "Return a stable key for LABEL: \"Adopt\" becomes \"adopt\".
It is used to match a heading against the known rings and to hang CSS off
the picture, so it must survive a change of decoration but not a change
of name."
  (string-trim
   (replace-regexp-in-string "[^a-z0-9]+" "-" (downcase label))
   "-" "-"))

(defun jfw/radar--join (pieces)
  "Join PIECES into one line, keeping the space the source had between them.
Org hands back the text around a link in pieces that carry no space of
their own, so \"[[url][Guile Scheme]] and Lisps\" arrives as two pieces
that would be written as \"Guile Schemeand Lisps\" by a plain concat.
A space is added between two pieces that would otherwise run together,
but never before punctuation, which attaches to the word before it."
  (let ((line ""))
    (dolist (piece pieces)
      (cond
       ((string-empty-p piece))
       ((string-empty-p line) (setq line piece))
       ((or (string-match-p "[[:space:]]\\'" line)
            (string-match-p "\\`[[:space:]]" piece)
            ;; Punctuation closes the word before it rather than opening one.
            (string-match-p "\\`[],.;:!?)]" piece))
        (setq line (concat line piece)))
       (t (setq line (concat line " " piece)))))
    line))

(defun jfw/radar--text (node)
  "Return NODE as plain text, with links reduced to their description."
  (cond
   ((stringp node) (substring-no-properties node))
   ((null node) "")
   ((not (consp node)) "")
   ;; A secondary string is a list of objects rather than an element.
   ((not (symbolp (car node))) (jfw/radar--join (mapcar #'jfw/radar--text node)))
   ((eq (car node) 'link)
    ;; A bracket link keeps its description in its contents; only an
    ;; explicit =:description= property overrides what the reader sees.
    (let ((description (or (org-element-property :description node)
                           (org-element-contents node))))
      (if description
          (jfw/radar--text description)
        (or (org-element-property :raw-link node) ""))))
   ((eq (car node) 'entity)
    (or (org-element-property :utf-8 node) ""))
   ((eq (car node) 'line-break) " ")
   (t (jfw/radar--join (mapcar #'jfw/radar--text (org-element-contents node))))))

(defun jfw/radar--children (node type)
  "Return the direct children of NODE whose element type is TYPE."
  (cl-remove-if-not (lambda (child) (eq (car-safe child) type))
                    (org-element-contents node)))

(defun jfw/radar--section (headline)
  "Return HEADLINE's section element, which holds everything before its
first sub-heading."
  (car (jfw/radar--children headline 'section)))

(defun jfw/radar--layers (ring)
  "Return the layer headlines directly inside RING."
  (jfw/radar--children ring 'headline))

(defun jfw/radar--lists (headline)
  "Return the lists directly inside HEADLINE, in the order they appear.
A list nested inside an item belongs to that entry rather than to the
layer, so it is left out here."
  (when-let* ((section (jfw/radar--section headline)))
    (jfw/radar--children section 'plain-list)))

(defun jfw/radar--items (list)
  "Return the items of LIST."
  (jfw/radar--children list 'item))

(defun jfw/radar--first-link (item)
  "Return the target of the first link inside ITEM, or nil."
  (when-let* ((link (org-element-map item 'link #'identity nil t)))
    (or (org-element-property :raw-link link)
        (org-element-property :path link))))

(defun jfw/radar--blip (item layer ring anchor index)
  "Describe ITEM as a blip in LAYER and RING.
ANCHOR is the fragment its heading answers at, and INDEX is its place in
the article.  A trailing note after an em dash is kept apart, because the
picture writes the short name beside the dot and the note in the tooltip.

The answer is a plist with the keys `:label', `:note', `:movement',
`:href', `:layer', `:ring', `:anchor', `:index' and the drawing's own
`:x', `:y' and `:label-p' initialized here: `plist-put' mutates a key
that already exists, which is what lets the settle pass move a blip
without anything having to map positions back to it."
  (let* ((raw (string-trim (replace-regexp-in-string "[[:space:]]+" " "
                                                     (jfw/radar--text item))))
         (dash (string-match "—" raw))
         (label (string-trim (if dash (substring raw 0 dash) raw)))
         (note (and dash (string-trim (substring raw (1+ dash)))))
         (note (and note (not (string-empty-p note)) note))
         (movement-name
          (when (string-match "\\(?:([ \t]*\\(new\\|moved in\\|moved out\\|no change\\)[ \t]*)\\)[ \t]*\\'"
                              label)
            (match-string 1 label)))
         (movement (and movement-name
                        (cdr (assoc (downcase movement-name) jfw/radar-movements)))))
    (when movement-name
      (setq label (string-trim (substring label 0 (match-beginning 0)))))
    (list :label label :note note
          :movement movement
          :movement-label movement-name
          :href (jfw/radar--first-link item)
          :layer layer :ring ring :anchor anchor :index index
          :x 0.0 :y 0.0 :label-p nil)))

(defun jfw/radar--read-rings (tree)
  "Return the radar described by TREE, the parsed Org document.
The answer is a plist with `:rings', `:layers' and `:blips'.  A ring is a
section that asks for a `jfw-radar-ring' container, a layer is a heading
inside one, and a blip is a list item under a layer.  A layer appears in
several rings, so the first mention creates it and the rest are matched
by name, which is also what fixes the order of the wedges."
  (let ((rings '()) (layers '()) (blips '()) (index 0))
    (dolist (ring (org-element-map tree 'headline #'identity))
      (when (equal jfw/radar-ring-class
                   (org-element-property :HTML_CONTAINER_CLASS ring))
        (let ((label (jfw/radar--heading-text ring)))
          (unless (string-empty-p label)
            (let ((ring-entry (list :label label
                                    :slug (jfw/radar--slug label)
                                    :anchor (or (org-element-property :CUSTOM_ID ring)
                                                (jfw/radar--slug label))
                                    :count 0 :index 0)))
              (setq rings (append rings (list ring-entry)))
              (dolist (layer-headline (jfw/radar--layers ring))
                (let ((layer-label (jfw/radar--heading-text layer-headline)))
                  (unless (string-empty-p layer-label)
                    (let* ((layer-slug (jfw/radar--slug layer-label))
                           (anchor (or (org-element-property :CUSTOM_ID layer-headline)
                                       layer-slug))
                           (layer-entry
                            (or (cl-find layer-slug layers
                                         :test #'equal
                                         :key (lambda (entry) (plist-get entry :slug)))
                                (let ((new (list :label layer-label
                                                 :slug layer-slug
                                                 :index (length layers)
                                                 :anchor anchor
                                                 :count 0)))
                                  (setq layers (append layers (list new)))
                                  new))))
                      (dolist (list (jfw/radar--lists layer-headline))
                        (dolist (item (jfw/radar--items list))
                          (let ((blip (jfw/radar--blip item layer-entry
                                                       ring-entry anchor index)))
                            (unless (string-empty-p (plist-get blip :label))
                              (setq index (1+ index))
                              (setq blips (append blips (list blip)))
                              (plist-put layer-entry :count
                                         (1+ (plist-get layer-entry :count)))
                              (plist-put ring-entry :count
                                         (1+ (plist-get ring-entry :count))))))))))))))))
    (list :rings rings :layers layers :blips blips)))

(defun jfw/radar-data (&optional file)
  "Return the radar described by FILE, or nil when it describes none.
FILE defaults to the radar article.  A page without rings, layers or
blips gets nil rather than an empty picture."
  (let* ((file (or file (expand-file-name
                         "docs/blog/articles/development/tech-radar.org"
                         jfw/project-root)))
         (data (when (and file (file-exists-p file))
                 (with-temp-buffer
                   (insert-file-contents file)
                   (org-mode)
                   (jfw/radar--read-rings (org-element-parse-buffer))))))
    (when (and data
               (plist-get data :rings)
               (plist-get data :layers)
               (plist-get data :blips))
      (jfw/radar--order-rings data))))

(defun jfw/radar--rank (ring)
  "Return RING's place in `jfw/radar-ring-order', or the end of it."
  (or (cl-position (plist-get ring :slug) jfw/radar-ring-order :test #'equal)
      (length jfw/radar-ring-order)))

(defun jfw/radar--order-rings (data)
  "Return DATA with its rings drawn from the middle outwards.
An unknown ring keeps its place after the known ones rather than being
dropped, and the order is stable so two builds of the same article are
the same picture."
  (let ((rings (cl-stable-sort (copy-sequence (plist-get data :rings))
                               (lambda (a b) (< (jfw/radar--rank a)
                                                (jfw/radar--rank b))))))
    (cl-loop for ring in rings for index from 0
             do (plist-put ring :index index))
    (plist-put (copy-sequence data) :rings rings)))

;;; ---------------------------------------------------------------------
;;; Geometry
;;; ---------------------------------------------------------------------

(defun jfw/radar--bands (rings)
  "Return the (INNER . OUTER) radius of each ring, in drawing order.
The bands tile the outer radius without gaps, and the last one ends
exactly on it."
  (let* ((total (max 1 (cl-reduce #'+ rings :key (lambda (ring)
                                                   (plist-get ring :count)))))
         (weights (mapcar (lambda (ring)
                            (/ (+ (or (cdr (assoc (plist-get ring :slug)
                                                  jfw/radar-ring-weights))
                                     (/ 1.0 (length rings)))
                                  (/ (float (plist-get ring :count)) total))
                               2.0))
                          rings))
         (sum (cl-reduce #'+ weights))
         (inner 0.0)
         (bands '()))
    (dolist (weight weights)
      (let ((outer (+ inner (* jfw/radar-outer-radius (/ weight sum)))))
        (push (cons inner outer) bands)
        (setq inner outer)))
    (nreverse bands)))

(defun jfw/radar--point (degrees radius)
  "Return the point at DEGREES clockwise from straight up, at RADIUS.
The answer is (X . Y) in the drawing's own coordinates."
  (let ((radians (* degrees (/ (float float-pi) 180.0))))
    (cons (+ jfw/radar-center (* radius (sin radians)))
          (- jfw/radar-center (* radius (cos radians))))))

(defun jfw/radar--number (value)
  "Return VALUE formatted for an SVG attribute."
  (format "%.2f" (float value)))

(defun jfw/radar--sector (start end inner outer)
  "Return the path of an annular sector from START to END degrees.
A wedge that reaches the middle is closed through the centre point
explicitly, because an arc of radius zero is not portable."
  (let* ((start-outer (jfw/radar--point start outer))
         (end-outer (jfw/radar--point end outer))
         (large (if (> (- end start) 180) 1 0)))
    (if (<= inner 0)
        (format "M %s %s A %s %s 0 %d 1 %s %s L %s %s Z"
                (jfw/radar--number (car start-outer))
                (jfw/radar--number (cdr start-outer))
                (jfw/radar--number outer) (jfw/radar--number outer)
                large
                (jfw/radar--number (car end-outer))
                (jfw/radar--number (cdr end-outer))
                (jfw/radar--number jfw/radar-center)
                (jfw/radar--number jfw/radar-center))
      (let ((start-inner (jfw/radar--point start inner))
            (end-inner (jfw/radar--point end inner)))
        (format "M %s %s A %s %s 0 %d 1 %s %s L %s %s A %s %s 0 %d 0 %s %s Z"
                (jfw/radar--number (car start-outer))
                (jfw/radar--number (cdr start-outer))
                (jfw/radar--number outer) (jfw/radar--number outer) large
                (jfw/radar--number (car end-outer))
                (jfw/radar--number (cdr end-outer))
                (jfw/radar--number (car end-inner))
                (jfw/radar--number (cdr end-inner))
                (jfw/radar--number inner) (jfw/radar--number inner) large
                (jfw/radar--number (car start-inner))
                (jfw/radar--number (cdr start-inner)))))))

(defun jfw/radar--step (layers)
  "Return the angular width of one layer's sector, in degrees."
  (/ 360.0 (max 1 (length layers))))

(defun jfw/radar--gap (layers)
  "Return the gap left on either side of a layer, in degrees."
  (min jfw/radar-sector-gap-max
       (* (jfw/radar--step layers) jfw/radar-sector-gap-share)))

;;; ---------------------------------------------------------------------
;;; Settling the blips
;;; ---------------------------------------------------------------------
;; Twelve technologies in the innermost ring would otherwise collapse into
;; one unreadable knot: the arc available at that radius is short.  The dots
;; are seeded evenly across their wedge and band, then allowed to settle
;; until no pair is closer than `jfw/radar-min-blip-gap', with every dot
;; tethered back inside its own ring and layer.

(defun jfw/radar--raw-dots (rings bands layers blips)
  "Return the dots to settle, one per blip, seeded across its own slot."
  (let* ((step (jfw/radar--step layers))
         (gap (jfw/radar--gap layers))
         (usable (- step (* gap 2)))
         (dots '()))
    (dolist (layer layers)
      (let ((start (+ (* (plist-get layer :index) step) gap)))
        (cl-loop for ring in rings
                 for band in bands
                 do (let* ((width (- (cdr band) (car band)))
                           (siblings (cl-remove-if-not
                                      (lambda (blip)
                                        ;; Matched by name rather than by
                                        ;; identity: two parses of the same
                                        ;; article describe the same ring.
                                        (and (equal (plist-get (plist-get blip :ring) :slug)
                                                    (plist-get ring :slug))
                                             (equal (plist-get (plist-get blip :layer) :slug)
                                                    (plist-get layer :slug))))
                                      blips)))
                      (cl-loop for blip in siblings
                               for index from 0
                               do (push (list :blip blip
                                              :angle (+ start
                                                        (/ (* usable (+ index 0.5))
                                                           (length siblings)))
                                              :radius (+ (car band)
                                                         (* width
                                                            (+ 0.3 (* 0.45 (/ (mod index 3) 2.0)))))
                                              :min-angle start
                                              :max-angle (+ start usable)
                                              :min-radius (+ (car band) (* width 0.12))
                                              :max-radius (- (cdr band) (* width 0.10))
                                              :x 0.0 :y 0.0)
                                        dots))))))
    (nreverse dots)))

(defun jfw/radar--settle (dots)
  "Return DOTS after they have pushed each other apart.
Each pass moves every pair closer than the minimum gap away from each
other, then brings every dot back inside its own wedge and band.  A pass
that finds no close pair ends the settling early."
  (let ((dots (vconcat dots))
        (gap (float jfw/radar-min-blip-gap)))
    (dotimes (_ 60)
      (let ((close 0))
        ;; Measure each dot at its current angle and radius.
        (dotimes (i (length dots))
          (let* ((dot (aref dots i))
                 (point (jfw/radar--point (plist-get dot :angle)
                                          (plist-get dot :radius))))
            (plist-put dot :x (car point))
            (plist-put dot :y (cdr point))))
        (dotimes (i (length dots))
          (cl-loop for j from (1+ i) below (length dots)
                   do (let* ((a (aref dots i))
                             (b (aref dots j))
                             (dx (- (plist-get b :x) (plist-get a :x)))
                             (dy (- (plist-get b :y) (plist-get a :y)))
                             (distance (sqrt (+ (* dx dx) (* dy dy)))))
                        (when (< distance gap)
                          (when (= distance 0)
                            (setq dx 0.0 dy 0.01 distance 0.01))
                          (let* ((push (/ (- gap distance) 2.0))
                                 (ux (/ dx distance))
                                 (uy (/ dy distance)))
                            (plist-put a :x (- (plist-get a :x) (* ux push)))
                            (plist-put a :y (- (plist-get a :y) (* uy push)))
                            (plist-put b :x (+ (plist-get b :x) (* ux push)))
                            (plist-put b :y (+ (plist-get b :y) (* uy push)))
                            (setq close (1+ close)))))))
        ;; The push is free to wander, so every dot is brought back to its
        ;; own slot before it can drift into a neighbour's territory.
        (dotimes (i (length dots))
          (let* ((dot (aref dots i))
                 (dx (- (plist-get dot :x) jfw/radar-center))
                 (dy (- jfw/radar-center (plist-get dot :y)))
                 (radius (sqrt (+ (* dx dx) (* dy dy))))
                 (angle (* (/ (atan dx dy) (float float-pi)) 180.0)))
            (when (< angle 0) (setq angle (+ angle 360.0)))
            (plist-put dot :radius (min (plist-get dot :max-radius)
                                        (max (plist-get dot :min-radius) radius)))
            (plist-put dot :angle (min (plist-get dot :max-angle)
                                       (max (plist-get dot :min-angle) angle)))))
        (when (= close 0) (cl-return))))
    ;; Whatever ended the settling, every dot now has an angle and a radius
    ;; inside its own slot, and that is where its blip is drawn.  Writing
    ;; them back once, after the passes, means a blip is never left at the
    ;; origin because the first pass found nothing to push.
    (dotimes (i (length dots))
      (let* ((dot (aref dots i))
             (point (jfw/radar--point (plist-get dot :angle)
                                      (plist-get dot :radius)))
             (blip (plist-get dot :blip)))
        (plist-put blip :x (car point))
        (plist-put blip :y (cdr point))
        (plist-put blip :radius (plist-get dot :radius))
        (plist-put blip :angle (plist-get dot :angle))))
    dots))

(defun jfw/radar--place (data)
  "Return DATA's blips after they have been placed on the picture.
Seeding and settling are one step from the caller's side: a blip nobody
has placed has no coordinates of its own, and drawing it at the origin
would put it outside every ring."
  (let ((rings (plist-get data :rings))
        (layers (plist-get data :layers)))
    (jfw/radar--settle (jfw/radar--raw-dots rings (jfw/radar--bands rings)
                                          layers (plist-get data :blips)))
    (plist-get data :blips)))

;;; ---------------------------------------------------------------------
;;; Labels
;;; ---------------------------------------------------------------------

(defun jfw/radar--shorten (text limit)
  "Return TEXT shortened to LIMIT characters at a word boundary."
  (if (<= (length text) limit)
      text
    (let* ((cut (substring text 0 limit))
           (space (cl-position ?\s cut :from-end t)))
      (concat (string-trim (if (and space (> space (/ limit 2.0)))
                               (substring cut 0 space)
                             cut))
              "…"))))

(defun jfw/radar--boxes-overlap-p (a b)
  "Return non-nil when box A and box B intersect.
A box is (X Y WIDTH HEIGHT) in the drawing's coordinates."
  (and (< (nth 0 a) (+ (nth 0 b) (nth 2 b)))
       (< (nth 0 b) (+ (nth 0 a) (nth 2 a)))
       (< (nth 1 a) (+ (nth 1 b) (nth 3 b)))
       (< (nth 1 b) (+ (nth 1 a) (nth 3 a)))))

(defun jfw/radar--text-box (x y width height anchor-left clear)
  "Return the box of a text at (X . Y), WIDTH by HEIGHT.
When ANCHOR-LEFT is nil the text grows to the left of X.  CLEAR is the
white space kept around it, which is what makes a name that merely
touches another still read as printed over it."
  (list (- (if anchor-left x (- x width)) clear)
        (- y (* height 0.8) clear)
        (+ width (* 2 clear))
        (+ height (* 1.6 clear))))

(defun jfw/radar--ring-label-positions (rings bands layers)
  "Return one (RING LAYER ANGLE X Y FLIP) per ring name on the picture."
  (let ((step (jfw/radar--step layers))
        (gap (jfw/radar--gap layers))
        (positions '()))
    (cl-loop for ring in rings
             for band in bands
             do (dolist (layer layers)
                  (let ((angle (+ (* (plist-get layer :index) step) gap 12)))
                    (push (list ring layer angle
                                (car (jfw/radar--point angle (/ (+ (car band) (cdr band)) 2)))
                                (cdr (jfw/radar--point angle (/ (+ (car band) (cdr band)) 2)))
                                (and (> angle 90) (< angle 270)))
                          positions))))
    (nreverse positions)))

(defun jfw/radar--declutter (rings bands layers blips)
  "Decide which blip names fit on the picture, and mark them.
A name that would land on one already kept steps aside; it is still in
the tooltip, still a link, and still in the list below the drawing.  The
inner rings are heard first, because those are the entries a reader looks
for first."
  (let ((taken '()))
    ;; The ring names are written by the drawing itself, so they are ground
    ;; the blip names have to give way to.
    (dolist (position (jfw/radar--ring-label-positions rings bands layers))
      (let* ((ring (nth 0 position))
             (x (nth 3 position))
             (y (nth 4 position))
             (flip (nth 5 position))
             (width (* (length (plist-get ring :label)) 12.0)))
        (push (jfw/radar--text-box x y width 20 (not flip) 7) taken)))
    (dolist (blip (cl-stable-sort (copy-sequence blips)
                                  (lambda (a b)
                                    (let ((ra (plist-get a :ring))
                                          (rb (plist-get b :ring)))
                                      (if (= (plist-get ra :index) (plist-get rb :index))
                                          (< (plist-get a :index) (plist-get b :index))
                                        (< (plist-get ra :index) (plist-get rb :index)))))))
      (let* ((x (plist-get blip :x))
             (y (plist-get blip :y))
             (left (>= x jfw/radar-center))
             (text (jfw/radar--shorten (plist-get blip :label) 30))
             (width (* (length text) 7.6))
             (box (jfw/radar--text-box (+ x (if left 14 -14)) (+ y 4)
                                       width 15 left 2)))
        (unless (cl-some (lambda (other) (jfw/radar--boxes-overlap-p box other))
                         taken)
          (plist-put blip :label-p t)
          (push box taken))))
    blips))

;;; ---------------------------------------------------------------------
;;; Writing the SVG
;;; ---------------------------------------------------------------------

(defun jfw/radar--title (blip)
  "Return the accessible name of BLIP, as an SVG title element."
  (format "<title>%s</title>"
          (jfw/escape-html
           (concat (plist-get blip :label)
                   " — " (plist-get (plist-get blip :ring) :label) " ring, "
                   (plist-get (plist-get blip :layer) :label)
                   (when (plist-get blip :movement)
                     (concat ", " (plist-get blip :movement)))
                   (when (plist-get blip :note)
                     (concat ". " (plist-get blip :note)))))))

(defun jfw/radar--blip-svg (blip)
  "Return BLIP as an SVG group: a hit target, a dot and a name."
  (let* ((x (plist-get blip :x))
         (y (plist-get blip :y))
         (left (>= x jfw/radar-center))
         (dot-x (jfw/radar--number x))
         (dot-y (jfw/radar--number y))
         (ring-slug (plist-get (plist-get blip :ring) :slug))
         (layer-index (plist-get (plist-get blip :layer) :index))
         (movement (plist-get blip :movement-label))
         (classes (concat "jfw-radar-blip jfw-radar-blip-" ring-slug
                          " jfw-radar-blip-quadrant-" (number-to-string (mod layer-index 4))
                          (when movement
                            (concat " jfw-radar-moved-"
                                    (cdr (assoc (downcase movement)
                                                '(("new" . "new")
                                                  ("moved in" . "in")
                                                  ("moved out" . "out")
                                                  ("no change" . "same")))))))))
    (concat
     (format "<a href=\"#%s\" class=\"%s\" aria-label=\"%s\">"
             (jfw/escape-html (plist-get blip :anchor))
             classes
             (jfw/escape-html (concat (plist-get blip :label) " — "
                                      (plist-get (plist-get blip :ring) :label)
                                      " ring, "
                                      (plist-get (plist-get blip :layer) :label))))
     (jfw/radar--title blip)
     (format "<circle cx=\"%s\" cy=\"%s\" r=\"%s\" class=\"jfw-radar-hit\"/>"
             dot-x dot-y (jfw/radar--number (/ jfw/radar-min-blip-gap 2.0)))
     (format "<circle cx=\"%s\" cy=\"%s\" r=\"9\" class=\"jfw-radar-dot\"/>"
             dot-x dot-y)
     ;; Every name is in the drawing. The ones that would land on a name
     ;; already kept are marked, and the stylesheet keeps them quiet until
     ;; their blip is pointed at or focused, so the picture at rest is
     ;; readable and the name is still there to be asked for.
     (format (concat "<text x=\"%s\" y=\"%s\" class=\"jfw-radar-blip-label%s\""
                     " text-anchor=\"%s\" dx=\"%s\" dy=\"4\">%s</text>")
             dot-x dot-y (if (plist-get blip :label-p) "" " is-cramped")
             (if left "start" "end")
             (if left "14" "-14")
             (jfw/escape-html (jfw/radar--shorten (plist-get blip :label) 30)))
     "</a>")))

(defun jfw/radar--svg (rings bands layers blips)
  "Return the radar as a standalone SVG element."
  (let* ((step (jfw/radar--step layers))
         (gap (jfw/radar--gap layers))
         (total (length blips)))
    (concat
     (format (concat "<svg xmlns=\"http://www.w3.org/2000/svg\""
                     " viewBox=\"0 0 %d %d\" class=\"jfw-radar-svg\""
                     " role=\"img\" aria-label=\"%s\">")
             jfw/radar-size jfw/radar-size
             (jfw/escape-html
              (format "Tech radar: %d technologies across %d layers and %d rings. Every blip is a link to its entry; every layer and ring is listed in full below."
                      total (length layers) (length rings))))
     "<g class=\"jfw-radar-art\">"
     ;; The layers are the wedges, drawn under everything else.
     "<g class=\"jfw-radar-quadrants\">"
     (mapconcat (lambda (layer)
                  (format "<path d=\"%s\" class=\"jfw-radar-wedge jfw-radar-wedge-%d\"/>"
                          (jfw/radar--sector (+ (* (plist-get layer :index) step) gap)
                                             (- (* (1+ (plist-get layer :index)) step) gap)
                                             0 jfw/radar-outer-radius)
                          (mod (plist-get layer :index) 4)))
                layers "")
     "</g>"
     ;; Ring boundaries, and the ring's name written in each wedge.
     "<g class=\"jfw-radar-rings\">"
     (mapconcat (lambda (band)
                  (format "<circle cx=\"%s\" cy=\"%s\" r=\"%s\" class=\"jfw-radar-ring-edge\"/>"
                          (jfw/radar--number jfw/radar-center)
                          (jfw/radar--number jfw/radar-center)
                          (jfw/radar--number (cdr band))))
                bands "")
     (mapconcat (lambda (position)
                  (let* ((ring (nth 0 position))
                         (angle (nth 2 position))
                         (x (nth 3 position))
                         (y (nth 4 position))
                         (flip (nth 5 position)))
                    (format (concat "<text x=\"%s\" y=\"%s\" class=\"jfw-radar-ring-label\""
                                    " text-anchor=\"%s\" data-jfw-radar-ring-name=\"%s\""
                                    " transform=\"rotate(%s %s %s)\">%s</text>")
                            (jfw/radar--number x) (jfw/radar--number y)
                            (if flip "end" "start")
                            (if (= 0 (plist-get (nth 1 position) :index)) "first" "repeat")
                            (jfw/radar--number (if flip (+ angle 180) angle))
                            (jfw/radar--number x) (jfw/radar--number y)
                            (jfw/escape-html (plist-get ring :label)))))
                (jfw/radar--ring-label-positions rings bands layers))
     "</g>"
     "<g class=\"jfw-radar-blips\">"
     (mapconcat #'jfw/radar--blip-svg blips "")
     "</g></g></svg>")))

;;; ---------------------------------------------------------------------
;;; The page fragment
;;; ---------------------------------------------------------------------

(defun jfw/radar--legend (kind entries)
  "Return a legend list of ENTRIES, each a link to its own entry.
KIND is \"ring\" or \"layer\" and only picks the class, which is what
tints the swatch beside the name."
  (format "<ul class=\"jfw-radar-legend jfw-radar-legend-%ss\">%s</ul>"
          kind
          (mapconcat
           (lambda (entry)
             (format (concat "<li><a class=\"jfw-radar-legend-button jfw-radar-%s-%s\""
                             " href=\"#%s\"><span>%s</span>"
                             "<span class=\"jfw-radar-legend-count\">%d</span></a></li>")
                     kind (plist-get entry :slug)
                     (jfw/escape-html (or (plist-get entry :anchor)
                                          (plist-get entry :slug)))
                     (jfw/escape-html (plist-get entry :label))
                     (plist-get entry :count)))
           entries "")))

(defun jfw/radar-html (&optional info)
  "Return the radar for the page being exported, as an HTML fragment.
INFO is the exporter's communication channel, whose `:input-file' is the
article that describes the radar.  A page without one gets an empty
string, so a stray block cannot break the build."
  (let* ((data (jfw/radar-data (plist-get info :input-file)))
         (rings (plist-get data :rings))
         (layers (plist-get data :layers))
         (placed (when data (jfw/radar--place data)))
         (blips (and placed (jfw/radar--declutter rings (jfw/radar--bands rings)
                                                layers placed))))
    (if (not data)
        ;; A page without a radar answers with nothing, so a stray block
        ;; cannot break the build and never writes the word "nil".
        ""
      (concat
       "<div class=\"jfw-radar\">"
       "<div class=\"jfw-radar-canvas\">"
       (jfw/radar--svg rings (jfw/radar--bands rings) layers blips)
       "</div>"
       "<div class=\"jfw-radar-panel\">"
       "<p class=\"jfw-radar-panel-title\">Rings</p>"
       (jfw/radar--legend "ring" rings)
       "<p class=\"jfw-radar-panel-title\">Layers</p>"
       (jfw/radar--legend "layer" layers)
       "<p class=\"jfw-radar-hint\">Each blip links to the entry it stands for;"
       " the full catalogue is below, under the rings it belongs to.</p>"
       "</div></div>"))))

(provide 'jfw-radar)

;;; jfw-radar.el ends here
