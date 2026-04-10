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
             ((guix licenses)
              #:prefix license:))

(packages->manifest (list texinfo darkhttpd watchexec emacs-no-x))

