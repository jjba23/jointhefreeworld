;;; jointhefreeworld-site.el --- Build jointhefreeworld.org

;; Copyright (C) 2024 Josep Bigorra

;; Version: 0.1.1
;; Author: Josep Bigorra <jjbigorra@gmail.com>
;; Maintainer: Josep Bigorra <jjbigorra@gmail.com>
;; URL: https://codeberg.org/jjba23/jointhefreeworld
;; Package: emacs
;; Package-Requires: ((emacs "29.1"))

;; jointhefreeworld is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; jointhefreeworld is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
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
  (list `(header (@ (class "site-header"))
                 (div (@ (class "container"))
                      (div (@ (class "site-title"))
                           (em "jointhefreeworld.org")
                           ))
                 (div (@ (class "site-masthead"))
                      (div (@ (class "container"))
                           (nav (@ (class "nav"))
                                (a (@ (class "nav-link") (href "/")) "Home") " "
                                (a (@ (class "nav-link") (href "/blog/")) "Blog") " "
                                (a (@ (class "nav-link") (href "/portfolio/")) "Portfolio") " "
                                (a (@ (class "nav-link") (href "/cv/")) "CV/Resume") " "
                                (a (@ (class "nav-link") (href "https://codeberg.org/jjba23")) "Codeberg") " "
                                (a (@ (class "nav-link") (href "/manuals/")) "Manuals") " "
                                (a (@ (class "nav-link") (href "https://www.linkedin.com/in/josepjba/")) "LinkedIn") " "
                                (a (@ (class "nav-link") (href "https://wikimusic.jointhefreeworld.org")) "WikiMusic") " "
                                (a (@ (class "nav-link") (href "https://casadelcata.es")) "Casa del Cata") " "
                                ))))))



(defun jfw/site-footer ()
  (list
   `(hr)
   `(footer (@ (class "site-footer"))
            (div (@ (class "container"))
                 (div (@ (class "row"))
                      (div (@ (class "column"))
                           (p "© 2024 jointhefreeworld"))
                      (small "Licensed under the GNU GPL v3 or newer")
                      (div (@ (class "column align-right"))
                           (p
                            (a (@ (href "https://codeberg.org/jjba23/jointhefreeworld"))
                               (img (@ (src ,(concat jfw/site-url "/img/github.png"))
                                       (style "width: 120px")
                                       (alt "View the code on Codeberg")))))
                           (p
                            (a (@(href ,(string-join (list jfw/site-url "rss.xml") "/"))) "RSS"))))))))

(defun get-article-output-path (org-file pub-dir)
  (let ((article-dir (concat pub-dir
                             (downcase
                              (file-name-as-directory
                               (file-name-sans-extension
                                (file-name-nondirectory org-file)))))))

    (if (string-match "\\/index.org\\|\\/404.org$" org-file)
        pub-dir
      (progn
        (unless (file-directory-p article-dir)
          (make-directory article-dir t))
        article-dir))))

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
                             (head-extra)
                             (pre-content)
                             (exclude-header)
                             (exclude-footer))
  (concat
   "<!-- Generated from " (jfw/get-commit-hash)  " on " (format-time-string "%Y-%m-%d @ %H:%M") " with " org-export-creator-string " -->\n"
   "<!DOCTYPE html>"
   (sxml-to-xml
    `(html (@ (lang "en"))
           (head
            (meta (@ (charset "utf-8")))
            (meta (@ (author "Josep Bigorra - jointhefreeworld")))
            (meta (@ (name "viewport")
                     (content "width=device-width, initial-scale=1, shrink-to-fit=no")))
            (link (@ (rel "icon") (type "image/png") (href "/static/img/favicon.png")))
            ;; (link (@ (rel "alternative")
            ;;          (type "application/rss+xml")
            ;;          (title "jointhefreeworld news")
            ;;          (href ,(concat jfw/site-url "/rss/news.xml"))))
            
            (link (@ (rel "stylesheet") (href ,(concat jfw/site-url "/static/css/jointhefreeworld.css"))))
            
            ,(when head-extra head-extra)
            (title ,(concat title " - jointhefreeworld")))
           (body ,@(unless exclude-header
                     (jfw/site-header))
                 (div (@ (class "container flex justify-center"))
                      (div (@ (class "site-post"))
                           (h1 (@ (class "site-post-title"))
                               ,title)
                           ,(when publish-date
                              `(p (@ (class "site-post-meta")) ,publish-date))
                           ,(if-let ((video-id (plist-get info :video)))
                                (jfw/embed-video video-id))
                           ,(when pre-content pre-content)
                           (div (@ (id "content"))
                                ,content))
                      
                      )
                 ,@(unless exclude-footer
                     (jfw/site-footer)))))))

(defun jfw/org-html-template (contents info)
  (jfw/generate-page (org-export-data (plist-get info :title) info)
                    contents
                    info
                    :publish-date (org-export-data (org-export-get-date info "%B %e, %Y") info)))

(defun jfw/org-html-link (link contents info)
  "Removes file extension and changes the path into lowercase file:// links."
  (when (and (string= 'file (org-element-property :type link))
             (string= "org" (file-name-extension (org-element-property :path link))))
    (org-element-put-property link :path
                              (downcase
                               (file-name-sans-extension
                                (org-element-property :path link)))))

  (let ((exported-link (org-export-custom-protocol-maybe link contents 'html info)))
    (cond
     (exported-link exported-link)
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
         (format "<h%d%s><a id=\"%s\" class=\"anchor\" href=\"#%s\">#</a>&nbsp;%s</h%d>%s"
                 level
                 (or attributes "")
                 anchor-name
                 anchor-name
                 text
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

(defun jfw/org-html-special-block (special-block contents info)
  "Transcode a SPECIAL-BLOCK element from Org to HTML.
CONTENTS holds the contents of the block.  INFO is a plist
holding contextual information."
  (let* ((block-type (org-element-property :type special-block))
         (attributes (org-export-read-attribute :attr_html special-block)))
    (format "<div class=\"%s center\">\n%s\n</div>"
            block-type
            (or contents
                (if (string= block-type "cta")
                    "If you find this guide helpful, please consider supporting us via the links on the <a href=\"/how-to-help/#support-my-work\">How to Help</a> page!"
                  "")))))

(org-export-define-derived-backend 'site-html 'html
                                   :translate-alist
                                   '((template . jfw/org-html-template)
                                     (link . jfw/org-html-link)
                                     (src-block . jfw/org-html-src-block)
                                     (special-block . jfw/org-html-special-block)
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

(defun jfw/publish-newsletter-page (plist filename pub-dir)
  "Publish a newsletter .txt file to a simple HTML page."
  (let* ((issue-name (file-name-sans-extension
                      (file-name-nondirectory filename)))
         (output-file (expand-file-name
                       (concat issue-name ".html")
                       pub-dir))
         (contents (with-temp-buffer
                     (insert-file-contents filename)
                     (buffer-string))))
    (with-temp-file output-file
      (insert
       (jfw/generate-page
        (concat "Issue "
                (nth 2 (split-string issue-name "-")))
        (format "<pre class=\"newsletter-text\">%s</pre>"
                (replace-regexp-in-string
                 "\\(http\\|https\\)://[^ \t\n\r<>\"']*[^ \t\n\r<>\".,;!?']"
                 (lambda (match)
                   (format "<a href=\"%s\">%s</a>" match match))
                 contents))
        '()
        :exclude-header t
        :exclude-footer t)))))

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

(defun jfw/rss-extract-date (html-file)
  "Extract the post date from an HTML file."
  (with-temp-buffer
    (insert-file-contents html-file)
    (let* ((dom (libxml-parse-html-region (point-min) (point-max)))
           (date-string (dom-text (car (dom-by-class dom "site-post-meta"))))
           (parsed-date (parse-time-string date-string))
           (day (nth 3 parsed-date))
           (month (nth 4 parsed-date))
           (year (nth 5 parsed-date)))
      ;; NOTE: Hardcoding this at 8am for now
      (encode-time 0 0 8 day month year))))


(setq webfeeder-title-function #'jfw/rss-extract-title)
;; webfeeder-date-function #'jfw/rss-extract-date)

(setq org-publish-project-alist
      (list '("jointhefreeworld:main"
              :base-directory "./docs/home"
              :base-extension "org"
              :publishing-directory "./public"
              :publishing-function org-html-publish-to-html
              :with-title t
              :recursive t
              :with-timestamps t)
            '("jointhefreeworld:blog"
              :base-directory "./docs/blog/"
              :base-extension "org"
              :publishing-directory "./public/blog"
              :publishing-function org-html-publish-to-html
              :with-title t
              :recursive t
              :with-timestamps t)
            '("jointhefreeworld:manuals"
              :base-directory "./docs/manuals/"
              :base-extension "org"
              :publishing-directory "./public/manuals"
              :publishing-function org-html-publish-to-html
              :with-title t
              :recursive t
              :with-timestamps t)
            '("jointhefreeworld:portfolio"
              :base-directory "./docs/portfolio/"
              :base-extension "org"
              :publishing-directory "./public/portfolio"
              :publishing-function org-html-publish-to-html
              :with-title t
              :recursive t
              :with-timestamps t)))

(defun jfw/publish ()
  "Publish the entire site."
  (interactive)
  (org-publish-all t)
  (webfeeder-build "rss.xml"
                   "./public"
                   jfw/site-url
                   (let ((default-directory (expand-file-name "./public/")))
                     (remove "news/index.html"
                             (directory-files-recursively "blog/articles"
                                                          ".*\\.html$")))
                   :builder 'webfeeder-make-rss
                   :title "Jointhefreeworld News"
                   :description "News and Insights from the Jointhefreeworld project!"
                   :author "Josep Bigorra")
  )




(provide 'jointhefreeworld-site)
;;; jointhefreeworld-site.el ends here
