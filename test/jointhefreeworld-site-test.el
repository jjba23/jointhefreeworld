;;; jointhefreeworld-site-test.el --- ERT tests for the build  -*- lexical-binding: t -*-

;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; jointhefreeworld is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; jointhefreeworld is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public License
;; along with jointhefreeworld.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Tests for jointhefreeworld-site.el, the program that publishes this site.
;;
;; They test the build script itself rather than a copy of its rules: the
;; file under test is loaded, and every expectation below is stated against
;; the very functions that write the site.  A rule that changes shape in the
;; build therefore fails here rather than in a browser.
;;
;; What is covered:
;;
;; - The URL layout, which is the one thing every canonical link, social
;;   card and feed entry depends on.
;; - The navigation marker, the text helpers and the date readers.
;; - The blog listings, including that they escape what they are given.
;; - The social cards' layout arithmetic and the well-formedness of their
;;   SVG.
;; - The structured data, the theme colours and the per-page script list.
;; - The tech radar article's outline, which is the radar's own data.
;; - A smoke test of the page template, so that a broken s-expression in the
;;   document chrome is a failing test instead of a blank page.
;;
;; Run them with `maak test', or directly:
;;
;;   emacs -Q --batch -l test/jointhefreeworld-site-test.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; The build script installs its own Emacs packages into ./.packages on
;; first load, so a machine that has never built the site needs a network
;; connection once, exactly as it would to publish.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'org-element)
(require 'ox-html)

(defconst jfw-test/root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "The repository root, resolved from this file's own location.
Nothing else in these tests assumes a working directory, so the suite can
be run from anywhere.")

;; The file under test is loaded, not copied: what follows is stated against
;; the very functions that publish the site.
(require 'jointhefreeworld-site (expand-file-name "jointhefreeworld-site.el" jfw-test/root))

(defun jfw-test/any-article-path ()
  "Return the site path of some blog article, whichever the build finds.
Tests that need an article's address ask the build for one rather than
naming an article, so deleting or renaming a post cannot break them."
  (or (plist-get (car (jfw/blog-articles)) :url)
      (error "the build found no blog articles at all")))

(defmacro jfw-test/with-temp-org (contents &rest body)
  "Write CONTENTS to a temporary Org file, then evaluate BODY with it.
The file name is bound to `file' for BODY to use, and the file is removed
afterwards whether BODY succeeded or not."
  (declare (indent 1) (debug t))
  `(let ((file (make-temp-file "jfw-test" nil ".org")))
     (unwind-protect
         (progn (with-temp-file file (insert ,contents))
                (let ((file file))
                  ,@body))
       (delete-file file))))

(defun jfw-test/info (&optional file date)
  "Return an export communication plist for FILE, with an optional DATE.
This is the part of the exporter's own plist that the page template reads:
the source file a page came from, which is what decides its address, the
date, which the exporter hands over as a secondary string holding a
timestamp, and the cache the exporter itself would have built."
  (let ((info (list :input-file (expand-file-name (or file "docs/home/index.org")
                                                  jfw-test/root)
                    ;; `org-export-data' reads this cache, so a plist without
                    ;; it is not a plist the exporter could have produced.
                    :exported-data (make-hash-table :test #'equal))))
    (if date
        (append info
                (list :date (list (org-element-create
                                   'timestamp
                                   (list :year-start (string-to-number (substring date 0 4))
                                         :month-start (string-to-number (substring date 5 7))
                                         :day-start (string-to-number (substring date 8 10))
                                         :type 'active)))))
      info)))

(defun jfw-test/heading-html (level text id)
  "Return an exported heading, as the build writes it, with its anchor.
The identifier lives on the anchor link beside the heading text, which is
the shape the rail has to read."
  (format (concat "<h%d>%s&nbsp;<a id=\"%s\" class=\"anchor\""
                  " href=\"#%s\" aria-label=\"Link to this section\">#</a></h%d>")
          level text id id level))

;;; ---------------------------------------------------------------------
;;; The URL layout
;;; ---------------------------------------------------------------------
;; Every canonical link, every social card and every feed entry is built
;; from these answers, so they are the tests worth having first.

(ert-deftest jfw-test/file-page-path-follows-the-publish-table ()
  "A project's published address matches where its directory is written."
  (let ((cases '(("docs/home/index.org" . "/")
                 ("docs/home/404.org" . "/404.html")
                 ("docs/blog/index.org" . "/blog/")
                 ("docs/blog/articles/emacs/index.org" . "/blog/articles/emacs/")
                 ("docs/blog/articles/emacs/emacs-registers.org"
                  . "/blog/articles/emacs/emacs-registers/")
                 ("docs/documentation/index.org" . "/documentation/")
                 ("docs/portfolio/index.org" . "/portfolio/")
                 ;; The policies publish at the top level on purpose.
                 ("docs/policies/code-of-conduct.org" . "/code-of-conduct/")
                 ("docs/policies/ai-policy.org" . "/ai-policy/"))))
    (dolist (case cases)
      (should (equal (jfw/file-page-path (expand-file-name (car case) jfw-test/root))
                     (cdr case))))))

(ert-deftest jfw-test/file-page-path-lowercases-the-file-name ()
  "The case chosen for a file name never reaches the address bar."
  (should (equal (jfw/file-page-path
                  (expand-file-name "docs/blog/articles/emacs/Emacs-Registers.org"
                                    jfw-test/root))
                 "/blog/articles/emacs/emacs-registers/")))

(ert-deftest jfw-test/article-path-p-distinguishes-articles-from-indexes ()
  "Only a single article's address counts as an article."
  (should (jfw/article-path-p "/blog/articles/emacs/emacs-registers/"))
  (should-not (jfw/article-path-p "/blog/"))
  (should-not (jfw/article-path-p "/blog/articles/emacs/"))
  (should-not (jfw/article-path-p "/code-of-conduct/")))

(ert-deftest jfw-test/section-slug-and-label ()
  "A blog category is spelled the way its directory is, and labelled the way
the site labels it."
  (should (equal (jfw/section-slug "/blog/articles/gnu-linux/some-post/") "gnu-linux"))
  (should (equal (jfw/section-label "/blog/articles/gnu-linux/some-post/") "GNU/Linux"))
  (should (equal (jfw/section-label "/blog/articles/ci/some-post/") "CI/CD"))
  ;; A category nobody has named falls back to its own words.
  (should (equal (jfw/section-label "/blog/articles/some-new-thing/post/")
                 "Some New Thing"))
  (should-not (jfw/section-slug "/blog/")))

;;; ---------------------------------------------------------------------
;;; The navigation
;;; ---------------------------------------------------------------------

(ert-deftest jfw-test/nav-current-picks-the-deepest-entry ()
  "An article marks its own section, not the whole of /blog/."
  (should (equal (jfw/nav-current "/") "/"))
  (should (equal (jfw/nav-current "/blog/") "/blog/"))
  (should (equal (jfw/nav-current "/blog/articles/emacs/emacs-registers/") "/blog/"))
  (should (equal (jfw/nav-current "/blog/articles/development/tech-radar/")
                 "/blog/articles/development/tech-radar/"))
  ;; A page no entry covers leaves the bar unmarked.
  (should-not (jfw/nav-current "/portfolio/"))
  (should-not (jfw/nav-current nil)))

(ert-deftest jfw-test/nav-items-marks-the-current-page ()
  "The current entry is announced with aria-current rather than by colour."
  (let* ((items (jfw/nav-items "/blog/"))
         (attribute (lambda (item name) (cadr (assq name (cadr item)))))
         (marked (cl-remove-if-not
                  (lambda (item) (equal (funcall attribute item 'aria-current) "page"))
                  items)))
    (should (= (length items) (length jfw/nav-links)))
    (should (= (length marked) 1))
    (should (equal (funcall attribute (car marked) 'href) "/blog/"))))

(ert-deftest jfw-test/nav-groups-put-every-link-in-exactly-one-place ()
  "A link is on the bar or behind `more', never in both and never lost."
  (let* ((groups (jfw/nav-groups))
         (primary (car groups))
         (secondary (cdr groups))
         (all (append primary secondary)))
    (should (= (length all) (length jfw/nav-links)))
    (should (= (length (delete-dups (copy-sequence all))) (length jfw/nav-links)))
    ;; The bar keeps the places a reader goes next, and the menu keeps the
    ;; ones they go once.
    (dolist (link primary)
      (should (member (car link) jfw/nav-primary-paths)))
    (dolist (link secondary)
      (should-not (member (car link) jfw/nav-primary-paths)))
    ;; Both groups are still in the order the table gives them.
    (should (equal primary
                   (cl-remove-if-not (lambda (link)
                                       (member (car link) jfw/nav-primary-paths))
                                     jfw/nav-links)))))

(ert-deftest jfw-test/page-kicker-names-the-part-of-the-site ()
  "The line above a title is the site's word for the section, not the
directory's."
  (should (equal (jfw/page-kicker "/") "jointhefreeworld"))
  (should (equal (jfw/page-kicker "/blog/") "Blog"))
  (should (equal (jfw/page-kicker "/blog/articles/emacs/") "Emacs"))
  (should (equal (jfw/page-kicker "/blog/articles/emacs/emacs-registers/") "Emacs"))
  (should (equal (jfw/page-kicker "/documentation/") "Docs"))
  (should (equal (jfw/page-kicker "/joe-cv/") "CV"))
  (should (equal (jfw/page-kicker "/code-of-conduct/") "Code of Conduct"))
  ;; The not-found page publishes as a file rather than a directory, and is
  ;; named for what it is rather than for its name.
  (should (equal (jfw/page-kicker "/404.html") "Nothing here")))

(ert-deftest jfw-test/page-meta-drops-what-a-page-does-not-have ()
  "A page with neither a date nor a reading time gets no line at all."
  (should-not (jfw/page-meta))
  (should-not (jfw/page-meta "" nil ""))
  (let ((one (jfw/page-meta "30/06/2026" "2026-06-30" nil)))
    (should (= (length one) 1))
    (should (string-match-p "30/06/2026" (pp-to-string one)))
    (should (string-match-p "datetime" (pp-to-string one))))
  (let ((both (jfw/page-meta "30/06/2026" "2026-06-30" 6)))
    (should (string-match-p " · " (pp-to-string both)))
    (should (string-match-p "6 minutes" (pp-to-string both))))
  ;; A one-minute page is a minute, not minutes.
  (should (string-match-p "1 minute" (pp-to-string (jfw/page-meta nil nil 1)))))

;;; ---------------------------------------------------------------------
;;; Text and dates
;;; ---------------------------------------------------------------------

(ert-deftest jfw-test/plain-text-strips-tags-and-decodes-entities ()
  "Text headed for a meta tag must already be plain, or it is escaped twice."
  (should (equal (jfw/plain-text "<p>Hello &amp; welcome</p>") "Hello & welcome"))
  (should (equal (jfw/plain-text "a  <b>b</b>\n   c") "a b c"))
  (should (equal (jfw/plain-text "caf&#233;") "café"))
  (should (equal (jfw/plain-text "  ") "")))

(ert-deftest jfw-test/escape-html-escapes-what-html-reserves ()
  "An ampersand in a title cannot become an entity in the page."
  (should (equal (jfw/escape-html "<a & 'b'>") "&lt;a &amp; &#39;b&#39;&gt;"))
  (should (equal (jfw/escape-html "plain") "plain")))

(ert-deftest jfw-test/bound-words-cuts-at-a-word-and-marks-the-cut ()
  "A shortened description ends at a space and says that it was cut."
  (let* ((text "one two three four five six seven eight")
         (short (jfw/bound-words text 20)))
    (should (<= (length short) 21))
    (should (string-suffix-p "…" short))
    (should (string-prefix-p "one two" short)))
  (should (equal (jfw/bound-words "short" 20) "short")))

(ert-deftest jfw-test/date-sort-key-reads-both-shapes-of-date ()
  "A bare date and a timestamp sort the same way, and a bad one sorts last."
  (should (= (jfw/date-sort-key "2025-04-11") 20250411))
  (should (= (jfw/date-sort-key "<2025-04-11 Fri>") 20250411))
  (should (= (jfw/date-sort-key "[2025-04-11 Fri 10:00]") 20250411))
  (should-not (jfw/date-sort-key ""))
  (should-not (jfw/date-sort-key nil)))

(ert-deftest jfw-test/date-display-shows-the-day-it-was-written ()
  "An index entry shows the same shape of date the exporter writes."
  ;; The day name follows the build machine's locale, exactly as a timestamp
  ;; written in a paragraph does, so the test names the locale it means.
  (let ((system-time-locale "C"))
    (should (equal (jfw/date-display "2025-04-11") "2025-04-11 Fri")))
  ;; A date the build cannot read is passed through rather than dropped.
  (should (equal (jfw/date-display "someday") "someday"))
  (should-not (jfw/date-display nil)))

(ert-deftest jfw-test/reading-time-is-never-zero ()
  "A short page takes a minute, not no time at all."
  (should (= (estimate-reading-time "one two three") 1))
  (should (= (estimate-reading-time "") 1))
  ;; 130 words a minute is the declared speed, so 260 words read as two.
  (should (= (estimate-reading-time (mapconcat #'identity (make-list 260 "word") " ")) 2)))

;;; ---------------------------------------------------------------------
;;; Reading a page's own keywords
;;; ---------------------------------------------------------------------

(ert-deftest jfw-test/org-keyword-reads-a-value-and-reports-an-absence ()
  "Present-but-empty and absent are different answers, and both are useful."
  (jfw-test/with-temp-org "#+title: A title\n#+highlight: yes\n#+description:\nbody\n"
    (should (equal (jfw/org-keyword file "title") "A title"))
    (should (equal (jfw/org-keyword file "highlight") "yes"))
    (should (equal (jfw/org-keyword file "description") ""))
    (should-not (jfw/org-keyword file "keywords"))))

(ert-deftest jfw-test/article-metadata-describes-an-article ()
  "A listing entry is made of what the article says about itself."
  (jfw-test/with-temp-org
      (concat "#+title: A & B\n"
              "#+date: 2025-04-11\n"
              "#+description: About things\n"
              "#+highlight: yes\n"
              "\nbody\n")
    ;; The day name follows the machine's locale, so the test names the one
    ;; it means while the entry is composed.
    (let ((article (let ((system-time-locale "C")) (jfw/article-metadata file))))
      (should (equal (plist-get article :title) "A & B"))
      (should (= (plist-get article :date-key) 20250411))
      (should (equal (plist-get article :date-display) "2025-04-11 Fri"))
      (should (equal (plist-get article :description) "About things"))
      (should (plist-get article :highlight))
      ;; The category is the directory the file lives in.
      (should (equal (plist-get article :category)
                     (file-name-nondirectory (directory-file-name (file-name-directory file))))))))

(ert-deftest jfw-test/article-metadata-skips-a-forwarding-page ()
  "A stub forwards readers and is not an article, so it is not listed."
  (jfw-test/with-temp-org "#+title: Moved\n#+redirect: /elsewhere/\n"
    (should-not (jfw/article-metadata file))))

(ert-deftest jfw-test/highlight-reads-any-value-but-no ()
  "An article can say why it is highlighted instead of only that it is."
  (dolist (value jfw/highlight-off)
    (jfw-test/with-temp-org (format "#+title: T\n#+highlight: %s\n" value)
      (should-not (plist-get (jfw/article-metadata file) :highlight))))
  (jfw-test/with-temp-org "#+title: T\n#+highlight: because it is good\n"
    (should (plist-get (jfw/article-metadata file) :highlight))))

;;; ---------------------------------------------------------------------
;;; Blog listings
;;; ---------------------------------------------------------------------

(defmacro jfw-test/with-articles (articles &rest body)
  "Evaluate BODY with the blog's article list replaced by ARTICLES.
The listings are pure functions of that list, so a fixture is all a test of
them needs; no file has to be written to disk."
  (declare (indent 1) (debug t))
  `(let ((jfw/blog-articles-cache (list ,@articles))
         (jfw/listing-entries-written 0)
         (jfw/listing-pages-written 0))
     ,@body))

(ert-deftest jfw-test/listing-highlighted-shows-only-the-highlights ()
  "The front page's selection is the articles that asked to be on it."
  (jfw-test/with-articles ((list :title "On the front" :highlight t :category "emacs")
                           (list :title "Only in its category" :highlight nil :category "emacs"))
    (should (equal (mapcar (lambda (article) (plist-get article :title))
                           (jfw/listing-articles "highlighted" "/blog/"))
                   '("On the front")))))

(ert-deftest jfw-test/listing-category-shows-its-own-category ()
  "A category page lists every article of its own category and no other."
  (jfw-test/with-articles ((list :title "An Emacs post" :category "emacs")
                           (list :title "A Lisp post" :category "lisps"))
    (should (equal (mapcar (lambda (article) (plist-get article :title))
                           (jfw/listing-articles "category" "/blog/articles/emacs/"))
                   '("An Emacs post")))))

(ert-deftest jfw-test/listing-unknown-kind-is-empty-not-guessed ()
  "A typo in an index page leaves the page blank rather than wrong."
  (jfw-test/with-articles ((list :title "A post" :highlight t :category "emacs"))
    (should-not (jfw/listing-articles "highlight" "/blog/"))))

(ert-deftest jfw-test/listing-entry-escapes-what-it-is-given ()
  "A title holding markup cannot break the page it is listed on."
  (let ((html (jfw/listing-entry-html
               (list :title "R&D <live>" :url "/blog/articles/emacs/x/"
                     :date-display "2025-04-11 Fri" :description "a & b"))))
    (should (string-match-p "R&amp;D &lt;live&gt;" html))
    (should (string-match-p "a &amp; b" html))
    (should (string-match-p "href=\"/blog/articles/emacs/x/\"" html))
    (should (string-match-p "2025-04-11 Fri" html))
    ;; The summary is optional: an article without a description is still an
    ;; entry, and gains no dangling dash.
    (let ((bare (jfw/listing-entry-html (list :title "Bare" :url "/x/"))))
      (should (string-match-p ">Bare</a>" bare))
      (should-not (string-match-p " - " bare)))))

(ert-deftest jfw-test/listing-html-counts-what-it-wrote ()
  "The build reports what the listings found, so the count has to be right."
  (jfw-test/with-articles ((list :title "One" :highlight t :category "emacs" :url "/1/")
                           (list :title "Two" :highlight t :category "emacs" :url "/2/"))
    (let ((html (jfw/listing-html "highlighted" "/blog/")))
      (should (string-match-p "/1/" html))
      (should (string-match-p "/2/" html))
      (should (= jfw/listing-entries-written 2))
      (should (= jfw/listing-pages-written 1)))))

(ert-deftest jfw-test/special-block-fills-a-listing ()
  "A page asks for a listing, and the build writes it out of the articles."
  (jfw-test/with-articles ((list :title "Highlighted" :highlight t :category "emacs"
                                 :url "/blog/articles/emacs/x/"
                                 :date-display "2025-04-11 Fri"
                                 :description "About things."))
    (let* ((info (list :input-file (expand-file-name "docs/blog/index.org" jfw-test/root)))
           (block (org-element-create 'special-block
                                      (list :type "listing" :parameters "highlighted")))
           (html (jfw/org-html-special-block block nil info)))
      (should (string-match-p "Highlighted" html))
      (should (string-match-p "/blog/articles/emacs/x/" html)))))

(ert-deftest jfw-test/blog-articles-are-newest-first ()
  "The listings are the same on every build: newest first, then by title."
  (let ((articles (jfw/blog-articles)))
    (should (> (length articles) 0))
    (should (cl-every (lambda (article) (plist-get article :title)) articles))
    (let ((keys (delq nil (mapcar (lambda (article) (plist-get article :date-key)) articles))))
      (should (equal keys (sort (copy-sequence keys) #'>))))))

(ert-deftest jfw-test/every-article-has-a-title-and-a-readable-date ()
  "The content the site ships can be listed, cited and sorted."
  (dolist (file (jfw/article-files))
    (should (jfw/org-keyword file "title"))
    (should (jfw/date-sort-key (jfw/org-keyword file "date")))))

;;; ---------------------------------------------------------------------
;;; Social cards
;;; ---------------------------------------------------------------------

(ert-deftest jfw-test/og-card-escape-protects-the-svg ()
  "A title with an ampersand cannot break the card that carries it."
  (should (equal (jfw/og-card-escape "R&D <x>") "R&amp;D &lt;x&gt;"))
  (should (equal (jfw/og-card-escape "it's") "it&apos;s")))

(ert-deftest jfw-test/og-card-estimate-measures-with-the-declared-advances ()
  "A card is measured with the font's own advances, not with a guess."
  (let ((narrow (jfw/og-card-estimate "iii" 100))
        (wide (jfw/og-card-estimate "WWW" 100)))
    (should (> narrow 0))
    (should (> wide narrow)))
  ;; Size and width are proportional: twice the size is twice the measure.
  (should (< (abs (- (* 2 (jfw/og-card-estimate "hello" 50))
                     (jfw/og-card-estimate "hello" 100)))
             0.001)))

(ert-deftest jfw-test/og-card-wrap-keeps-every-line-inside-the-card ()
  "A wrapped title never reaches past the card's text column."
  (let* ((title (mapconcat #'identity (make-list 24 "engineering") " "))
         (lines (jfw/og-card-wrap title 62 jfw/og-card-text-width)))
    (should (> (length lines) 1))
    (dolist (line lines)
      (should (<= (jfw/og-card-estimate line 62) jfw/og-card-text-width)))))

(ert-deftest jfw-test/og-card-title-layout-fits-a-short-title-on-one-line ()
  "A short title is set at the largest size, on one line."
  (let ((layout (jfw/og-card-title-layout "A short title")))
    (should (= (car layout) (car jfw/og-card-title-sizes)))
    (should (= (length (cdr layout)) 1))))

(ert-deftest jfw-test/og-card-title-layout-steps-down-for-a-long-title ()
  "A long title takes more lines rather than overflowing the card."
  (let* ((title (mapconcat #'identity
                           (make-list 18 "extraordinarily" )
                           " "))
         (layout (jfw/og-card-title-layout title))
         (size (car layout))
         (lines (cdr layout)))
    (should (member size jfw/og-card-title-sizes))
    (should (> (length lines) 1))
    (dolist (line lines)
      (should (<= (jfw/og-card-estimate line size) jfw/og-card-text-width)))))

(ert-deftest jfw-test/og-card-svg-is-well-formed ()
  "The card is XML, and a rasteriser is entitled to refuse anything else."
  (skip-unless (fboundp 'libxml-parse-xml-region))
  (let ((svg (jfw/og-card-svg "R&D: a title" "emacs")))
    (should (string-prefix-p "<svg" svg))
    (should (string-match-p "R&amp;D: a title" svg))
    (with-temp-buffer
      (insert svg)
      (should (libxml-parse-xml-region (point-min) (point-max))))))

(ert-deftest jfw-test/og-card-address-mirrors-the-article ()
  "A card lives where a reader would look for its article's card."
  (let ((path (jfw-test/any-article-path)))
    (should (equal (jfw/og-card-url path)
                    (concat "/" jfw/og-cards-directory "/"
                            (car (jfw/og-card-parts path)) "/"
                            (cdr (jfw/og-card-parts path)) ".png")))
    (should (string-suffix-p ".png" (jfw/og-card-file path "png"))))
  ;; Pages that are not articles keep the site-wide card.
  (should-not (jfw/og-card-parts "/blog/"))
  (should-not (jfw/og-card-url "/blog/")))

;;; ---------------------------------------------------------------------
;;; Structured data and page metadata
;;; ---------------------------------------------------------------------

(defun jfw-test/json-ld-graph (&rest args)
  "Return the @graph of the JSON-LD document built from ARGS, parsed.
Parsing it rather than matching the string is the point: what a crawler
does with this page is parse it, so the test does the same.  Keys come back
as symbols, which is how an alist is parsed."
  (let* ((json (apply #'jfw/json-ld args))
         (document (json-parse-string json :object-type 'alist)))
    ;; A JSON array parses into a vector; the tests read it as a list.
    (append (alist-get '@graph document) nil)))

(defun jfw-test/type-of-node (nodes wanted)
  "Return the nodes in NODES whose @type is WANTED."
  (cl-remove-if-not (lambda (node) (equal (alist-get '@type node) wanted)) nodes))

(ert-deftest jfw-test/json-ld-describes-an-article ()
  "An article is a BlogPosting, with its dates and its section."
  (let* ((nodes (jfw-test/json-ld-graph
                 :title "A title" :description "A description"
                 :url "https://example.org/blog/articles/emacs/x/"
                 :path "/blog/articles/emacs/x/" :index-p nil
                 :image "https://example.org/card.png" :published "2025-04-11"
                 :modified "2025-05-01" :keywords '("emacs" "lisp")
                 :section "Emacs"))
         (posting (car (jfw-test/type-of-node nodes "BlogPosting"))))
    (should posting)
    (should (equal (alist-get 'headline posting) "A title"))
    (should (equal (alist-get 'datePublished posting) "2025-04-11"))
    (should (equal (alist-get 'dateModified posting) "2025-05-01"))
    (should (equal (alist-get 'articleSection posting) "Emacs"))
    (should (equal (alist-get 'keywords posting) ["emacs" "lisp"]))
    (should (jfw-test/type-of-node nodes "Person"))
    (should (jfw-test/type-of-node nodes "WebSite"))
    (should (jfw-test/type-of-node nodes "BreadcrumbList"))))

(ert-deftest jfw-test/json-ld-describes-a-page ()
  "Anything that is not an article is a WebPage, and still carries a trail."
  (let* ((nodes (jfw-test/json-ld-graph
                 :title "Docs" :description "D" :url "https://example.org/docs/"
                 :path "/documentation/" :index-p t
                 :image "https://example.org/card.png"))
         (page (car (jfw-test/type-of-node nodes "WebPage"))))
    (should page)
    (should (equal (alist-get 'name page) "Docs"))
    (should-not (jfw-test/type-of-node nodes "BlogPosting"))))

(ert-deftest jfw-test/json-ld-script-cannot-close-its-own-element ()
  "A title holding a closing script tag must not end the script element."
  (let ((script (jfw/json-ld-script "{\"headline\": \"</script>\", \"a\": \"<b>\"}")))
    (should-not (string-match-p "<" script))
    (should (string-match-p "\\\\u003c" script))))

(ert-deftest jfw-test/theme-colors-cover-both-schemes ()
  "The browser's chrome is tinted for each scheme it might be asked about."
  (let ((metas (jfw/theme-color-metas)))
    (should (= (length metas) 2))
    (dolist (scheme '("light" "dark"))
      (let ((meta (cl-find-if (lambda (node)
                                (let ((attributes (cadr node)))
                                  (equal (cadr (assq 'media attributes))
                                         (format "(prefers-color-scheme: %s)" scheme))))
                              metas)))
        (should meta)
        (should (string-prefix-p "#" (cadr (assq 'content (cadr meta)))))))))

(ert-deftest jfw-test/theme-init-script-restores-the-choice ()
  "The inline script touches the same storage key the chooser does."
  (should (string-match-p (regexp-quote jfw/theme-storage-key) jfw/theme-init-script))
  (should (string-match-p "\"light\"" jfw/theme-init-script))
  (should (string-match-p "\"dark\"" jfw/theme-init-script))
  ;; It also marks the document as JS-capable, which is what reveals the
  ;; controls that would be dead without scripting.
  (should (string-match-p "data-js" jfw/theme-init-script)))

(ert-deftest jfw-test/page-scripts-loads-what-the-page-asked-for ()
  "A page downloads the scripts it names, and nothing it does not."
  (should (= (length (jfw/page-scripts (list :scripts "repl"))) 1))
  (should (= (length (jfw/page-scripts (list :scripts "repl, radar"))) 2))
  (should (= (length (jfw/page-scripts (list :scripts "repl radar"))) 2))
  (should-not (jfw/page-scripts (list :scripts "")))
  (should-not (jfw/page-scripts nil))
  ;; An unknown name is dropped rather than guessed at.
  (should-not (jfw/page-scripts (list :scripts "replx"))))

;;; ---------------------------------------------------------------------
;;; The rail
;;; ---------------------------------------------------------------------
;; The rail is written by the build rather than by a script, so that it is
;; part of the page a reader receives rather than something a reader has to
;; be able to run.

(defun jfw-test/rail-html (content)
  "Return the rail built for CONTENT as HTML, or nil when there is none."
  (when-let* ((rail (jfw/page-rail content)))
    (sxml-to-xml (car rail))))

(ert-deftest jfw-test/page-rail-is-built-from-the-headings ()
  "The rail names the page's own headings and links to their own anchors."
  (let ((html (jfw-test/rail-html
               (concat (jfw-test/heading-html 2 "The rings" "the-rings")
                       "<p>Prose between two headings.</p>"
                       (jfw-test/heading-html 2 "What FREE means" "what-free-means")
                       (jfw-test/heading-html 3 "A detail" "a-detail")))))
    (should html)
    (should (string-match-p "on this page" html))
    (should (string-match-p "href=\"#the-rings\"" html))
    (should (string-match-p "What FREE means" html))
    ;; The "#" the heading carries beside its text is not part of its name.
    (should-not (string-match-p "The rings #" html))
    ;; A third-level heading is drawn as a sub-entry.
    (should (string-match-p "article-rail-item is-sub" html))))

(ert-deftest jfw-test/page-rail-needs-three-headings ()
  "Two headings are furniture, and a page with two gets no rail."
  (should-not (jfw/page-rail (concat (jfw-test/heading-html 2 "One" "one")
                                     (jfw-test/heading-html 2 "Two" "two"))))
  (should-not (jfw/page-rail "<p>A page with no headings at all.</p>"))
  (should-not (jfw/page-rail nil)))

(ert-deftest jfw-test/page-rail-leaves-out-what-is-folded-away ()
  "A heading inside a closed disclosure is not in the rail, and one inside
an open disclosure is."
  (let ((closed (format "<details><summary>Folded</summary>%s</details>"
                        (jfw-test/heading-html 2 "Hidden" "hidden")))
        (opened (format "<details open=\"true\"><summary>Open</summary>%s</details>"
                        (jfw-test/heading-html 2 "Shown" "shown"))))
    ;; Two headings the reader can see, one they cannot: still no rail.
    (should-not (jfw-test/rail-html (concat (jfw-test/heading-html 2 "One" "one")
                                            (jfw-test/heading-html 2 "Two" "two")
                                            closed)))
    (let ((html (jfw-test/rail-html (concat (jfw-test/heading-html 2 "One" "one")
                                            (jfw-test/heading-html 2 "Two" "two")
                                            opened))))
      (should html)
      (should (string-match-p "Shown" html))
      (should-not (string-match-p "Hidden" html)))))

;;; ---------------------------------------------------------------------
;;; The page template
;;; ---------------------------------------------------------------------
;; The chrome is written with s-expressions, and a mistake there is a blank
;; page rather than a compiler error, so the template is exercised here.

(ert-deftest jfw-test/generate-page-writes-the-chrome ()
  "A generated page carries the document head, the chrome and the footer."
  (let* ((info (jfw-test/info "docs/home/index.org" "2025-04-11"))
         (content (concat "<p>Hello</p>"
                          (jfw-test/heading-html 2 "One" "one")
                          (jfw-test/heading-html 2 "Two" "two")
                          (jfw-test/heading-html 2 "Three" "three")))
         (html (jfw/generate-page "A title" content info :content-reading-time 1)))
    ;; The head.
    (should (string-match-p "<!DOCTYPE html>" html))
    (should (string-match-p "<title>A title - jointhefreeworld</title>" html))
    (should (string-match-p "name=\"theme-color\"" html))
    (should (string-match-p "application/ld\\+json" html))
    (should (string-match-p "rel=\"canonical\"" html))
    ;; The bar: a wordmark, the places, the menu and the theme chooser.
    (should (string-match-p "class=\"site-header\"" html))
    (should (string-match-p "class=\"toolbelt\"" html))
    (should (string-match-p "class=\"site-mark\"" html))
    (should (string-match-p "class=\"nav-more\"" html))
    (should (string-match-p "data-jfw-theme-toggle=\"true\"" html))
    ;; The hero: the section, the title, and the stamp beneath them.
    (should (string-match-p "class=\"page-kicker\"" html))
    (should (string-match-p "jointhefreeworld</p>" html))
    (should (string-match-p "class=\"site-post-title\"" html))
    (should (string-match-p "class=\"page-meta\"" html))
    (should (string-match-p "1 minute" html))
    ;; The body: the sheet, and the rail the build wrote beside it.
    (should (string-match-p "class=\"page-body has-rail\"" html))
    (should (string-match-p "class=\"article-rail\"" html))
    (should (string-match-p "on this page" html))
    (should (string-match-p "href=\"#three\"" html))
    (should (string-match-p "id=\"content\"" html))
    (should (string-match-p "class=\"site-footer\"" html))
    (should (string-match-p "class=\"jfw-skip-link\"" html))
    (should (string-match-p "data-jfw-progress=\"true\"" html))
    ;; The content itself, and no placeholder left behind.
    (should (string-match-p "<p>Hello</p>" html))
    (should-not (string-match-p "__RAW_TITLE_PLACEHOLDER__" html))
    (should-not (string-match-p "__RAW_CONTENT_PLACEHOLDER__" html))
    (should-not (string-match-p "__JSON_LD_PLACEHOLDER__" html))
    (should-not (string-match-p "__THEME_INIT_PLACEHOLDER__" html))))

(ert-deftest jfw-test/generate-page-gives-a-short-page-one-column ()
  "A page with too few headings gets no rail and no empty gutter."
  (let* ((info (jfw-test/info "docs/home/index.org" "2025-04-11"))
         (html (jfw/generate-page "A title" "<p>Hello</p>" info)))
    (should (string-match-p "class=\"page-body\"" html))
    (should-not (string-match-p "page-body has-rail" html))
    (should-not (string-match-p "class=\"article-rail\"" html))))

(ert-deftest jfw-test/generate-page-closes-every-element-it-opens ()
  "The progress line is empty, and must still be closed.
An unclosed element there once nested the whole page inside a line two
pixels tall, so the shape of this one element is worth a test of its own."
  (let* ((info (jfw-test/info "docs/home/index.org" "2025-04-11"))
         (html (jfw/generate-page "A title" "<p>Hello</p>" info)))
    ;; The line is empty and explicitly closed, rather than self-closing:
    ;; the serialiser writes an opening tag for an element with no content,
    ;; and everything after it would then be its child.
    (should (string-match-p "class=\"jfw-progress\"[^>]*></div>" html))))

(ert-deftest jfw-test/generate-page-omits-what-it-was-asked-to-omit ()
  "A page of an embed or a fragment can drop the shared furniture."
  (let* ((info (jfw-test/info "docs/home/index.org" "2025-04-11"))
         (html (jfw/generate-page "A title" "<p>Hello</p>" info
                                  :exclude-header t :exclude-footer t)))
    (should-not (string-match-p "class=\"site-header" html))
    (should-not (string-match-p "class=\"site-footer\"" html))
    (should (string-match-p "id=\"content\"" html))))

;;; ---------------------------------------------------------------------
;;; Breadcrumbs
;;; ---------------------------------------------------------------------

(ert-deftest jfw-test/breadcrumb-steps-leave-out-the-url-of-the-last-step ()
  "The trail ends on the page the reader is already standing on."
  (let ((steps (jfw/breadcrumb-steps "/blog/articles/emacs/emacs-registers/"
                                     "Emacs registers" nil)))
    (should (equal (car (car steps)) "Home"))
    (should (equal (cdr (car steps)) "/"))
    ;; The bare "articles" level is an implementation detail, not a place.
    (should-not (assoc "articles" (mapcar (lambda (step) (cons (car step) nil)) steps)))
    (should (equal (car (car (last steps))) "Emacs registers"))
    (should-not (cdr (car (last steps)))))
  ;; An index page stops at its own directory, with a URL on every step.
  (dolist (step (jfw/breadcrumb-steps "/blog/articles/emacs/" "Emacs" t))
    (should (cdr step))))

;;; ---------------------------------------------------------------------
;;; The tech radar's source of truth
;;; ---------------------------------------------------------------------

;; `tech-radar.js' draws the radar from the article rather than from a list
;; of its own, so the article's outline *is* the radar's data. These tests
;; state the contract the script reads it by: the rings are the sections, in
;; the order they are written, and the layers are the sub-headings inside
;; them. Nothing below repeats a count or a technology list — those are the
;; article's to change — only the shape the drawing depends on.

(defconst jfw-test/radar-file
  (expand-file-name "docs/blog/articles/development/tech-radar.org" jfw-test/root)
  "The tech radar article, the only source of the radar's content.")

(defun jfw-test/radar-headlines ()
  "Return every headline of the radar article, in document order."
  (with-temp-buffer
    (insert-file-contents jfw-test/radar-file)
    (org-mode)
    (org-element-map (org-element-parse-buffer) 'headline #'identity)))

(defun jfw-test/heading-name (headline)
  "Return HEADLINE's text without the emoji it opens with: \"✅ Adopt\" -> \"Adopt\".
The class is spelled out in ASCII on purpose: `[:alnum:]' is answered by
the buffer's syntax table, which gives the variation selector in \"🗑️\" word
syntax, so it would survive the strip."
  (let ((title (org-element-interpret-data (org-element-property :title headline))))
    (substring-no-properties
     (string-trim (replace-regexp-in-string "\\`[^A-Za-z0-9]+" "" title)))))

(defun jfw-test/radar-rings ()
  "Return the radar article's ring headlines, in the order they are written.
A ring is the section that asks for `section' containers carrying the
`jfw-radar-ring' class, which is exactly what the drawing script looks for
on the published page."
  (cl-remove-if-not
   (lambda (headline)
     (equal "jfw-radar-ring" (org-element-property :HTML_CONTAINER_CLASS headline)))
   (jfw-test/radar-headlines)))

(defun jfw-test/radar-layers (ring)
  "Return the layer headlines inside RING, in the order they are written."
  (org-element-map (org-element-contents ring) 'headline #'identity))

(ert-deftest jfw-test/radar-leads-with-the-rings ()
  "The radar is organised ring first: Adopt, Trial, Assess, Deprecate.
The drawing puts these bands from the middle outwards in the order the
article gives them, so this order is the radar's rather than a detail of a
heading."
  (should (equal (mapcar #'jfw-test/heading-name (jfw-test/radar-rings))
                 '("Adopt" "Trial" "Assess" "Deprecate"))))

(ert-deftest jfw-test/radar-layers-sit-inside-every-ring ()
  "Every ring names the layers it lands in, and only the known layer names.
A layer becomes a wedge of the picture, so a ring that invented a seventh
layer name would widen the radar without anything saying so; a ring with no
layers at all would be a band with nothing to say."
  (let ((known '("Languages" "Frameworks & UI" "Data & Storage"
                 "Tools & Environment" "Platforms & Delivery" "Practice & Craft")))
    (should (jfw-test/radar-rings))
    (dolist (ring (jfw-test/radar-rings))
      (let ((layers (mapcar #'jfw-test/heading-name (jfw-test/radar-layers ring))))
        (should (equal (length (cl-delete-if-not
                                (lambda (layer) (member layer known))
                                layers))
                       (length layers)))
        (should layers)))))

(ert-deftest jfw-test/radar-trials-deepseek-as-a-tool ()
  "DeepSeek is trialled as a tool, and described as one on a short leash.
The entry earns its place by where it sits: an assistant that drafts and
reviews while a human decides belongs in Trial, not in Adopt."
  (let* ((rings (jfw-test/radar-rings))
         (trial (cl-find "Trial" rings
                         :test #'equal :key #'jfw-test/heading-name))
         (tools (and trial (cl-find "Tools & Environment" (jfw-test/radar-layers trial)
                                    :test #'equal :key #'jfw-test/heading-name)))
         (text (and tools (org-element-interpret-data (org-element-contents tools)))))
    (should trial)
    (should tools)
    (when (stringp text)
      (should (string-match-p "DeepSeek" text))
      (should (string-match-p "deepseek\\.com" text))
      ;; Marked as what it is in this revision, not quietly folded in.
      (should (string-match-p "(new)" text)))))

(provide 'jointhefreeworld-site-test)

;;; jointhefreeworld-site-test.el ends here
