;;; jfw-ui.el --- jointhefreeworld build  -*- lexical-binding: t -*-

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
(require 'jfw-core)



(defconst jfw/nav-links
  '(("/" . "Home")
    ("/blog/" . "Blog")
    ("/blog/articles/development/tech-radar/" . "Tech Radar")
    ("/joe-cv/" . "Joe's CV")
    ("/documentation/" . "Docs")
    ("/code-of-conduct/" . "Code of Conduct")
    ("/ai-policy/" . "AI Policy")
    ("https://github.com/jjba23" . "GitHub")
    ("https://www.linkedin.com/in/josepjba/" . "LinkedIn"))
  "The site navigation, in order: a site-relative path or an absolute URL,
paired with its label.")

(defconst jfw/nav-primary-paths
  '("/" "/blog/" "/blog/articles/development/tech-radar/"
    "/joe-cv/" "/documentation/")
  "The navigation entries that stay on the bar; the rest fold under `more'.
A bar that names five places is read; a bar that names nine is scanned.
The five are where a reader goes next, the four are where a reader goes
once — a policy, a source host, a professional profile — so they cost one
click behind a disclosure rather than a row of the bar on every page.")

(defun jfw/nav-groups ()
  "Return the navigation as (PRIMARY . SECONDARY), each in its own order.
Every entry appears in exactly one of the two lists, which is what keeps a
new link from silently going missing when it is added to the table."
  (let (primary secondary)
    (dolist (link jfw/nav-links)
      (if (member (car link) jfw/nav-primary-paths)
          (push link primary)
        (push link secondary)))
    (cons (nreverse primary) (nreverse secondary))))

(defun jfw/nav-current (current)
  "Return the nav href that best describes the page at CURRENT.
The longest site-relative link the page sits under wins, so an article
marks its own section instead of the whole of /blog/; a link to the root
only ever matches the root itself."
  (when current
    (let ((best nil))
      (dolist (link jfw/nav-links best)
        (let ((href (car link)))
          (when (and (string-prefix-p "/" href)
                     (or (string= href current)
                         (and (not (string= href "/"))
                              (string-prefix-p href current))))
            (when (or (null best) (> (length href) (length best)))
              (setq best href))))))))

(defun jfw/nav-items (current &optional links)
  "Return LINKS as sxml, marking the entry that matches CURRENT.
LINKS defaults to the whole navigation; the bar passes its own groups so
that the same marking rules apply on both sides of the `more' disclosure."
  (mapcar (lambda (link)
            (let ((href (car link))
                  (label (cdr link)))
              `(a (@ (class "nav-link")
                     (href ,href)
                     ,@(when (equal href current) '((aria-current "page"))))
                  ,label)))
          (or links jfw/nav-links)))

(defun jfw/theme-toggle ()
  "Return the light / dark / follow-the-system chooser as sxml.
The three radios are the real controls and their labels are the buttons, so
native keyboard behaviour and screen readers both work without a script;
the stylesheet shows the label of the chosen one and the icon of all three,
which is what keeps the bar to a single line."
  `(div (@ (class "theme-toggle")
           (role "radiogroup")
           (aria-label "Color theme")
           (data-jfw-theme-toggle "true"))
        ,@(cl-loop
           for (value icon title label) in '(("light" "☀️" "Light theme" "light")
                                             ("dark" "🌙" "Dark theme" "dark")
                                             ("system" "🖥️" "Follow the system theme" "system"))
           for checked = (equal value "system")
           append
           (list
            `(input (@ (class "theme-toggle-input")
                       (type "radio")
                       (name "jfw-theme")
                       (id ,(concat "jfw-theme-" value))
                       (value ,value)
                       ,@(when checked '((checked "checked")))))
            `(label (@ (class "theme-toggle-option")
                       (data-choice ,value)
                       (for ,(concat "jfw-theme-" value))
                       (title ,title))
                    (span (@ (class "theme-toggle-icon") (aria-hidden "true")) ,icon)
                    (span (@ (class "theme-toggle-label")) ,label))))))

(defun jfw/site-header (&optional current)
  "Return the shared site header as sxml.
CURRENT is the site-relative path of the page being published; the nav
entry the visitor is standing on is the one told `aria-current'.

One bar, three parts: where you are, where you can go, and how the site
looks. The wordmark is a link home rather than a decoration, the five
places a reader goes next stay on the bar, and the four they go once wait
behind a disclosure that opens with a real click because it is a real
`details' element."
  (let* ((groups (jfw/nav-groups))
         (primary (car groups))
         (secondary (cdr groups))
         (nav-current (jfw/nav-current current)))
    ;; A list, because the template splices the shared furniture into the
    ;; body: a bare node would be spliced apart into its own tag and
    ;; attributes.
    (list
     `(header (@ (class "site-header"))
              (div (@ (class "toolbelt"))
                   (a (@ (class "site-mark") (href "/"))
                      (span (@ (class "site-mark-glyph") (aria-hidden "true")) "λ")
                      (span (@ (class "site-mark-name")) "jointhefreeworld"))
                   (nav (@ (class "nav nav-primary") (aria-label "Site"))
                        ,@(jfw/nav-items nav-current primary))
                   ,@(when secondary
                       `((details (@ (class "nav-more") (data-jfw-nav-more "true"))
                                  (summary (@ (class "nav-more-summary")) "more")
                                  (div (@ (class "nav-more-panel"))
                                       (nav (@ (class "nav nav-secondary")
                                               (aria-label "More of the site"))
                                            ,@(jfw/nav-items nav-current secondary))))))
                   ,(jfw/theme-toggle))))))




(defun jfw/site-footer ()
  "Return the shared site footer as sxml.
Two columns on a wide screen, one on a phone: the left says what this is
and who made it, the right is the list of places that are about the site
rather than in it."
  `((footer (@ (class "site-footer"))
            (div (@ (class "footer-inner"))
                 (div (@ (class "footer-identity"))
                      (p (@ (class "footer-mark")) "jointhefreeworld")
                      (em "Copyright © Josep Bigorra (jjba23 - jjbigorra@gmail.com)")
                      (em "Licensed under the GNU AGPL v3 or newer")
                      (em ,(format "Site build: %s" (jfw/get-commit-hash))))
                 (div (@ (class "footer-links"))
                      (a (@ (href "https://codeberg.org/jjba23/jointhefreeworld"))
                         "🔗 source code on Codeberg")
                      (a (@ (href ,(string-join (list jfw/site-url "rss.xml") "/")))
                         "🗞️ RSS feed")
                      (a (@ (href "/blog/articles/development/tech-radar/"))
                         "🧭 the FREE stack tech radar")
                      (a (@ (href "/code-of-conduct/")) "🤝 code of conduct")
                      (a (@ (href "/ai-policy/")) "🤖 AI policy")
                      (a (@ (href "#top")) "⬆️ back to the top"))))))

(provide 'jfw-ui)

;;; lisp/jfw-ui.el ends here
