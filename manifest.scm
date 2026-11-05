;;; jointhefreeworld

;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

(use-modules (guix packages)
             (gnu)
             (guix utils)
             (guix git-download)
             (guix download)
             (gnu packages admin)
             (gnu packages nss)
             (gnu packages gnupg)
             (gnu packages pkg-config)
             (gnu packages linux)
             (gnu packages compression)
             (gnu packages rust-apps)
             (gnu packages texinfo)
             (gnu packages autotools)
             (gnu packages web)
             (gnu packages emacs)
             (gnu packages fonts)
             (gnu packages gnome)
             ((guix licenses)
              #:prefix license:))

;; librsvg provides rsvg-convert, which draws the per-article social cards
;; from the SVG the export writes, and font-dejavu is what it draws the
;; text with: cards are generated inside this environment, so both fonts
;; and rasteriser have to be declared here rather than hoped for.
(packages->manifest (list texinfo darkhttpd watchexec emacs-no-x
                          librsvg font-dejavu))

