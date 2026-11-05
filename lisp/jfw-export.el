;;; jfw-export.el --- jointhefreeworld build  -*- lexical-binding: t -*-

;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:

;; Part of the site build.  The entry point is ./jointhefreeworld-site.el,
;; which installs the packages and requires this file after them; nothing
;; here is meant to be loaded on its own.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ox-html)
(require 'ox-publish)
(require 'vc-git)
(require 'esxml)
(require 'webfeeder)
(require 'jfw-core)
(require 'jfw-pages)
(require 'jfw-ui)
(require 'jfw-blog)
(require 'jfw-cards)
(require 'jfw-jsonld)
(require 'jfw-radar)



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
                                           ;; The faces the stylesheet declares are this site's own
                                           ;; files on its own asset host, so there is nothing to
                                           ;; preconnect to: the preloads below are the whole of what
                                           ;; the head asks for before the first paint.
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
                       ;; An article carries its neighbours and its related
                       ;; reading at the foot of its own prose. They are
                       ;; written here, from the catalogue the build already
                       ;; keeps, so they cannot point at a page that no
                       ;; longer exists.
                       (concat contents (or (jfw/article-chrome-html path) ""))
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
  "Export SRC-BLOCK with the button that copies it already in its corner.
The markup is written here rather than assembled by a script, so the button
is in the page a reader receives, works the moment the document is parsed,
and costs a visitor without scripting nothing but a line the stylesheet
keeps quiet.  The script that answers the click only has to read the block
beside the button.  An empty block gets no button, because there would be
nothing to copy."
  (let ((code (string-trim (org-html-format-code src-block info))))
    (if (string-empty-p code)
        "<pre></pre>"
      (concat "<div class=\"jfw-code\">"
              (format "<pre>%s</pre>" code)
              "<button type=\"button\" class=\"jfw-copy\""
              " aria-label=\"Copy this code block to the clipboard\""
              " title=\"Copy this code block to the clipboard\">copy</button>"
              "</div>"))))


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

(provide 'jfw-export)

;;; lisp/jfw-export.el ends here
