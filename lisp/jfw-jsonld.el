;;; jfw-jsonld.el --- jointhefreeworld build  -*- lexical-binding: t -*-

;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:

;; Part of the site build.  The entry point is ./jointhefreeworld-site.el,
;; which installs the packages and requires this file after them; nothing
;; here is meant to be loaded on its own.

;;; Code:

(require 'json)
(require 'jfw-core)
(require 'jfw-pages)



(defun jfw/json-ld-script (json)
  "Return JSON-LD JSON that is safe to inline inside a script element.
A literal < cannot end a script element on its own, but a title holding
\"</script>\" could, so every < becomes \\u003c: still valid JSON, and it
reads back as the same character once parsed."
  (when json
    (replace-regexp-in-string "<" "\\u003c" json t t)))

(cl-defun jfw/json-ld (&key title description url path index-p image
                          published modified keywords section)
  "Return a JSON-LD document describing the page, as a JSON string.
The graph names the site and its author on every page, then describes
the page itself — a BlogPosting with its dates for an article, a plain
WebPage anywhere else — and closes with a breadcrumb trail."
  (let* ((site (concat jfw/site-url "/"))
         (person `(("@type" . "Person")
                   ("@id" . ,(concat site "#person"))
                   ("name" . "Josep Bigorra")
                   ("alternateName" . "jjba23")
                   ("email" . "mailto:jjbigorra@gmail.com")
                   ("url" . ,site)
                   ("sameAs" . ("https://codeberg.org/jjba23"
                                "https://www.linkedin.com/in/josepjba/"
                                "https://www.youtube.com/channel/UCdIkk-5jPA2HaAEB5a5X6XA"))))
         (website `(("@type" . "WebSite")
                    ("@id" . ,(concat site "#website"))
                    ("url" . ,site)
                    ("name" . "jointhefreeworld")
                    ("description" . ,jfw/default-description)
                    ("inLanguage" . "en")
                    ("publisher" . (("@id" . ,(concat site "#person"))))))
         (image-node `(("@type" . "ImageObject")
                       ("url" . ,image)
                       ("width" . ,(string-to-number jfw/og-image-width))
                       ("height" . ,(string-to-number jfw/og-image-height))))
         (author-ref (list (cons "@id" (concat site "#person"))))
         (site-ref (list (cons "@id" (concat site "#website"))))
         (page-node
          (if (jfw/article-path-p path)
              (append
               `(("@type" . "BlogPosting")
                 ("@id" . ,(concat url "#article"))
                 ("headline" . ,title)
                 ("description" . ,description)
                 ("url" . ,url)
                 ("mainEntityOfPage" . (("@type" . "WebPage") ("@id" . ,url)))
                 ("image" . ,image-node)
                 ("inLanguage" . "en")
                 ("author" . ,author-ref)
                 ("publisher" . ,author-ref)
                 ("isPartOf" . ,site-ref))
               (when section (list (cons "articleSection" section)))
               (when published (list (cons "datePublished" published)))
               (when modified (list (cons "dateModified" modified)))
               (when keywords (list (cons "keywords" keywords))))
            `(("@type" . "WebPage")
              ("@id" . ,(concat url "#webpage"))
              ("url" . ,url)
              ("name" . ,title)
              ("description" . ,description)
              ("inLanguage" . "en")
              ("primaryImageOfPage" . ,image-node)
              ("isPartOf" . ,site-ref))))
         (breadcrumb
          `(("@type" . "BreadcrumbList")
            ("itemListElement"
             . ,(cl-loop for (label . step-url) in (jfw/breadcrumb-steps path title index-p)
                         for position from 1
                         collect (if step-url
                                     `(("@type" . "ListItem")
                                       ("position" . ,position)
                                       ("name" . ,label)
                                       ("item" . ,(jfw/absolute-url step-url)))
                                   `(("@type" . "ListItem")
                                     ("position" . ,position)
                                     ("name" . ,label))))))))
    (json-encode `(("@context" . "https://schema.org")
                   ("@graph" . ,(list website person page-node breadcrumb))))))

(provide 'jfw-jsonld)

;;; lisp/jfw-jsonld.el ends here
