;;; jfw-pages.el --- jointhefreeworld build  -*- lexical-binding: t -*-

;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:

;; Part of the site build.  The entry point is ./jointhefreeworld-site.el,
;; which installs the packages and requires this file after them; nothing
;; here is meant to be loaded on its own.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'dom)
(require 'vc-git)
(require 'jfw-core)



(defun get-article-output-path (org-file pub-dir)
  "Return the output directory for ORG-FILE under PUB-DIR.
Index and 404 pages are published directly into PUB-DIR; every other
page gets its own lowercased directory."
  (if (string-match-p "index\\.org$\\|404\\.org$" org-file)
      pub-dir
    (let ((article-dir (expand-file-name (downcase (file-name-base org-file)) pub-dir)))
      (unless (file-directory-p article-dir)
        (make-directory article-dir t))
      (file-name-as-directory article-dir))))

;;; ---------------------------------------------------------------------
;;; Page metadata: canonical URLs, social cards, robots and JSON-LD
;;; ---------------------------------------------------------------------
;; Every page gets a canonical URL, a complete Open Graph and Twitter
;; card, and a JSON-LD description of itself, so that shared links render
;; richly and search engines can tell the pages apart without guessing.

(defconst jfw/og-image "/static/img/share-default.png"
  "Site-wide social sharing card, used when a page sets no #+OG_IMAGE:.")

(defconst jfw/og-image-width "1200")
(defconst jfw/og-image-height "630")

(defconst jfw/og-image-alt
  "jointhefreeworld — free software, engineering writing and the FREE stack, by Josep Bigorra"
  "Alt text describing the default social sharing card.")

(defconst jfw/robots-indexable
  "index, follow, max-image-preview:large, max-snippet:-1, max-video-preview:-1"
  "Robots directives for pages that should be indexed in full.")

(defconst jfw/robots-stub "noindex, follow"
  "Robots directives for pages that only forward to their new home.")

(defconst jfw/html-entities
  '(("amp" . "&") ("lt" . "<") ("gt" . ">") ("quot" . "\"")
    ("apos" . "'") ("nbsp" . " ") ("hellip" . "…") ("mdash" . "—")
    ("ndash" . "–") ("lsquo" . "‘") ("rsquo" . "’") ("ldquo" . "“")
    ("rdquo" . "”") ("times" . "×") ("copy" . "©"))
  "Named HTML entities decoded when turning exported HTML back to text.")

(defun jfw/decode-html-entity (match)
  "Return the character named by the entity in MATCH, or MATCH itself."
  (or (cdr (assoc (match-string 1 match) jfw/html-entities)) match))

(defun jfw/plain-text (html)
  "Return HTML with its tags stripped, entities decoded and space collapsed.
The result is plain text, so the consumers that re-escape it — the meta
tags — never double-encode an ampersand or an accent."
  (when html
    (let* ((text (replace-regexp-in-string "<[^>]*>" " " html))
           (text (replace-regexp-in-string "&\\([a-zA-Z]+\\);" #'jfw/decode-html-entity text t))
           (text (replace-regexp-in-string "&#\\([0-9]+\\);"
                                           (lambda (m) (string (string-to-number (match-string 1 m))))
                                           text t)))
      ;; Export data carries face properties, and an attribute writer
      ;; prints those along with the text, so drop them here.
      (substring-no-properties
       (string-trim (replace-regexp-in-string "[[:space:]]+" " " text))))))

(defun jfw/bound-words (text limit)
  "Return TEXT shortened to at most LIMIT characters, at a word boundary."
  (if (<= (length text) limit)
      text
    (let ((cut (substring text 0 limit)))
      (concat (string-trim (substring cut 0 (or (string-match " [^ ]*\\'" cut) limit)))
              "…"))))

(defconst jfw/html-escapes
  '((?& . "&amp;") (?< . "&lt;") (?> . "&gt;") (?\" . "&quot;") (?\' . "&#39;"))
  "The characters HTML reserves, and the entities that replace them.")

(defun jfw/escape-html (text)
  "Return TEXT with the characters HTML reserves replaced by entities."
  (when text
    (replace-regexp-in-string
     "[&<>\"']"
     (lambda (match) (cdr (assq (string-to-char match) jfw/html-escapes)))
     text t t)))

(defconst jfw/section-labels
  '(("ci" . "CI/CD") ("development" . "Dev") ("gnu-linux" . "GNU/Linux")
    ("freebsd" . "FreeBSD") ("lisps" . "Lisps") ("emacs" . "Emacs")
    ("haskell" . "Haskell") ("rust" . "Rust") ("go" . "Go")
    ("personal" . "Personal"))
  "Human names for the blog's category directories, shared by the
article:section meta tag, the structured data and the breadcrumbs.")

(defun jfw/humanize (slug)
  "Return SLUG turned into a human-readable label."
  (or (cdr (assoc slug jfw/section-labels))
      (capitalize (replace-regexp-in-string "-" " " slug))))

(defun jfw/file-page-path (file)
  "Return the site-relative URL that the Org source FILE answers at.
The path mirrors what `jfw/org-html-publish-to-html' writes: the docs/home
project lands at the root, every other project keeps its own
directory, and a non-index file gets a lowercase directory of its own.
This is the one place that knows the URL layout, so the canonical link,
the social card, the blog listings and the structured data all agree by
construction.  FILE may be nil, which answers for a page exported
without one."
  (let* ((input file)
         (docs-root (file-name-as-directory (expand-file-name "docs/" jfw/project-root)))
         (rel (if input (file-relative-name input docs-root) "index.org"))
         (project (car (split-string rel "/")))
         (prefix (jfw/project-url-prefix (concat project "/")))
         (rest (string-remove-prefix (concat project "/") rel))
         (base (file-name-base rest))
         (dir (file-name-directory rest))
         (root (if (string-empty-p prefix) "/" (concat "/" prefix "/"))))
    (cond
     ((string= base "404") "/404.html")
     ((string= base "index") (concat root (or dir "")))
     (t (concat root (or dir "") (downcase base) "/")))))

(defun jfw/page-path (info)
  "Return the site-relative URL of the page being exported."
  (jfw/file-page-path (plist-get info :input-file)))

(defvar jfw/url-prefix-cache (make-hash-table :test #'equal)
  "Cache of publish project directory to the URL prefix it writes.")

(defun jfw/project-url-prefix (project-dir)
  "Return the URL prefix that the publish project PROJECT-DIR writes to.
It is read back from `org-publish-project-alist' itself, so a project
that is moved in the build is also moved in its canonical URLs and
social cards without a second place to keep in sync."
  (or (gethash project-dir jfw/url-prefix-cache)
      (puthash project-dir
               (let* ((cwd jfw/project-root)
                      (docs-root (file-name-as-directory (expand-file-name "docs/" cwd)))
                      (public-root (file-name-as-directory (expand-file-name "public/" cwd)))
                      (base-dir (file-name-as-directory (expand-file-name project-dir docs-root))))
                 (catch 'found
                   (dolist (project org-publish-project-alist)
                     (let* ((plist (cdr project))
                            (project-base (when (plist-get plist :base-directory)
                                            (file-name-as-directory
                                             (expand-file-name (plist-get plist :base-directory) cwd))))
                            (publish-dir (when (plist-get plist :publishing-directory)
                                           (file-name-as-directory
                                            (expand-file-name (plist-get plist :publishing-directory) cwd)))))
                       (when (and project-base publish-dir (equal project-base base-dir))
                         (let ((prefix (string-trim (file-relative-name publish-dir public-root) "/" "/")))
                           (throw 'found (if (equal prefix ".") "" prefix))))))
                   ""))
               jfw/url-prefix-cache)))

(defun jfw/page-index-p (info)
  "Return non-nil when the page being exported is a directory index.
Such a page is reached by its directory name alone, so its breadcrumb
stops at that directory instead of repeating its own title."
  (let ((base (file-name-base (or (plist-get info :input-file) "index.org"))))
    (or (string= base "index") (string= base "404"))))

(defun jfw/absolute-url (path)
  "Return PATH as an absolute URL, leaving an already absolute one alone."
  (if (or (string-prefix-p "http://" path) (string-prefix-p "https://" path))
      path
    (concat jfw/site-url path)))

(defun jfw/article-path-p (path)
  "Return non-nil when PATH is a single blog article."
  (string-match-p "\\`/blog/articles/[^/]+/[^/]+/\\'" path))

(defun jfw/section-slug (path)
  "Return the blog category PATH belongs to, spelled as its directory is."
  (let ((parts (split-string (string-trim path "/" "/") "/" t)))
    (when (and (equal (car parts) "blog") (equal (cadr parts) "articles"))
      (nth 2 parts))))

(defun jfw/section-label (path)
  "Return the human name of the blog category PATH belongs to, if any."
  (when-let* ((category (jfw/section-slug path)))
    (jfw/humanize category)))

(defconst jfw/page-kickers
  '(("blog" . "Blog")
    ("documentation" . "Docs")
    ("portfolio" . "Portfolio")
    ("platform" . "Platform")
    ("joe-cv" . "CV")
    ("code-of-conduct" . "Code of Conduct")
    ("ai-policy" . "AI Policy")
    ("404" . "Nothing here"))
  "Names for the parts of the site that are not a blog category.
The kicker above a title is the site's own word for a section, so it is a
table rather than a guess at what a directory name meant.")

(defun jfw/page-kicker (path)
  "Return the word that names the part of the site PATH belongs to.
This is the small line above a page's title: the section the page sits in,
in the site's own words rather than in the words of its directory."
  (or (jfw/section-label path)
      (let ((head (car (split-string (string-trim path "/" "/") "/" t))))
        (cond
         ((null head) "jointhefreeworld")
         ((assoc (file-name-sans-extension head) jfw/page-kickers)
          (cdr (assoc (file-name-sans-extension head) jfw/page-kickers)))
         (t (jfw/humanize head))))))

(defconst jfw/rail-minimum-headings 3
  "How many headings a page needs before a rail is worth building.
Two entries in a list the reader can see at a glance is furniture; a page
long enough to get lost in is the one that earns a map.")

(defun jfw/dom-attributes (node)
  "Return the attribute alist of the parsed NODE, or nil when it has none.
A libxml node is (TAG ATTRIBUTES CHILD...), and a node with no attributes
carries its first child where the attributes would be, so the two cases are
told apart by looking at the shape rather than at the position."
  (let ((second (car-safe (cdr node))))
    (and (consp second) (consp (car second)) second)))

(defun jfw/heading-entry (node)
  "Return (ID . TEXT) for the heading NODE, or nil when it cannot be linked.
An exported heading carries its identifier on the anchor link beside its
text, and occasionally on the heading itself; either will do, and a heading
with neither is one nobody could link to anyway."
  (let* ((anchor (car (dom-by-class (list node) "anchor")))
         (id (or (and anchor (dom-attr anchor 'id))
                 (dom-attr node 'id)))
         (text (when id
                 (string-trim
                  (replace-regexp-in-string
                   "[\u00A0[:space:]]+" " "
                   (dom-texts node))))))
    (when (and text (not (string-empty-p text)))
      ;; The heading carries its own \"#\" link, and that glyph is not part
      ;; of the name a reader wants to read.
      (cons id (string-trim (replace-regexp-in-string "#\\s-*\\'" "" text))))))

(defun jfw/heading-entries (node hidden)
  "Return (LEVEL . (ID . TEXT)) for every heading under NODE, in order.
HIDDEN is non-nil inside a disclosure that is closed: a heading behind a
closed disclosure is not on the page as far as the reader is concerned, so
it is left out of the rail."
  (when (consp node)
    (let* ((tag (car node))
           (attributes (jfw/dom-attributes node))
           (children (if attributes (cddr node) (cdr node)))
           (hidden (or hidden
                       (and (eq tag 'details)
                            (not (assq 'open attributes)))))
           (entry (and (memq tag '(h2 h3))
                       (not hidden)
                       (jfw/heading-entry node))))
      (append
       (when entry (list (cons tag entry)))
       (cl-mapcan (lambda (child) (jfw/heading-entries child hidden))
                  children)))))

(defun jfw/page-rail (content)
  "Return the rail for CONTENT as sxml, or nil when the page is too short.
The rail is written while the page is exported, out of the page's own h2 and
h3 headings, so that a reader without scripting gets it too and the layout
does not change under a page that is still loading. It is the one part of
the page that used to need a script and no longer does; what the script adds
is the mark that follows the reader down it."
  (when (and content (fboundp 'libxml-parse-html-region))
    (let ((headings
           (with-temp-buffer
             (insert content)
             (jfw/heading-entries
              (libxml-parse-html-region (point-min) (point-max))
              nil))))
      (when (>= (length headings) jfw/rail-minimum-headings)
        (list
         `(aside (@ (class "article-rail"))
                 (p (@ (class "article-rail-title")) "on this page")
                 (ol (@ (class "article-rail-list"))
                     ,@(cl-loop for (level . entry) in headings
                                for (id . text) = entry
                                collect
                                `(li (@ (class ,(if (eq level 'h3)
                                                    "article-rail-item is-sub"
                                                  "article-rail-item")))
                                     (a (@ (class "article-rail-link")
                                           (href ,(concat "#" id)))
                                        ,text))))))))))

(defun jfw/page-meta (&optional publish-date iso-date reading-time)
  "Return the annotation line under a page's title, as sxml, or nil.
A page shows the date it was written and how long it takes to read; a page
with neither shows no line at all rather than an empty one.  The two are
separated by a middle dot, because a line of prose punctuation in a
monospaced voice is punctuation only."
  (let ((bits '()))
    (when (and publish-date (not (equal publish-date "")))
      (push `(time (@ (datetime ,(or iso-date ""))) ,publish-date) bits))
    (when (and reading-time (not (equal reading-time "")))
      (push (format "%s %s" reading-time
                    (if (equal (format "%s" reading-time) "1") "minute" "minutes"))
            bits))
    (when bits
      (let ((bits (nreverse bits)))
        `((p (@ (class "page-meta"))
             ,@(cl-loop for bit in bits
                        for first = t then nil
                        append (if first (list bit) (list " · " bit)))))))))

(defun jfw/iso-date (info)
  "Return the page's date as an ISO 8601 day, or nil when it has none."
  (let ((date (org-export-data (org-export-get-date info "%Y-%m-%d") info)))
    (when (and date (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'" date))
      date)))

(defvar jfw/git-date-cache (make-hash-table :test #'equal)
  "Cache of source file to the ISO date of the commit that last changed it.")

(defun jfw/git-file-date (file)
  "Return the ISO 8601 author date of the last commit touching FILE.
This is the honest answer to \"when was this article last updated?\",
which a checkout timestamp cannot give.  Unlike the file mtime it is
reproducible across clones, and a tarball without git simply yields nil
so the page omits the field instead of inventing one."
  (when (and file (file-exists-p file))
    (or (gethash file jfw/git-date-cache)
        (puthash file
                 (condition-case nil
                     (let ((out (string-trim
                                 (with-output-to-string
                                   (with-current-buffer standard-output
                                     (vc-git-command t nil nil "log" "-1" "--format=%aI" "--" file))))))
                       (when (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}" out) out))
                   (error nil))
                 jfw/git-date-cache))))

(defun jfw/keyword-list (info)
  "Return the page's #+keywords: as a list of trimmed strings."
  (let ((keywords (plist-get info :keywords)))
    (when (and keywords (stringp keywords) (not (string-empty-p (string-trim keywords))))
      (delq nil (mapcar (lambda (word)
                          (let ((word (string-trim word)))
                            (unless (string-empty-p word) word)))
                        (split-string keywords ","))))))

(defun jfw/breadcrumb-steps (path title index-p)
  "Return the breadcrumb steps from the site root to the page.
Each step is (LABEL . URL); the last one carries no URL because it is
the page the reader is already on.  Pure implementation details such as
the \"articles\" level are left out of the trail."
  (let* ((parts (split-string (string-trim path "/" "/") "/" t))
         (dirs (if index-p parts (butlast parts)))
         (steps (list (cons "Home" "/")))
         (accum ""))
    (dolist (dir dirs)
      (setq accum (concat accum "/" dir))
      (unless (member dir '("articles" "index"))
        (setq steps (append steps (list (cons (jfw/humanize dir) (concat accum "/")))))))
    (if (or index-p (null parts))
        steps
      (append steps (list (cons (jfw/plain-text title) nil))))))

(let ((common-props '(:base-extension "org"
                                      :publishing-function jfw/org-html-publish-to-html
                                      :with-title t
                                      :recursive t
                                      :with-timestamps t)))
  (setq org-publish-project-alist
        `(("jointhefreeworld:main"
           :base-directory "./docs/home"
           :publishing-directory "./public"
           ,@common-props)
          ("jointhefreeworld:blog"
           :base-directory "./docs/blog/"
           :publishing-directory "./public/blog"
           ,@common-props)
          ("jointhefreeworld:documentation"
           :base-directory "./docs/documentation/"
           :publishing-directory "./public/documentation"
           ,@common-props)
          ("jointhefreeworld:platform"
           :base-directory "./docs/platform/"
           :publishing-directory "./public/platform"
           ,@common-props)
          ("jointhefreeworld:portfolio"
           :base-directory "./docs/portfolio/"
           :publishing-directory "./public/portfolio"
           ,@common-props)
          ;; The project policies are site-wide documents rather than blog
          ;; posts, so they publish at the top level: /code-of-conduct/ and
          ;; /ai-policy/.  Their old blog URLs remain as forwarding stubs.
          ("jointhefreeworld:policies"
           :base-directory "./docs/policies/"
           :publishing-directory "./public"
           ,@common-props))))

(provide 'jointhefreeworld-site)

(provide 'jfw-pages)

;;; lisp/jfw-pages.el ends here
