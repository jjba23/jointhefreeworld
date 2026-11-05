;;; batch-indent.el --- Custom editor configuration for JOINTHEFREEWORLD.ORG -*- lexical-binding: t -*-

;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:

;; TODO


;;; Code:

(defun indent-file (&optional save)
  "Format the whole buffer."
  ;; (setq indent-tabs-mode nil)
  (indent-region (point-min) (point-max) nil)
  (untabify (point-min) (point-max))
  (delete-trailing-whitespace)
  (when save
    (save-buffer))
  ;; (princ (buffer-string))
  )

(defun indent-and-save ()
  (indent-file t))
