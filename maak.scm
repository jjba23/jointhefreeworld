;;; jointhefreeworld

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
  ($ (list (format #f "CI=~a"
                   (if ci? "true" "false"))
;;           "LC_ALL=en_US.UTF8"
           "guix time-machine --channels=channels.scm --"
           "shell -m manifest.scm --"
           "emacs -Q --batch -l ./jointhefreeworld-site.el"
           "--funcall jfw/publish")
     #:verbose? #t)
  ($ '("cp -Rfv ./static ./public/static"))
  ($ '("cp -Rfv ./static/robots.txt ./public/robots.txt"))
  ($ '("cp -Rfv ./static/sitemap.xml ./public/sitemap.xml")))

(define (fmt)
  "Format project source code files."
  ($ '("find . -maxdepth 8 -name '*.scm'" "-type f -exec guix style -f {} \\;")
     #:verbose? #t)
  ($ (list "find ~+ -maxdepth 8 -name '*.el'"
           "-type f -exec emacs -Q --batch {} "
           (~ "--eval '~s'" emacs-lisp-indent-cmd) "\\;")
     #:verbose? #t))

(define (kill-server)
  "Kill any running HTTP server in the same port."
  ($ (list (~ "fuser -k ~a/tcp || true" http-port))))

(define (serve)
  "Run HTTP server serving the rendered production result of running."
  (kill-server)
  ($ (list (~ "darkhttpd ./public --port ~a" http-port))))

(define (build-and-serve)
  (build #:ci? #f)
  (serve))

(define (hot-reload)
  "Hot-reloading developer's setup."
  (time-machine-manifest-shell (list "watchexec"
                                     "--clear"
                                     (~ "--exts ~a"
                                        (string-join (map symbol->string
                                                      hot-reload-file-types)
                                                     ","))
                                     "--on-busy-update=restart"
                                     "--shell bash"
                                     "--watch . --"
                                     "maak build-and-serve")))

(define (hr)
  "Alias to hot-reloading."
  (hot-reload))

(define (dev)
  "Developer's setup."
  (hot-reload))

(define (default)
  "Default task to be run, list available tasks."
  ($ '("maak --list")))

(define (lint-css)
  ($ '("stylelint --fix strict --config .stylelintrc.yml" "static/css/*.css")))

(define (deploy)
  "Deploy the project."
  (build #:ci? #t)
  (delete-file-recursively (~ "~a/index.html" deploy-dir))
  (delete-file-recursively (~ "~a/blog" deploy-dir))
  (delete-file-recursively (~ "~a/portfolio" deploy-dir))
  (delete-file-recursively (~ "~a/documentation/index.html" deploy-dir))
  ($ (list "cp -rfv public/*"
           (~ "~a/" deploy-dir))))
