;;; jointhefreeworld

;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

(define-module (maak)
  #:declarative? #t
  #:use-module (maak maak))

;; ====== Maak constants ======

;; The TCP port on which the development web server will listen.
(define http-port
  50011)

;; The absolute path to the directory where the main project files will be deployed.
(define deploy-dir
  "/srv/http/jointhefreeworld.org")

;; The Emacs Lisp script to run for indenting ELisp files.
(define emacs-lisp-indent-cmd
  '(progn (indent-region (point-min)
                         (point-max) nil)
          (untabify (point-min)
                    (point-max))
          (delete-trailing-whitespace)
          (save-buffer)))

(define hot-reload-file-types
  '(org el scm css))

;; ====== Maak tasks ======

(define* (build #:key ci?)
  "Build the project."
  (delete-file-recursively ".org-cache")
  (remkdir-p "./public")
  ;; CI goes through `#:env' rather than as a `CI=... ' prefix: `env' sets it
  ;; for the pinned shell itself, which is what makes it reach emacs inside it.
  (time-machine-manifest-shell
   (list "emacs" "-Q" "--batch" "-l" "./jointhefreeworld-site.el"
         "--funcall" "jfw/publish")
   #:env (list (~ "CI=~a" (if ci? "true" "false")))
   #:verbose? #t)
  (cp "./static" "./public/static")
  (cp "./static/robots.txt" "./public/robots.txt")
  (cp "./static/sitemap.xml" "./public/sitemap.xml"))

(define (fmt)
  "Format project source code files."
  (run (list "find" "." "-maxdepth" "8" "-name" "*.scm" "-type" "f"
             "-exec" "guix" "style" "-f" "{}" ";")
       #:verbose? #t)
  ;; The elisp pass works on absolute paths, which is what `find ~+' used to
  ;; ask the shell for; the indenting form reaches emacs as one word.
  (run (list "find" (getcwd) "-maxdepth" "8" "-name" "*.el" "-type" "f"
             "-exec" "emacs" "-Q" "--batch" "{}"
             "--eval" (~ "~s" emacs-lisp-indent-cmd) ";")
       #:verbose? #t))

(define (kill-server)
  "Kill any running HTTP server in the same port."
  ;; Nothing listens on a fresh machine, so a `fuser' that finds nothing is
  ;; not a failure of the task.
  (run (list "fuser" "-k" (~ "~a/tcp" http-port))
       #:allow-failure? #t))

(define (serve)
  "Run HTTP server serving the rendered production result of running."
  (kill-server)
  (run (list "darkhttpd" "./public" "--port" (~ "~a" http-port))))

(define (build-and-serve)
  (build #:ci? #f)
  (serve))

(define (hot-reload)
  "Hot-reloading developer's setup."
  (time-machine-manifest-shell (list "watchexec"
                                     "--clear"
                                     "--exts" (string-join
                                               (map symbol->string
                                                    hot-reload-file-types)
                                               ",")
                                     "--on-busy-update=restart"
                                     "--shell" "bash"
                                     "--watch" "."
                                     "--" "maak" "build-and-serve")))

(define (hr)
  "Alias to hot-reloading."
  (hot-reload))

(define (dev)
  "Developer's setup."
  (hot-reload))

(define (default)
  "Default task to be run, list available tasks."
  (list-tasks))

(define (lint-css)
  "Lint and fix the CSS sources."
  (run (list "stylelint" "--fix" "strict" "--config" ".stylelintrc.yml"
             "static/css/*.css")
       #:expand? #t))

(define (lint-elisp)
  "Load the build script in batch mode to catch load-time errors."
  (time-machine-manifest-shell (list "emacs"
                                "-Q"
                                "--batch"
                                "-l"
                                "./jointhefreeworld-site.el"
                                "--eval"
                                "(message \"jointhefreeworld-site.el loaded successfully\")")))

(define (lint)
  "Run every project linter."
  (lint-css)
  (lint-elisp))

(define (test)
  "Run the ERT test suite for the build script."
  ;; The tests load jointhefreeworld-site.el itself rather than a copy of its
  ;; rules, so a run also proves that the script still loads.  They run in
  ;; the same pinned environment as the build, which is what makes a failure
  ;; mean a defect rather than a missing package.
  (time-machine-manifest-shell (list "emacs"
                                     "-Q"
                                     "--batch"
                                     "-l"
                                     "./test/jointhefreeworld-site-test.el"
                                     "-f"
                                     "ert-run-tests-batch-and-exit")))

(define (check)
  "Run every check the project has: the linters, then the tests."
  (lint)
  (test))

(define (share-card)
  "Rasterise the social sharing card from its SVG source."
  ;; The SVG is the source of truth and the PNG is what social platforms
  ;; fetch, so the two are kept in step by regenerating rather than editing.
  ;; Both tools come from Guix: `guix shell inkscape pngquant -- maak
  ;; share-card`.
  (run (list "inkscape" "--export-type=png"
             "--export-width=1200" "--export-height=630"
             "--export-filename=/tmp/jfw-share-default.png"
             "static/img/share-default.svg"))
  (run (list "pngquant" "--quality=70-95" "--speed" "1" "--strip" "--force"
             "--output" "static/img/share-default.png"
             "/tmp/jfw-share-default.png")))

(define (deploy)
  "Deploy the project."
  (build #:ci? #t)
  (delete-file-recursively (~ "~a/index.html" deploy-dir))
  (delete-file-recursively (~ "~a/blog" deploy-dir))
  (delete-file-recursively (~ "~a/portfolio" deploy-dir))
  (delete-file-recursively (~ "~a/documentation/index.html" deploy-dir))
  ;; The social cards are generated from the articles that exist today, so
  ;; the directory goes the same way as the pages: a card for a deleted
  ;; article must not survive its article.
  (delete-file-recursively (~ "~a/og" deploy-dir))
  (cp "public/*" (~ "~a/" deploy-dir) #:expand? #t))
