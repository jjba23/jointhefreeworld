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

;; This file is the entry point and nothing else: it installs the packages
;; the build needs, puts ./lisp on the load path, and loads the modules.
;; Each module owns one concern, and each documents itself:
;;
;;   jfw-core    the constants, the fonts, the theme and the page scripts
;;   jfw-pages   text, URLs, the rail, dates and the breadcrumbs
;;   jfw-ui      the navigation, the header and the footer
;;   jfw-blog    the articles, the listings and the blog's own pages
;;   jfw-radar   the tech radar, drawn from the article when it is exported
;;   jfw-cards   the social cards, composed and rasterised at build time
;;   jfw-jsonld  the structured data every page carries
;;   jfw-export  the exporter: template, backend, feed and publish entry
;;
;; Usage:
;; emacs -Q --batch -l ./jointhefreeworld-site.el --funcall jfw/publish
;;
;; or
;;
;; make publish
;;
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

(defconst jfw/project-root
  (file-name-as-directory
   (file-name-directory
    (or load-file-name buffer-file-name (expand-file-name "jointhefreeworld-site.el"))))
  "Absolute directory holding this build script and the project it builds.
Resolved once, while this file loads: during an export `default-directory'
is the directory of whichever Org file is being published, so it cannot
be used to find the project's own manifests, sources or output.  It is
defined here, in the entry point, because every module is found relative
to it.")

;;; The modules.

(add-to-list 'load-path jfw/project-root)
(add-to-list 'load-path (expand-file-name "lisp" jfw/project-root))

(require 'jfw-core)
(require 'jfw-pages)
(require 'jfw-ui)
(require 'jfw-blog)
(require 'jfw-radar)
(require 'jfw-cards)
(require 'jfw-jsonld)
(require 'jfw-export)

(provide 'jointhefreeworld-site)

;;; jointhefreeworld-site.el ends here
