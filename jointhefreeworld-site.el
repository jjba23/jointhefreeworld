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

(defvar yt-iframe-format
  (concat "<div class=\"video\">"
          "  <iframe src=\"https://www.youtube.com/embed/%s\" allowfullscreen></iframe>"
          "</div>"))

(defun jfw/embed-video (video-id)
  (format yt-iframe-format video-id))

(setq user-full-name "Josep Bigorra")
(setq user-mail-address "jjbigorra@gmail.com")

(defvar jfw/site-url (if (string-equal (getenv "CI") "true")
                         "https://jointhefreeworld.org"
                       "http://localhost:50011")
  "The URL for the site being generated.")

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

(defun jfw/site-header ()
  (list
   `(div (@ (id "top")(class "site-title"))
         (a (@ (class "border-b-none")
               (href "https://jointhefreeworld.org"))(em "jointhefreeworld.org")))
   `(header (@ (class "site-header flex"))
            (div (@ (class "site-masthead"))
                 (div (@ (class "container"))
                      (details (@ (open "true")(class "nav-details"))
                               (summary "site navigation")
                               (nav (@ (class "nav"))
                                    (a (@ (class "nav-link") (href "/")) "Home") " "
                                    (a (@ (class "nav-link") (href "/blog/")) "Blog") " "
                                    (a (@ (class "nav-link") (href "/joe-cv/")) "Joe's CV") " "
                                    (a (@ (class "nav-link") (href "/documentation/")) "Documentation") " "
                                    (a (@ (class "nav-link") (href "https://codeberg.org/jjba23")) "Codeberg") " "
                                    (a (@ (class "nav-link") (href "https://www.linkedin.com/in/josepjba/")) "LinkedIn") " "
                                    )))))))



(defun jfw/site-footer ()
  `((footer (@ (class "site-footer"))
            (div (@ (class "container"))
                 (div (@ (class "flex flex-col gap-3"))
                      (em (@(class "text-sm")) "Copyright © Josep Bigorra (jjba23 - jjbigorra@gmail.com)")
                      (em (@(class "text-sm")) "Licensed under the GNU AGPL v3 or newer")
                      (div (@ (class "flex flex-row flex-wrap gap-3"))
                           (small
                            (a (@ (href "https://codeberg.org/jjba23/jointhefreeworld"))
                               "🔗 source code on Codeberg"))
                           (small
                            (a (@(href ,(string-join (list jfw/site-url "rss.xml") "/"))) "🗞️ RSS feed"))
                           (small
                            (a (@(href "#top")) "⬆️ back to the top"))
                           ))))))

(defun get-article-output-path (org-file pub-dir)
  (if (string-match-p "index\\.org$\\|404\\.org$" org-file)
      pub-dir
    (let ((article-dir (expand-file-name (downcase (file-name-base org-file)) pub-dir)))
      (unless (file-directory-p article-dir)
        (make-directory article-dir t))
      (file-name-as-directory article-dir))))

(defun jfw/get-commit-hash ()
  "Get the short hash of the latest commit in the current repository."
  (string-trim-right
   (with-output-to-string
     (with-current-buffer standard-output
       (vc-git-command t nil nil "rev-parse" "--short" "HEAD")))))

(cl-defun jfw/generate-page (title
                             content
                             info
                             &key
                             (publish-date)
                             (content-reading-time)
                             (exclude-content-reading-time)
                             (head-extra)
                             (pre-content)
                             (exclude-header)
                             (exclude-footer))
  (concat
   "\n"
   "<!DOCTYPE html>"

   (thread-last
     (sxml-to-xml
      `(html (@ (lang "en"))
             (head
              (meta (@ (charset "utf-8")))
              (meta (@ (author "Josep Bigorra - jointhefreeworld")))
              (meta (@ (name "viewport")
                       (content "width=device-width, initial-scale=1, shrink-to-fit=no")))
              (link (@ (rel "icon") (type "image/png") (href "/static/img/favicon.png")))
              (script (@(type "speculationrules"))
                      "
{
  \"prerender\": [
    {
      \"where\": {
        \"selector_matches\": \"a\"
      }
    }
  ]
}
")
              (link (@ (rel "stylesheet") (href ,(concat jfw/site-url "/static/css/jointhefreeworld.css"))))
              ,(when head-extra head-extra)
              (title "__RAW_TITLE_PLACEHOLDER__ - jointhefreeworld"))
             (body ,@(unless exclude-header
                       (jfw/site-header))
                   (div (@ (class "container flex flex-col items-center"))
                        (h1 (@ (class "site-post-title"))
                            "__RAW_TITLE_PLACEHOLDER__")
                        ,(when (and (not exclude-content-reading-time) content-reading-time (not (equal "" content-reading-time)))
                           `(em (@(class "site-post-meta")) ,(format "estimated reading time: %s minutes" content-reading-time)))
                        ,(when (and publish-date (not (equal "" publish-date)))
                           `(p (@ (class "site-post-meta")) ,(format "written on: %s" publish-date)))
                        ,(if-let ((video-id (plist-get info :video)))
                             (jfw/embed-video video-id))
                        ,(when pre-content pre-content)
                        (div (@ (id "content")(class "content max-w-full"))
                             "__RAW_CONTENT_PLACEHOLDER__"))
                   ,@(unless exclude-footer
                       (jfw/site-footer)))))

     ;; Pass the result sequentially through these string-replace calls
     (string-replace "__RAW_TITLE_PLACEHOLDER__" (or title ""))
     (string-replace "__RAW_CONTENT_PLACEHOLDER__" (or content "")))))

(defun estimate-reading-time (content)
  "Calculate the estimated reading time of CONTENT in minutes."
  (interactive)
  (let* ((word-list (split-string content "\\s-+" t)) ; Split by whitespace, remove empty strings
         (word-count (length word-list))
         (words-per-minute 180) ; Average reading speed
         (estimated-minutes (/ (float word-count) words-per-minute))
         (minutes (floor estimated-minutes)))
    minutes))

(defun is-exclude-content-reading-time-p (title)
  "Predicate that determines whether a page should show
estimated reading time based on its TITLE."
  (member title '("Joe's web-site - Join the Free World"
                  "Joe's Blog"
                  "Documentation - jointhefreeworld.org"
                  "Joe's Portfolio"
                  "Lisps" "Emacs" "Haskell" "GNU/Linux"
                  "Dev" "CI/CD" "Go" "FreeBSD" "Personal")))

(defun jfw/org-html-template (contents info)
  (let* ((page-title (car (plist-get info :title))))
    (message (format "page title: %s" page-title))
    (jfw/generate-page (org-export-data (plist-get info :title) info)
                       contents
                       info
                       :publish-date (org-export-data (org-export-get-date info "%d/%m/%Y") info)
                       :content-reading-time (estimate-reading-time contents)
                       :exclude-content-reading-time (is-exclude-content-reading-time-p page-title))))

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
      (format "<img loading=\"lazy\" %s src=\"%s\">"
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
         (anchor-name (jfw/make-heading-anchor-name text))
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
         (format "<h%d%s>%s&nbsp;<a id=\"%s\" class=\"anchor\" href=\"#%s\">#</a></h%d>%s"
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
                                     (headline . jfw/org-html-headline))
                                   :options-alist
                                   '((:video "VIDEO" nil nil)))

(defun org-html-publish-to-html (plist filename pub-dir)
  "Publish an org file to HTML, using the FILENAME as the output directory."
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
                                      :publishing-function org-html-publish-to-html
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
           ,@common-props))))

(defun jfw/publish ()
  "Publish the entire site."
  (interactive)
  (org-publish-all t)
  (ignore-errors
    ;; Temporarily force Emacs to use the standard English/POSIX locale
    ;; so webfeeder generates RFC-compliant pubDates (e.g., "Sat", "May")
    (let ((system-time-locale "C"))
      (webfeeder-build "rss.xml"
                       "./public"
                       jfw/site-url
                       (let ((default-directory (expand-file-name "./public/")))
                         (remove "news/index.html"
                                 (directory-files-recursively "blog/articles"
                                                              ".*\\.html$")))
                       :builder 'webfeeder-make-rss
                       :title "jointhefreeworld news"
                       :description "News and Insights from the jointhefreeworld and jjba23 projects!"
                       :author "Josep Bigorra"))))

(provide 'jointhefreeworld-site)

;;; jointhefreeworld-site.el ends here
