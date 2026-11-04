;;; jfw-core.el --- jointhefreeworld build  -*- lexical-binding: t -*-

;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; This file is part of jointhefreeworld, free software under the GNU
;; Affero General Public License v3 or newer.  See COPYING.

;;; Commentary:

;; Part of the site build.  The entry point is ./jointhefreeworld-site.el,
;; which installs the packages and requires this file after them; nothing
;; here is meant to be loaded on its own.

;;; Code:

(require 'cl-lib)
(require 'subr-x)



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
  '("work-sans-normal-latin.woff2"  ; Work Sans, the face body copy is set in
    "work-sans-italic-latin.woff2"  ; and its italic, used above the fold
    "juliamono-normal-latin.woff2") ; JuliaMono, for a command or a file name
  "Self-hosted font files used on first paint, preloaded to avoid a late swap.")

(defun jfw/font-preloads ()
  "Return preload link nodes for the critical font files.
Fonts are always fetched in CORS mode, so each preload requests them
anonymously; without ``crossorigin'' the preload would not match the
stylesheet's own request and the font would be fetched twice."
  (mapcar (lambda (file)
            `(link (@ (rel "preload")
                      (as "font")
                      (type "font/woff2")
                      (crossorigin "anonymous")
                      (href ,(concat jfw/font-assets-url "/" file)))))
          jfw/critical-fonts))

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

(defconst jfw/page-script-alist
  `(("repl" . ,jfw/repl-scripts))
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

(provide 'jfw-core)

;;; lisp/jfw-core.el ends here
