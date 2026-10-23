;;; jointhefreeworld-site.el --- Build jointhefreeworld.org  -*- lexical-binding: t -*-

;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; Author: Josep Bigorra <jjbigorra@gmail.com>
;; Maintainer: Josep Bigorra <jjbigorra@gmail.com>
;; URL: https://codeberg.org/jjba23/jointhefreeworld
;; Package: emacs
;; Package-Requires: ((emacs "29.1"))

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

;;; Usage:
;; emacs -Q --batch -l ./jointhefreeworld-site.el --funcall jfw/publish
;;
;; or
;;
;; make publish

;; much inspired by David Wilson and his excellent videos and tutorials.
;; check his systemcrafters-site

;;; Code:

;; Initialize package sources
(require 'package)

;; Set the package installation directory so that packages aren't stored in the
;; ~/.emacs.d/elpa path.
(setq package-user-dir (expand-file-name "./.packages"))

(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/"))
(add-to-list 'package-archives '("melpa-stable" . "https://stable.melpa.org/packages/"))

;; Initialize the package system
(package-initialize)
(unless package-archive-contents
  (package-refresh-contents))

;; Install use-package
(unless (package-installed-p 'use-package)
  (package-install 'use-package))
(require 'use-package)

;; Require built-in dependencies
(require 'vc-git)
(require 'ox-publish)
(require 'subr-x)
(require 'cl-lib)
(require 'json)                          ; JSON-LD structured data

;; Install other dependencies
(use-package esxml
  :pin "melpa-stable"
  :ensure t)

(use-package htmlize
  :ensure t)

(use-package haskell-mode
  :ensure t)

(use-package rust-mode
  :ensure t)

(use-package kotlin-mode
  :ensure t)

(use-package webfeeder
  :ensure t)

(defconst jfw/video-iframe-format
  (concat "<div class=\"video\">"
          "  <iframe src=\"https://www.youtube.com/embed/%s\" allowfullscreen></iframe>"
          "</div>")
  "HTML template used to embed a YouTube video by its VIDEO-ID.")

(defun jfw/embed-video (video-id)
  "Return an HTML iframe embedding the YouTube video identified by VIDEO-ID."
  (format jfw/video-iframe-format video-id))

(setq user-full-name "Josep Bigorra")
(setq user-mail-address "jjbigorra@gmail.com")

(defconst jfw/project-root
  (file-name-as-directory
   (file-name-directory
    (or load-file-name buffer-file-name (expand-file-name "jointhefreeworld-site.el"))))
  "Absolute directory holding this build script and the project it builds.
Resolved once, while the file loads: during an export `default-directory'
is the directory of whichever Org file is being published, so it cannot
be used to find the project's own manifests, sources or output.")

(defconst jfw/site-url (if (string-equal (getenv "CI") "true")
                           "https://jointhefreeworld.org"
                         "http://localhost:50011")
  "The absolute URL the generated site will be published under.")

(defconst jfw/default-description
  "Free software, engineering writing, and the jointhefreeworld ecosystem, by Josep Bigorra."
  "Fallback meta description used for pages that do not define their own.")

(defun jfw/page-description (description &optional content path)
  "Return the meta description of a page, as plain text.
An explicit #+DESCRIPTION: wins.  Failing that, a blog article lends its
own opening prose, so a shared link says something specific about that
article instead of repeating the site tagline; every other page keeps
the site default."
  (let ((explicit (and description (string-trim description))))
    (cond
     ((and explicit (not (string-empty-p explicit))) explicit)
     ((and content path (jfw/article-path-p path)
           (> (length (jfw/plain-text content)) 60))
      (jfw/bound-words (jfw/plain-text content) 158))
     (t jfw/default-description))))

(defconst jfw/font-assets-url
  "https://jointhefreeworld.org/static-assets/fonts"
  "Base URL of the self-hosted font files referenced by the stylesheet.")

(defconst jfw/critical-fonts
  '("LSANS.woff"                   ; Lucida Sans regular, used for body copy
    "LSANSD.woff"                  ; Lucida Sans demi-bold, used for links
    "LSANSI.woff")                 ; Lucida Sans italic, used above the fold
  "Self-hosted font files used on first paint, preloaded to avoid a late swap.")

(defun jfw/font-preloads ()
  "Return preload link nodes for the critical font files.
Fonts are always fetched in CORS mode, so each preload requests them
anonymously; without ``crossorigin'' the preload would not match the
stylesheet's own request and the font would be fetched twice."
  (mapcar (lambda (file)
            `(link (@ (rel "preload")
                      (as "font")
                      (type "font/woff")
                      (crossorigin "anonymous")
                      (href ,(concat jfw/font-assets-url "/" file)))))
          jfw/critical-fonts))

(defconst jfw/google-fonts-url
  (concat "https://fonts.googleapis.com/css2?"
          "family=Intel+One+Mono:ital,wght@0,300..700;1,300..700&"
          "family=Plus+Jakarta+Sans:ital,wght@0,200..800;1,200..800&"
          "display=swap")
  "Google Fonts stylesheet for the fallback and code typefaces.")

(defconst jfw/theme-storage-key "jfw-theme"
  "localStorage key shared by the inline theme script and the toggle.
The toggle in `freeworld.js' reads the same key.")

(defconst jfw/theme-init-script
  (concat
   "(function(){try{var t=localStorage.getItem(\"" jfw/theme-storage-key "\");"
   "if(t===\"light\"||t===\"dark\"){document.documentElement.setAttribute(\"data-theme\",t);}}"
   "catch(e){}document.documentElement.setAttribute(\"data-js\",\"on\");})();")
  "Inline script that runs before first paint.
It restores a stored theme choice and marks the document as JS-capable,
which reveals the theme toggle. Keeping it inline avoids a flash of the
wrong theme while the deferred scripts are still loading.")

(defconst jfw/theme-colors
  '(("light" . "#faf3e8")
    ("dark" . "#18181b"))
  "The paper of the page, per colour scheme, as the browser wants it.
These mirror `--color-page-base' in the two palettes of the stylesheet.  A
value here and a value there that disagree would show as a strip of the
wrong colour above the page, so the pair is worth keeping in step.")

(defun jfw/theme-color-metas ()
  "Return the meta nodes that tint the browser's own chrome.
Each scheme gets a tag of its own and the browser picks the one that
matches the operating system, because a title bar is painted before any
script has run and cannot wait for the stored choice.  A visitor who
overrides the theme in the page itself keeps the system's tint in the
browser chrome, which is the closest thing to being right that the
standard allows."
  (mapcar (lambda (pair)
            `(meta (@ (name "theme-color")
                      (content ,(cdr pair))
                      (media ,(format "(prefers-color-scheme: %s)" (car pair))))))
          jfw/theme-colors))

(defconst jfw/repl-scripts
  `(script (@ (src ,(concat jfw/site-url "/static/js/guile-repl.js")) (defer "true")) "")
  "The Guile Scheme REPL, for pages that ask for it with #+SCRIPTS: repl.
It is a small interpreter in its own right, so only a page with a REPL
placed on it pays for downloading it.")

(defconst jfw/radar-scripts
  `(script (@ (src ,(concat jfw/site-url "/static/js/tech-radar.js")) (defer "true")) "")
  "The interactive tech radar, for pages that ask for #+SCRIPTS: radar.")

(defconst jfw/page-script-alist
  `(("repl" . ,jfw/repl-scripts)
    ("radar" . ,jfw/radar-scripts))
  "Maps the names used in #+SCRIPTS: to the script nodes they load.
Adding a page script means adding one entry here and asking for it from
the Org file, so no page ever downloads a script it does not use.")

(defun jfw/page-scripts (info)
  "Return the script nodes requested by the page's #+SCRIPTS: keyword.
Names are comma or space separated, and an unknown name is reported
during the build instead of silently doing nothing."
  (let* ((requested (plist-get info :scripts))
         (names (when (and requested (not (string-empty-p (string-trim requested))))
                  (split-string (string-trim requested) "[, ]+" t))))
    (delq nil (mapcar (lambda (name)
                        (or (cdr (assoc (downcase name) jfw/page-script-alist))
                            (progn (message "#+SCRIPTS: unknown script %s" name) nil)))
                      names))))

(org-link-set-parameters
 "yt"
 :follow
 (lambda (handle)
   (browse-url
    (concat "https://www.youtube.com/watch?v="
            handle)))
 :export
 (lambda (path desc backend channel)
   (when (eq backend 'html)
     (jfw/embed-video path))))

(defconst jfw/nav-links
  '(("/" . "Home")
    ("/blog/" . "Blog")
    ("/blog/articles/development/tech-radar/" . "Tech Radar")
    ("/joe-cv/" . "Joe's CV")
    ("/documentation/" . "Docs")
    ("/code-of-conduct/" . "Code of Conduct")
    ("/ai-policy/" . "AI Policy")
    ("https://codeberg.org/jjba23" . "Codeberg")
    ("https://www.linkedin.com/in/josepjba/" . "LinkedIn"))
  "The site navigation, in order: a site-relative path or an absolute URL,
paired with its label.")

(defconst jfw/nav-primary-paths
  '("/" "/blog/" "/blog/articles/development/tech-radar/"
    "/joe-cv/" "/documentation/")
  "The navigation entries that stay on the bar; the rest fold under `more'.
A bar that names five places is read; a bar that names nine is scanned.
The five are where a reader goes next, the four are where a reader goes
once — a policy, a source host, a professional profile — so they cost one
click behind a disclosure rather than a row of the bar on every page.")

(defun jfw/nav-groups ()
  "Return the navigation as (PRIMARY . SECONDARY), each in its own order.
Every entry appears in exactly one of the two lists, which is what keeps a
new link from silently going missing when it is added to the table."
  (let (primary secondary)
    (dolist (link jfw/nav-links)
      (if (member (car link) jfw/nav-primary-paths)
          (push link primary)
        (push link secondary)))
    (cons (nreverse primary) (nreverse secondary))))

(defun jfw/nav-current (current)
  "Return the nav href that best describes the page at CURRENT.
The longest site-relative link the page sits under wins, so an article
marks its own section instead of the whole of /blog/; a link to the root
only ever matches the root itself."
  (when current
    (let ((best nil))
      (dolist (link jfw/nav-links best)
        (let ((href (car link)))
          (when (and (string-prefix-p "/" href)
                     (or (string= href current)
                         (and (not (string= href "/"))
                              (string-prefix-p href current))))
            (when (or (null best) (> (length href) (length best)))
              (setq best href))))))))

(defun jfw/nav-items (current &optional links)
  "Return LINKS as sxml, marking the entry that matches CURRENT.
LINKS defaults to the whole navigation; the bar passes its own groups so
that the same marking rules apply on both sides of the `more' disclosure."
  (mapcar (lambda (link)
            (let ((href (car link))
                  (label (cdr link)))
              `(a (@ (class "nav-link")
                     (href ,href)
                     ,@(when (equal href current) '((aria-current "page"))))
                  ,label)))
          (or links jfw/nav-links)))

(defun jfw/theme-toggle ()
  "Return the light / dark / follow-the-system chooser as sxml.
The three radios are the real controls and their labels are the buttons, so
native keyboard behaviour and screen readers both work without a script;
the stylesheet shows the label of the chosen one and the icon of all three,
which is what keeps the bar to a single line."
  `(div (@ (class "theme-toggle")
           (role "radiogroup")
           (aria-label "Color theme")
           (data-jfw-theme-toggle "true"))
        ,@(cl-loop
           for (value icon title label) in '(("light" "☀️" "Light theme" "light")
                                             ("dark" "🌙" "Dark theme" "dark")
                                             ("system" "🖥️" "Follow the system theme" "system"))
           for checked = (equal value "system")
           append
           (list
            `(input (@ (class "theme-toggle-input")
                       (type "radio")
                       (name "jfw-theme")
                       (id ,(concat "jfw-theme-" value))
                       (value ,value)
                       ,@(when checked '((checked "checked")))))
            `(label (@ (class "theme-toggle-option")
                       (data-choice ,value)
                       (for ,(concat "jfw-theme-" value))
                       (title ,title))
                    (span (@ (class "theme-toggle-icon") (aria-hidden "true")) ,icon)
                    (span (@ (class "theme-toggle-label")) ,label))))))

(defun jfw/site-header (&optional current)
  "Return the shared site header as sxml.
CURRENT is the site-relative path of the page being published; the nav
entry the visitor is standing on is the one told `aria-current'.

One bar, three parts: where you are, where you can go, and how the site
looks. The wordmark is a link home rather than a decoration, the five
places a reader goes next stay on the bar, and the four they go once wait
behind a disclosure that opens with a real click because it is a real
`details' element."
  (let* ((groups (jfw/nav-groups))
         (primary (car groups))
         (secondary (cdr groups))
         (nav-current (jfw/nav-current current)))
    ;; A list, because the template splices the shared furniture into the
    ;; body: a bare node would be spliced apart into its own tag and
    ;; attributes.
    (list
     `(header (@ (class "site-header"))
              (div (@ (class "toolbelt"))
                   (a (@ (class "site-mark") (href "/"))
                      (span (@ (class "site-mark-glyph") (aria-hidden "true")) "λ")
                      (span (@ (class "site-mark-name")) "jointhefreeworld"))
                   (nav (@ (class "nav nav-primary") (aria-label "Site"))
                        ,@(jfw/nav-items nav-current primary))
                   ,@(when secondary
                       `((details (@ (class "nav-more") (data-jfw-nav-more "true"))
                                  (summary (@ (class "nav-more-summary")) "more")
                                  (div (@ (class "nav-more-panel"))
                                       (nav (@ (class "nav nav-secondary")
                                               (aria-label "More of the site"))
                                            ,@(jfw/nav-items nav-current secondary))))))
                   ,(jfw/theme-toggle))))))




(defun jfw/site-footer ()
  "Return the shared site footer as sxml.
Two columns on a wide screen, one on a phone: the left says what this is
and who made it, the right is the list of places that are about the site
rather than in it."
  `((footer (@ (class "site-footer"))
            (div (@ (class "footer-inner"))
                 (div (@ (class "footer-identity"))
                      (p (@ (class "footer-mark")) "jointhefreeworld")
                      (em "Copyright © Josep Bigorra (jjba23 - jjbigorra@gmail.com)")
                      (em "Licensed under the GNU AGPL v3 or newer")
                      (em ,(format "Site build: %s" (jfw/get-commit-hash))))
                 (div (@ (class "footer-links"))
                      (a (@ (href "https://codeberg.org/jjba23/jointhefreeworld"))
                         "🔗 source code on Codeberg")
                      (a (@ (href ,(string-join (list jfw/site-url "rss.xml") "/")))
                         "🗞️ RSS feed")
                      (a (@ (href "/blog/articles/development/tech-radar/"))
                         "🧭 the FREE stack tech radar")
                      (a (@ (href "/code-of-conduct/")) "🤝 code of conduct")
                      (a (@ (href "/ai-policy/")) "🤖 AI policy")
                      (a (@ (href "#top")) "⬆️ back to the top"))))))

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

(defvar jfw/commit-hash-cache nil
  "Cached short commit hash, so git is queried at most once per build.")

(defun jfw/get-commit-hash ()
  "Return the short hash of the latest commit, or \"unknown\".
The result is cached for the duration of the build, and a repository-free
or git-less environment degrades gracefully instead of aborting the
publish."
  (or jfw/commit-hash-cache
      (setq jfw/commit-hash-cache
            (condition-case nil
                (string-trim
                 (with-output-to-string
                   (with-current-buffer standard-output
                     (vc-git-command t nil nil "rev-parse" "--short" "HEAD"))))
              (error "unknown")))))

(defconst jfw/speculation-rules "
{
  \"prerender\": [
    {
      \"where\": {
        \"selector_matches\": \"a\"
      }
    }
  ]
}
"
  "Speculation Rules that let supporting browsers prerender followed links.")

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

;;; ---------------------------------------------------------------------
;;; Blog listings
;;; ---------------------------------------------------------------------
;; A list of articles is a copy of them, and a copy drifts: the index
;; pages used to carry one of their own, so an article was written into
;; two places, or into one and forgotten in the other.  The entries are
;; now written out of the articles themselves, and an index page only
;; says which listing it shows.

(defconst jfw/articles-directory "docs/blog/articles"
  "Directory of the blog article sources, one directory per category.")

(defconst jfw/highlight-keyword "HIGHLIGHT"
  "Keyword that puts an article on the blog's front page.
Its value is read as a yes unless `jfw/highlight-off' names it, so a
post can say why it is highlighted rather than only that it is.")

(defconst jfw/highlight-off '("no" "nil" "false" "0")
  "Values of #+HIGHLIGHT: that mean an article is not highlighted.")

(defconst jfw/listings '("highlighted" "category")
  "The listings an index page may ask for.
`highlighted' is the front page's selection, and `category' is every
article of the category the page itself belongs to.")

(defvar jfw/blog-articles-cache nil
  "What the listings show about every article, collected once per build.")

(defvar jfw/listing-entries-written 0)
(defvar jfw/listing-pages-written 0)

(defun jfw/org-keyword (file name)
  "Return the value of the #+NAME: keyword in FILE, or nil when it has none.
A keyword present without a value gives an empty string rather than nil,
so \"present\" and \"absent\" stay different answers.  The file is read as
text rather than parsed as Org: a keyword is metadata, and parsing a
whole document to find one buys nothing."
  (when (and file (file-exists-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (when (re-search-forward (format "^#\\+%s:[ \t]*\\(.*\\)$" (regexp-quote name)) nil t)
        (string-trim (match-string 1))))))

(defun jfw/article-files ()
  "Return the absolute file name of every published blog article.
An article is an Org file in a category directory; the category index
and anything else beside it is a page, not an article."
  (let ((root (expand-file-name jfw/articles-directory jfw/project-root))
        (files '()))
    (dolist (category (directory-files root t "\\`[^.]"))
      (when (file-directory-p category)
        (dolist (file (directory-files category t "\\.org\\'"))
          (unless (string= (file-name-nondirectory file) "index.org")
            (push file files)))))
    (sort files #'string<)))

(defun jfw/date-parts (date)
  "Return (YEAR MONTH DAY) as numbers, from an Org DATE value, or nil.
The date is read out of whatever surrounds it, so both a bare date and
the <date day> of a timestamp are understood."
  (when (and date (string-match "\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)" date))
    (list (string-to-number (match-string 1 date))
          (string-to-number (match-string 2 date))
          (string-to-number (match-string 3 date)))))

(defun jfw/date-sort-key (date)
  "Return an article's DATE as a number that sorts it, or nil.
Reading the digits rather than parsing a timestamp keeps an article with
an unreadable date out of the way instead of failing the build over it."
  (when-let* ((parts (jfw/date-parts date)))
    (string-to-number (format "%04d%02d%02d" (nth 0 parts) (nth 1 parts) (nth 2 parts)))))

(defun jfw/date-display (date)
  "Return an article's DATE the way an index page shows it.
The day name follows the build machine's locale, which is what Org does
with a timestamp in a paragraph, so a generated entry and a written one
read the same.  A date the build cannot read is passed through as it is."
  (when date
    (if-let* ((parts (jfw/date-parts date)))
        (format "%04d-%02d-%02d %s"
                (nth 0 parts) (nth 1 parts) (nth 2 parts)
                (format-time-string "%a" (encode-time 0 0 0 (nth 2 parts) (nth 1 parts) (nth 0 parts))))
      date)))

(defun jfw/article-metadata (file)
  "Return what a listing shows about the article in FILE, or nil.
A page that only forwards readers elsewhere is not an article: it is a
stub, and listing it would send them through a redirection."
  (unless (jfw/org-keyword file "redirect")
    (let* ((title (jfw/org-keyword file "title"))
           (date (jfw/org-keyword file "date"))
           (highlight (jfw/org-keyword file jfw/highlight-keyword))
           (category (file-name-nondirectory (directory-file-name (file-name-directory file)))))
      (list
       :file file
       :title (and title (jfw/plain-text title))
       :date date
       :date-key (jfw/date-sort-key date)
       :date-display (jfw/date-display date)
       :description (jfw/plain-text (jfw/org-keyword file "description"))
       :category category
       :url (jfw/file-page-path file)
       :highlight (and highlight (not (member (downcase highlight) jfw/highlight-off)))))))

(defun jfw/blog-articles ()
  "Return what the listings show about every blog article, newest first.
Two articles written on the same day are ordered by title, so that the
pages are the same on every build."
  (or jfw/blog-articles-cache
      (setq jfw/blog-articles-cache
            (sort (delq nil (mapcar #'jfw/article-metadata (jfw/article-files)))
                  (lambda (a b)
                    (let ((key-a (plist-get a :date-key))
                          (key-b (plist-get b :date-key)))
                      (cond
                       ((and key-a key-b (not (= key-a key-b))) (> key-a key-b))
                       ((and key-a (not key-b)) t)
                       ((and key-b (not key-a)) nil)
                       (t (string-lessp (or (plist-get a :title) "")
                                        (or (plist-get b :title) ""))))))))))

(defun jfw/listing-articles (kind path)
  "Return the articles that the listing KIND shows on the page at PATH.
A listing the build does not know is reported rather than guessed at,
which is how a typo in an index page is found."
  (pcase (downcase (or kind ""))
    ("highlighted" (cl-remove-if-not (lambda (article) (plist-get article :highlight))
                                     (jfw/blog-articles)))
    ("category" (when-let* ((category (jfw/section-slug path)))
                  (cl-remove-if-not (lambda (article) (equal (plist-get article :category) category))
                                    (jfw/blog-articles))))
    (_ (message "listing: %s asks for a listing this build does not know: %s"
                (or path "a page")
                (mapconcat #'identity jfw/listings " or "))
       nil)))

(defun jfw/listing-entry-html (article)
  "Return ARTICLE as the paragraph an index page shows it in.
The markup is the one Org writes for an entry somebody typed — a
timestamp span, a link and the summary — so a generated page reads like
the page it replaces."
  (concat
   "<p>\n"
   (when-let* ((date (plist-get article :date-display)))
     (format "<span class=\"timestamp-wrapper\"><span class=\"timestamp\">&lt;%s&gt; </span></span> "
             (jfw/escape-html date)))
   (format "<a href=\"%s\">%s</a>"
           (jfw/escape-html (plist-get article :url))
           (jfw/escape-html (or (plist-get article :title) "")))
   (let ((description (plist-get article :description)))
     (if (and description (not (string-empty-p description)))
         (format " - %s" (jfw/escape-html description))
       ""))
   "\n</p>\n"))

(defun jfw/listing-html (kind path)
  "Return the listing KIND as HTML for the page at PATH, or nil.
Nil means there is nothing to write, which is a fair answer for a
category nobody has written in yet."
  (when-let* ((articles (jfw/listing-articles kind path)))
    (cl-incf jfw/listing-pages-written)
    (cl-incf jfw/listing-entries-written (length articles))
    (mapconcat #'jfw/listing-entry-html articles "")))

(defun jfw/org-html-special-block (special-block contents info)
  "Export SPECIAL-BLOCK, or write a blog listing when it asks for one.
An index page declares which listing it shows:

  #+begin_listing highlighted
  #+end_listing

and the build fills it with the articles it finds, so the page cannot
list an article that no longer exists, nor forget one that does."
  (let ((type (org-element-property :type special-block)))
    (if (and type (string-equal (downcase type) "listing"))
        (or (jfw/listing-html (or (org-element-property :parameters special-block)
                                  (org-element-property :value special-block))
                              (jfw/page-path info))
            "")
      (org-html-special-block special-block contents info))))

(defun jfw/report-listings ()
  "Report what the listings found, once, at the end of a build."
  (let ((articles (jfw/blog-articles)))
    (message "blog listings: %d articles, %d highlighted, %d entries on %d pages"
             (length articles)
             (length (cl-remove-if-not (lambda (article) (plist-get article :highlight)) articles))
             jfw/listing-entries-written
             jfw/listing-pages-written)
    (dolist (article articles)
      (unless (plist-get article :date-key)
        (message "blog listing: %s has no readable #+DATE:, so it is listed last"
                 (file-name-nondirectory (plist-get article :file)))))))

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
     "\">Josep Bigorra (jjba23) · GNU AGPL v3 or newer</text>\n"
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

(defun jfw/json-ld-script (json)
  "Return JSON-LD JSON that is safe to inline inside a script element.
A literal < cannot end a script element on its own, but a title holding
\"</script>\" could, so every < becomes \\u003c: still valid JSON, and it
reads back as the same character once parsed."
  (when json
    (replace-regexp-in-string "<" "\\u003c" json t t)))

(cl-defun jfw/json-ld (&key title description url path index-p image
                          published modified keywords section)
  "Return a JSON-LD document describing the page, as a JSON string.
The graph names the site and its author on every page, then describes
the page itself — a BlogPosting with its dates for an article, a plain
WebPage anywhere else — and closes with a breadcrumb trail."
  (let* ((site (concat jfw/site-url "/"))
         (person `(("@type" . "Person")
                   ("@id" . ,(concat site "#person"))
                   ("name" . "Josep Bigorra")
                   ("alternateName" . "jjba23")
                   ("email" . "mailto:jjbigorra@gmail.com")
                   ("url" . ,site)
                   ("sameAs" . ("https://codeberg.org/jjba23"
                                "https://www.linkedin.com/in/josepjba/"
                                "https://www.youtube.com/channel/UCdIkk-5jPA2HaAEB5a5X6XA"))))
         (website `(("@type" . "WebSite")
                    ("@id" . ,(concat site "#website"))
                    ("url" . ,site)
                    ("name" . "jointhefreeworld")
                    ("description" . ,jfw/default-description)
                    ("inLanguage" . "en")
                    ("publisher" . (("@id" . ,(concat site "#person"))))))
         (image-node `(("@type" . "ImageObject")
                       ("url" . ,image)
                       ("width" . ,(string-to-number jfw/og-image-width))
                       ("height" . ,(string-to-number jfw/og-image-height))))
         (author-ref (list (cons "@id" (concat site "#person"))))
         (site-ref (list (cons "@id" (concat site "#website"))))
         (page-node
          (if (jfw/article-path-p path)
              (append
               `(("@type" . "BlogPosting")
                 ("@id" . ,(concat url "#article"))
                 ("headline" . ,title)
                 ("description" . ,description)
                 ("url" . ,url)
                 ("mainEntityOfPage" . (("@type" . "WebPage") ("@id" . ,url)))
                 ("image" . ,image-node)
                 ("inLanguage" . "en")
                 ("author" . ,author-ref)
                 ("publisher" . ,author-ref)
                 ("isPartOf" . ,site-ref))
               (when section (list (cons "articleSection" section)))
               (when published (list (cons "datePublished" published)))
               (when modified (list (cons "dateModified" modified)))
               (when keywords (list (cons "keywords" keywords))))
            `(("@type" . "WebPage")
              ("@id" . ,(concat url "#webpage"))
              ("url" . ,url)
              ("name" . ,title)
              ("description" . ,description)
              ("inLanguage" . "en")
              ("primaryImageOfPage" . ,image-node)
              ("isPartOf" . ,site-ref))))
         (breadcrumb
          `(("@type" . "BreadcrumbList")
            ("itemListElement"
             . ,(cl-loop for (label . step-url) in (jfw/breadcrumb-steps path title index-p)
                         for position from 1
                         collect (if step-url
                                     `(("@type" . "ListItem")
                                       ("position" . ,position)
                                       ("name" . ,label)
                                       ("item" . ,(jfw/absolute-url step-url)))
                                   `(("@type" . "ListItem")
                                     ("position" . ,position)
                                     ("name" . ,label))))))))
    (json-encode `(("@context" . "https://schema.org")
                   ("@graph" . ,(list website person page-node breadcrumb))))))

(cl-defun jfw/generate-page (title
                             content
                             info
                             &key
                             (publish-date)
                             (content-reading-time)
                             (exclude-content-reading-time)
                             (description)
                             (head-extra)
                             (pre-content)
                             (share-image)
                             (share-image-alt)
                             (exclude-header)
                             (exclude-footer))
  (let* ((path (jfw/page-path info))
         (index-p (jfw/page-index-p info))
         (redirect (plist-get info :redirect))
         ;; A page that forwards readers elsewhere claims the destination
         ;; as its canonical URL, so search engines consolidate both.
         (canonical (jfw/absolute-url (or redirect (plist-get info :canonical) path)))
         (description-text (jfw/page-description description content path))
         (plain-title (jfw/plain-text (or title "")))
         (iso-date (jfw/iso-date info))
         (modified (jfw/git-file-date (plist-get info :input-file)))
         (keywords (jfw/keyword-list info))
         (section (jfw/section-label path))
         (og-type (if (jfw/article-path-p path) "article" "website"))
         ;; A page's own #+OG_IMAGE: wins, then the card generated for it,
         ;; and only then the site-wide card.
         (share-card (jfw/absolute-url (or (plist-get info :og-image) share-image jfw/og-image)))
         (share-alt (or share-image-alt jfw/og-image-alt))
         (robots (or (plist-get info :robots)
                     (if redirect jfw/robots-stub jfw/robots-indexable)))
         (json-ld (jfw/json-ld :title plain-title :description description-text
                               :url canonical :path path :index-p index-p
                               :image share-card :published iso-date
                               :modified modified :keywords keywords :section section))
         ;; The rail is written here, from the page that is about to be
         ;; published, rather than by a script in the browser: it is content,
         ;; and content that needs a script to appear is content half the
         ;; readers do not get.
         (rail (jfw/page-rail content)))
    (concat
     "\n"
     "<!DOCTYPE html>"

     (thread-last
      (sxml-to-xml
       `(html (@ (lang "en"))             (head
                                           (meta (@ (charset "utf-8")))
                                           ;; Restored before paint to avoid a flash of the wrong theme;
                                           ;; the placeholder is swapped for real JavaScript below.
                                           (script "__THEME_INIT_PLACEHOLDER__")
                                           (meta (@ (name "author") (content "Josep Bigorra - jointhefreeworld")))
                                           (meta (@ (name "viewport")
                                                    (content "width=device-width, initial-scale=1, shrink-to-fit=no")))
                                           (meta (@ (name "description") (content ,description-text)))
                                           (meta (@ (name "robots") (content ,robots)))
                                           ;; The browser's own chrome, tinted to the paper.
                                           ,@(jfw/theme-color-metas)
                                           ,@(when keywords
                                               `((meta (@ (name "keywords")
                                                          (content ,(string-join keywords ", "))))))
                                           ;; The canonical link and og:url are the same string, so a
                                           ;; page never tells crawlers and card renderers different
                                           ;; stories about where it lives.
                                           (link (@ (rel "canonical") (href ,canonical)))
                                           ,@(when redirect
                                               `((meta (@ (http-equiv "refresh")
                                                          (content ,(concat "0; url=" redirect))))))
                                           (meta (@ (property "og:site_name") (content "jointhefreeworld")))
                                           (meta (@ (property "og:type") (content ,og-type)))
                                           (meta (@ (property "og:title") (content ,plain-title)))
                                           (meta (@ (property "og:description") (content ,description-text)))
                                           (meta (@ (property "og:url") (content ,canonical)))
                                           (meta (@ (property "og:locale") (content "en")))
                                           (meta (@ (property "og:image") (content ,share-card)))
                                           (meta (@ (property "og:image:secure_url") (content ,share-card)))
                                           (meta (@ (property "og:image:type") (content "image/png")))
                                           (meta (@ (property "og:image:width") (content ,jfw/og-image-width)))
                                           (meta (@ (property "og:image:height") (content ,jfw/og-image-height)))
                                           (meta (@ (property "og:image:alt") (content ,share-alt)))
                                           ,@(when (equal og-type "article")
                                               (append
						(when iso-date
                                                  `((meta (@ (property "article:published_time")
                                                             (content ,iso-date)))))
						(when modified
                                                  `((meta (@ (property "article:modified_time")
                                                             (content ,modified)))))
						`((meta (@ (property "article:author")
                                                           (content "Josep Bigorra"))))
						(when section
                                                  `((meta (@ (property "article:section")
                                                             (content ,section)))))
						(mapcar (lambda (tag)
                                                          `(meta (@ (property "article:tag")
                                                                    (content ,tag))))
							keywords)))
                                           (meta (@ (name "twitter:card") (content "summary_large_image")))
                                           (meta (@ (name "twitter:title") (content ,plain-title)))
                                           (meta (@ (name "twitter:description") (content ,description-text)))
                                           (meta (@ (name "twitter:image") (content ,share-card)))
                                           (meta (@ (name "twitter:image:alt") (content ,share-alt)))
                                           ;; Open the font connections early, then preload the faces that
                                           ;; are visible on first paint.
                                           (link (@ (rel "preconnect") (href "https://fonts.googleapis.com")))
                                           (link (@ (rel "preconnect")
                                                    (href "https://fonts.gstatic.com")
                                                    (crossorigin "anonymous")))
                                           ,@(jfw/font-preloads)
                                           (link (@ (rel "icon") (type "image/png") (href "/static/img/favicon.png")))
                                           (link (@ (rel "alternate")
                                                    (type "application/rss+xml")
                                                    (title "Jointhefreeworld News Feed")
                                                    (href "/rss.xml")))
                                           (script (@(type "speculationrules"))
                                                   "__SPECULATION_RULES_PLACEHOLDER__")              ;; Analytics is non-blocking: it loads in parallel with the page
                                           ;; and runs once the document has been parsed.
                                           (script (@ (src ,(concat jfw/site-url "/static/js/symbanta.js")) (defer "true")) "")
                                           (script (@ (src ,(concat jfw/site-url "/static/js/freeworld.js")) (defer "true")) "")
                                           (link (@ (rel "stylesheet")
                                                    (href ,(concat jfw/site-url "/static/css/jointhefreeworld.css"))))
                                           (link (@ (rel "stylesheet") (href ,jfw/google-fonts-url)))
                                           ,@(when head-extra head-extra)
                                           (title "__RAW_TITLE_PLACEHOLDER__ - jointhefreeworld")
                                           ;; The structured data travels through a placeholder because
                                           ;; sxml-to-xml would escape its quotes into oblivion.
                                           (script (@ (type "application/ld+json"))
                                                   "__JSON_LD_PLACEHOLDER__"))
              (body
               ;; The target of the footer's "back to the top" link. It
               ;; cannot be the header, because a sticky bar is always in
               ;; view and the browser then has nowhere to scroll to. This
               ;; anchor sits at the document origin and is out of flow, so
               ;; it takes no space on the page.
               (div (@ (class "jfw-top-anchor") (id "top") (aria-hidden "true")) "")
               ;; The two pieces of chrome the reader meets first. The skip
               ;; link is a real link, so it works with scripting off, and it
               ;; is the first thing Tab reaches. The progress line is drawn
               ;; from a custom property that freeworld.js writes, so with
               ;; scripting off it simply never grows.
               (a (@ (class "jfw-skip-link") (href "#content")) "skip to the content")
               ;; The empty string is the element's content, and it is what
               ;; makes the serialiser write a closing tag: without it the
               ;; progress line would be emitted as a lone opening tag and
               ;; every element after it would nest inside it.
               (div (@ (class "jfw-progress")
                       (data-jfw-progress "true")
                       (aria-hidden "true"))
                    "")
               ,@(unless exclude-header
                   ;; One bar: the wordmark, the nav, and the theme chooser.
                   (jfw/site-header (jfw/page-path info)))
               (main (@ (class "page"))
                     ;; The hero. A page says which part of the site it
                     ;; belongs to, what it is called and when it was
                     ;; written, before a single paragraph asks for the
                     ;; reader's attention.
                     (div (@ (class "page-hero"))
                          (p (@ (class "page-kicker")) ,(jfw/page-kicker path))
                          (h1 (@ (class "site-post-title"))
                              "__RAW_TITLE_PLACEHOLDER__")
                          ,@(jfw/page-meta publish-date iso-date
                                           (unless exclude-content-reading-time
                                             content-reading-time)))
                     ,(if-let* ((video-id (plist-get info :video)))
                          (jfw/embed-video video-id))
                     ,(when pre-content pre-content)
                     ;; The body: the sheet the article is printed on, and
                     ;; beside it the rail of the page's own headings, which
                     ;; the build wrote a moment ago. When the build found
                     ;; fewer than three headings there is no rail, and the
                     ;; grid is one column, so no page carries a gutter for
                     ;; nothing.
                     (div (@ (class ,(if rail "page-body has-rail" "page-body")))
                          ;; `tabindex' is -1 so that the skip link can move
                          ;; focus here: a reader who takes it lands at the
                          ;; top of the article and the next Tab continues
                          ;; inside it.
                          (div (@ (id "content") (class "content") (tabindex "-1"))
                               "__RAW_CONTENT_PLACEHOLDER__")
                          ,@rail))
               ,@(unless exclude-footer
                   (jfw/site-footer)))))

      ;; Pass the result sequentially through these string-replace calls
      (string-replace "__RAW_TITLE_PLACEHOLDER__" (or title ""))
      (string-replace "__SPECULATION_RULES_PLACEHOLDER__" (or jfw/speculation-rules ""))
      (string-replace "__THEME_INIT_PLACEHOLDER__" (or jfw/theme-init-script ""))
      (string-replace "__JSON_LD_PLACEHOLDER__" (or (jfw/json-ld-script json-ld) ""))
      (string-replace "__RAW_CONTENT_PLACEHOLDER__" (or content ""))))))

(defun estimate-reading-time (content)
  "Calculate the estimated reading time of CONTENT in whole minutes.
Always returns at least 1 so short pages never read as \"0 minutes\"."
  (let* ((word-list (split-string content "\\s-+" t)) ; Split by whitespace, remove empty strings
         (word-count (length word-list))
         (words-per-minute 130) ; Average reading speed
         (estimated-minutes (/ (float word-count) words-per-minute)))
    (max 1 (floor estimated-minutes))))

(defun is-exclude-content-reading-time-p (title)
  "Predicate that determines whether a page should show
estimated reading time based on its TITLE."
  (member title '("Joe's web-site 🌍 Join the Free World"
                  "Joe's Blog 📰"
                  "Docs 📑 - jointhefreeworld.org"
                  "Joe's Portfolio"
                  "Lisps" "Emacs" "Haskell" "GNU/Linux"
                  "Dev" "CI/CD" "Go" "FreeBSD" "Personal")))

(defun jfw/org-html-template (contents info)
  "Return the complete HTML document wrapping exported CONTENTS.
INFO is the original Org export communication channel."
  (let* ((page-title (car (plist-get info :title)))
         (path (jfw/page-path info))
         (plain-title (jfw/plain-text (org-export-data (plist-get info :title) info)))
         (label (or (plist-get info :og-label) (jfw/section-label path)))
         ;; An article's own card, generated while it is exported: the
         ;; title on the card is the title the page already carries, so
         ;; there is nothing extra to keep in step.
         (card (jfw/og-card path plain-title label)))
    (message (format "page title: %s" page-title))
    (jfw/generate-page (org-export-data (plist-get info :title) info)
                       contents
                       info
                       :publish-date (org-export-data (org-export-get-date info "%d/%m/%Y") info)
                       :description (org-export-data (plist-get info :description) info)
                       :content-reading-time (estimate-reading-time contents)
                       :exclude-content-reading-time (is-exclude-content-reading-time-p page-title)
                       :share-image card
                       :share-image-alt (when card
                                          (format "Sharing card: %s — %s on jointhefreeworld.org"
                                                  plain-title (or label "jointhefreeworld")))
                       ;; Pages ask for the scripts they use with #+SCRIPTS:,
                       ;; and download nothing else.
                       :head-extra (jfw/page-scripts info))))

(defun jfw/org-html-link (link contents info)
  "Removes file extension and changes the path into lowercase file:// links."
  (when (and (string= 'file (org-element-property :type link))
             (string= "org" (file-name-extension (org-element-property :path link))))
    (org-element-put-property link :path
                              (downcase
                               (file-name-sans-extension
                                (org-element-property :path link)))))

  (let ((exported-link (org-export-custom-protocol-maybe link contents 'html info))
        (img-style "style=\"\""))
    (cond
     (exported-link exported-link)
     ((or (string-match-p "jpg\\'" (org-element-property :raw-link link))
          (string-match-p "jpeg\\'" (org-element-property :raw-link link))
          (string-match-p "png\\'" (org-element-property :raw-link link))
          (string-match-p "webp\\'" (org-element-property :raw-link link)))
      (format "<img loading=\"lazy\" alt=\"%s\" %s src=\"%s\">"
              (if (stringp contents) (org-html-encode-plain-text contents) "")
              img-style
              (org-element-property :raw-link link)))
     ((equal contents nil)
      (format "<a href=\"%s\">%s</a>"
              (org-element-property :raw-link link)
              (org-element-property :raw-link link)))
     ((string-prefix-p "/" (org-element-property :raw-link link))
      (format "<a href=\"%s\">%s</a>"
              (org-element-property :raw-link link)
              contents))
     (t (org-export-with-backend 'html link contents info)))))

(defun jfw/make-heading-anchor-name (headline-text)
  (thread-last headline-text
               (downcase)
               (replace-regexp-in-string " " "-")
               (replace-regexp-in-string "[^[:alnum:]_-]" "")))

(defun jfw/org-html-headline (headline contents info)
  (let* ((text (org-export-data (org-element-property :title headline) info))
         (level (org-export-get-relative-level headline info))
         (level (min 7 (when level (1+ level))))
         ;; A heading may name its own anchor with :CUSTOM_ID:, which is the
         ;; only way to keep ids unique on a page that repeats a heading
         ;; (the radar's four rings under each of its six layers).
         (anchor-name (or (org-element-property :CUSTOM_ID headline)
                          (jfw/make-heading-anchor-name text)))
         (attributes (org-element-property :ATTR_HTML headline))
         (container (org-element-property :HTML_CONTAINER headline))
         (container-class (and container (org-element-property :HTML_CONTAINER_CLASS headline))))
    (when attributes
      (setq attributes
            (format " %s" (org-html--make-attribute-string
                           (org-export-read-attribute 'attr_html `(nil
                                                                   (attr_html ,(split-string attributes))))))))
    (concat
     (when (and container (not (string= "" container)))
       (format "<%s%s>" container (if container-class (format " class=\"%s\"" container-class) "")))
     (if (not (org-export-low-level-p headline info))
         (format "<h%d%s>%s&nbsp;<a id=\"%s\" class=\"anchor\" href=\"#%s\" aria-label=\"Link to this section\">#</a></h%d>%s"
                 level
                 (or attributes "")
                 text
                 anchor-name
                 anchor-name
                 level
                 (or contents ""))
       (concat
        (when (org-export-first-sibling-p headline info) "<ul>")
        (format "<li>%s%s</li>" text (or contents ""))
        (when (org-export-last-sibling-p headline info) "</ul>")))
     (when (and container (not (string= "" container)))
       (format "</%s>" (cl-subseq container 0 (cl-search " " container)))))))

(defun jfw/org-html-src-block (src-block _contents info)
  (let* ((lang (org-element-property :language src-block))
         (code (org-html-format-code src-block info)))
    (format "<pre>%s</pre>" (string-trim code))))


(org-export-define-derived-backend 'site-html 'html
                                   :translate-alist
                                   '((template . jfw/org-html-template)
                                     (link . jfw/org-html-link)
                                     (src-block . jfw/org-html-src-block)
                                     (special-block . jfw/org-html-special-block)
                                     (headline . jfw/org-html-headline))
                                   :options-alist
                                   '((:video "VIDEO" nil nil)
                                     (:scripts "SCRIPTS" nil nil)
                                     (:description "DESCRIPTION" nil nil)
                                     (:keywords "KEYWORDS" nil nil)
                                     ;; Per-page overrides for the metadata that
                                     ;; `jfw/generate-page' otherwise derives.
                                     (:canonical "CANONICAL" nil nil)
                                     (:robots "ROBOTS" nil nil)
                                     (:og-image "OG_IMAGE" nil nil)
                                     ;; A page whose category is not the word
                                     ;; that describes it names its own card
                                     ;; label here.
                                     (:og-label "OG_LABEL" nil nil)
                                     (:redirect "REDIRECT" nil nil)))

(defun jfw/org-html-publish-to-html (plist filename pub-dir)
  "Publish an org file to HTML under a pretty directory name.
Unlike the built-in `org-html-publish-to-html', this places non-index
pages in a lowercased directory derived from FILENAME, so every page
keeps a stable, human-readable URL.  It is intentionally named with a
`jfw/' prefix to avoid clobbering the built-in function."
  (let ((article-path (get-article-output-path filename pub-dir)))
    (cl-letf (((symbol-function 'org-export-output-file-name)
               (lambda (extension &optional subtreep pub-dir)
                 ;; The 404 page is a special case, it must be named "404.html"
                 (concat article-path
                         (if (string= (file-name-nondirectory filename) "404.org") "404" "index")
                         extension))))
      (org-publish-org-to 'site-html
                          filename
                          (concat "." (or (plist-get plist :html-extension)
                                          "html"))
                          plist
                          article-path))))

(setq org-publish-use-timestamps-flag t
      org-publish-timestamp-directory "./.org-cache/"
      org-export-with-section-numbers nil
      org-export-use-babel nil
      org-export-with-smart-quotes t
      org-export-with-sub-superscripts nil
      org-export-with-tags 'not-in-toc
      org-html-htmlize-output-type 'css
      org-html-prefer-user-labels t
      org-html-link-home jfw/site-url
      org-html-link-use-abs-url t
      org-html-link-org-files-as-html t
      org-html-html5-fancy t
      org-html-self-link-headlines t
      org-export-with-toc nil
      make-backup-files nil)

(defun jfw/format-live-stream-entry (entry style project)
  "Format posts with author and published data in the index page."
  (cond ((not (directory-name-p entry))
         (format "[[file:%s][%s]] - %s"
                 entry
                 (org-publish-find-title entry project)
                 (format-time-string "%B %d, %Y"
                                     (org-publish-find-date entry project))))
        ((eq style 'tree) (file-name-nondirectory (directory-file-name entry)))
        (t entry)))

(defun jfw/format-news-entry (entry style project)
  "Format posts with author and published data in the index page."
  (cond ((not (directory-name-p entry))
         (format "[[file:%s][%s]] - %s · %s"
                 entry
                 (org-publish-find-title entry project)
                 (car (org-publish-find-property entry :author project))
                 (format-time-string "%B %d, %Y"
                                     (org-publish-find-date entry project))))
        ((eq style 'tree) (file-name-nondirectory (directory-file-name entry)))
        (t entry)))

(defun jfw/news-sitemap (title files)
  (format "#+title: %s\n\n%s"
          title
          (mapconcat (lambda (file)
                       (format "- %s\n" file))
                     (cadr files)
                     "\n")))

(defun jfw/rss-extract-title (html-file)
  "Extract the title from an HTML file."
  (with-temp-buffer
    (insert-file-contents html-file)
    (let ((dom (libxml-parse-html-region (point-min) (point-max))))
      (dom-text (car (dom-by-class dom "site-post-title"))))))

(defun jfw/html-to-org-path (html-file)
  "Map an outputted HTML file path back to its original Org file path."
  (let* ((rel-path (file-relative-name html-file (expand-file-name "./public/")))
         (dir-path (file-name-directory rel-path)))
    (if dir-path
        (let* ((dir-no-slash (directory-file-name dir-path))
               (base-name (file-name-nondirectory dir-no-slash))
               (parent-dir (file-name-directory dir-no-slash)))
          ;; Reconstruct the path pointing to the ./docs/ directory
          (expand-file-name (concat base-name ".org")
                            (expand-file-name (or parent-dir "")
                                              (expand-file-name "./docs/"))))
      ;; Fallback if there is no directory nesting
      (expand-file-name (concat (file-name-sans-extension rel-path) ".org")
                        (expand-file-name "./docs/")))))

(defun jfw/extract-date-from-org (org-file)
  "Extract the #+date property from an ORG-FILE as a string."
  (when (file-exists-p org-file)
    (with-temp-buffer
      (insert-file-contents org-file)
      (goto-char (point-min))
      ;; Case-insensitive search for #+date:
      (when (re-search-forward "^#\\+[dD][aA][tT][eE]:[ \t]*\\(.*\\)" nil t)
        (string-trim (match-string 1))))))

(defun jfw/rss-extract-date (html-file)
  "Extract the post date directly from the source Org file."
  (let* ((org-file (jfw/html-to-org-path html-file))
         (date-string (jfw/extract-date-from-org org-file)))

    ;; Use regex to find YYYY-MM-DD, ignoring brackets and day names (English or Dutch)
    (if (and date-string (string-match "\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)" date-string))
        (let* ((year  (string-to-number (match-string 1 date-string)))
               (month (string-to-number (match-string 2 date-string)))
               (day   (string-to-number (match-string 3 date-string))))

          (message "------\nfile name: %s" org-file)
          (message "file date parsed: %04d-%02d-%02d" year month day)

          ;; Encode the time to UTC (t) at 23:00:00
          (encode-time 0 0 23 day month year t))

      ;; Epoch fallback for missing files
      (encode-time 0 0 0 1 1 1970 t))))


(setopt webfeeder-title-function #'jfw/rss-extract-title
        webfeeder-date-function #'jfw/rss-extract-date)

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

(defconst jfw/rss-exclusions
  '("news/index.html"
    ;; The policy pages moved out of the blog; these two only forward
    ;; readers to their new addresses, so they are not news.
    "blog/articles/personal/jointhefreeworld-code-of-conduct/index.html"
    "blog/articles/personal/jointhefreeworld-ai-policy/index.html")
  "Published blog files deliberately left out of the RSS feed.")

(defun jfw/publish ()
  "Publish the entire site, then rebuild the RSS feed.
The RSS step is reported but not fatal, so a single feed problem never
leaves the published HTML half-written."
  (interactive)
  (org-publish-all t)
  (jfw/report-listings)
  (jfw/report-og-cards)
  (condition-case err
      ;; Temporarily force Emacs to use the standard English/POSIX locale
      ;; so webfeeder generates RFC-compliant pubDates (e.g., "Sat", "May")
      (let ((system-time-locale "C"))
        (webfeeder-build "rss.xml"
                         "./public"
                         jfw/site-url
                         (let ((default-directory (expand-file-name "./public/")))
                           (cl-remove-if (lambda (file) (member file jfw/rss-exclusions))
                                         (directory-files-recursively "blog/articles"
                                                                      ".*\\.html$")))
                         :builder 'webfeeder-make-rss
                         :title "jointhefreeworld news"
                         :description "News and Insights from the jointhefreeworld and jjba23 projects!"
                         :author "Josep Bigorra"))
    (error (message "RSS feed build failed: %S" err))))

(provide 'jointhefreeworld-site)

;;; jointhefreeworld-site.el ends here
