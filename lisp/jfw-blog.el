;;; jfw-blog.el --- jointhefreeworld build  -*- lexical-binding: t -*-

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
(require 'jfw-pages)



;;; ---------------------------------------------------------------------
;;; Blog listings
;;; ---------------------------------------------------------------------
;; A list of articles is a copy of them, and a copy drifts: the index
;; pages used to carry one of their own, so an article was written into
;; two places, or into one and forgotten in the other.  The entries are
;; now written out of the articles themselves, and an index page only
;; says which listing it shows.

(defconst jfw/articles-directory "docs/blog/articles"
  "Directory of the blog article sources, one directory per category.")

(defconst jfw/highlight-keyword "HIGHLIGHT"
  "Keyword that puts an article on the blog's front page.
Its value is read as a yes unless `jfw/highlight-off' names it, so a
post can say why it is highlighted rather than only that it is.")

(defconst jfw/highlight-off '("no" "nil" "false" "0")
  "Values of #+HIGHLIGHT: that mean an article is not highlighted.")

(defconst jfw/listings '("highlighted" "category" "archive" "keywords")
  "The listings an index page may ask for.
`highlighted' is the front page's selection, `category' is every article of
the category the page itself belongs to, `archive' is every article grouped
by the year it was written, and `keywords' is the index of every keyword the
articles carry, each with the articles that name it.")

(defvar jfw/blog-articles-cache nil
  "What the listings show about every article, collected once per build.")

(defvar jfw/listing-entries-written 0)
(defvar jfw/listing-pages-written 0)

(defun jfw/org-keyword (file name)
  "Return the value of the #+NAME: keyword in FILE, or nil when it has none.
A keyword present without a value gives an empty string rather than nil,
so \"present\" and \"absent\" stay different answers.  The file is read as
text rather than parsed as Org: a keyword is metadata, and parsing a
whole document to find one buys nothing."
  (when (and file (file-exists-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (when (re-search-forward (format "^#\\+%s:[ \t]*\\(.*\\)$" (regexp-quote name)) nil t)
        (string-trim (match-string 1))))))

(defun jfw/article-files ()
  "Return the absolute file name of every published blog article.
An article is an Org file in a category directory; the category index
and anything else beside it is a page, not an article."
  (let ((root (expand-file-name jfw/articles-directory jfw/project-root))
        (files '()))
    (dolist (category (directory-files root t "\\`[^.]"))
      (when (file-directory-p category)
        (dolist (file (directory-files category t "\\.org\\'"))
          (unless (string= (file-name-nondirectory file) "index.org")
            (push file files)))))
    (sort files #'string<)))

(defun jfw/date-parts (date)
  "Return (YEAR MONTH DAY) as numbers, from an Org DATE value, or nil.
The date is read out of whatever surrounds it, so both a bare date and
the <date day> of a timestamp are understood."
  (when (and date (string-match "\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)" date))
    (list (string-to-number (match-string 1 date))
          (string-to-number (match-string 2 date))
          (string-to-number (match-string 3 date)))))

(defun jfw/date-sort-key (date)
  "Return an article's DATE as a number that sorts it, or nil.
Reading the digits rather than parsing a timestamp keeps an article with
an unreadable date out of the way instead of failing the build over it."
  (when-let* ((parts (jfw/date-parts date)))
    (string-to-number (format "%04d%02d%02d" (nth 0 parts) (nth 1 parts) (nth 2 parts)))))

(defun jfw/date-display (date)
  "Return an article's DATE the way an index page shows it.
The day name follows the build machine's locale, which is what Org does
with a timestamp in a paragraph, so a generated entry and a written one
read the same.  A date the build cannot read is passed through as it is."
  (when date
    (if-let* ((parts (jfw/date-parts date)))
        (format "%04d-%02d-%02d %s"
                (nth 0 parts) (nth 1 parts) (nth 2 parts)
                (format-time-string "%a" (encode-time 0 0 0 (nth 2 parts) (nth 1 parts) (nth 0 parts))))
      date)))

(defun jfw/article-keyword-list (file)
  "Return the #+KEYWORDS: of FILE as a list of trimmed strings.
Keywords are what tie two articles together, so they are read here, once
per article, and kept in the article's own metadata rather than parsed
again by every listing that wants them."
  (let ((value (jfw/org-keyword file "keywords")))
    (when (and value (not (string-empty-p value)))
      (delq nil (mapcar (lambda (word)
                          (let ((word (string-trim word)))
                            (unless (string-empty-p word) word)))
                        (split-string value ","))))))

(defun jfw/keyword-slug (keyword)
  "Return a stable fragment for KEYWORD: \"GNU Guix\" becomes \"gnu-guix\".
The keyword index links to a section per keyword, and the fragment has to
survive a change of case in the article that spells it."
  (string-trim
   (replace-regexp-in-string "[^a-z0-9]+" "-" (downcase keyword))
   "-" "-"))

(defun jfw/article-metadata (file)
  "Return what a listing shows about the article in FILE, or nil.
A page that only forwards readers elsewhere is not an article: it is a
stub, and listing it would send them through a redirection."
  (unless (jfw/org-keyword file "redirect")
    (let* ((title (jfw/org-keyword file "title"))
           (date (jfw/org-keyword file "date"))
           (highlight (jfw/org-keyword file jfw/highlight-keyword))
           (category (file-name-nondirectory (directory-file-name (file-name-directory file)))))
      (list
       :file file
       :title (and title (jfw/plain-text title))
       :date date
       :date-key (jfw/date-sort-key date)
       :date-display (jfw/date-display date)
       :description (jfw/plain-text (jfw/org-keyword file "description"))
       :category category
       :keywords (jfw/article-keyword-list file)
       :url (jfw/file-page-path file)
       :highlight (and highlight (not (member (downcase highlight) jfw/highlight-off)))))))

(defun jfw/blog-articles ()
  "Return what the listings show about every blog article, newest first.
Two articles written on the same day are ordered by title, so that the
pages are the same on every build."
  (or jfw/blog-articles-cache
      (setq jfw/blog-articles-cache
            (sort (delq nil (mapcar #'jfw/article-metadata (jfw/article-files)))
                  (lambda (a b)
                    (let ((key-a (plist-get a :date-key))
                          (key-b (plist-get b :date-key)))
                      (cond
                       ((and key-a key-b (not (= key-a key-b))) (> key-a key-b))
                       ((and key-a (not key-b)) t)
                       ((and key-b (not key-a)) nil)
                       (t (string-lessp (or (plist-get a :title) "")
                                        (or (plist-get b :title) ""))))))))))

(defun jfw/listing-articles (kind path)
  "Return the articles that the listing KIND shows on the page at PATH.
A listing the build does not know is reported rather than guessed at,
which is how a typo in an index page is found."
  (pcase (downcase (or kind ""))
    ("highlighted" (cl-remove-if-not (lambda (article) (plist-get article :highlight))
                                     (jfw/blog-articles)))
    ("category" (when-let* ((category (jfw/section-slug path)))
                  (cl-remove-if-not (lambda (article) (equal (plist-get article :category) category))
                                    (jfw/blog-articles))))
    (_ (message "listing: %s asks for a listing this build does not know: %s"
                (or path "a page")
                (mapconcat #'identity jfw/listings " or "))
       nil)))

(defun jfw/listing-entry-html (article)
  "Return ARTICLE as the paragraph an index page shows it in.
The markup is the one Org writes for an entry somebody typed — a
timestamp span, a link and the summary — so a generated page reads like
the page it replaces."
  (concat
   "<p>\n"
   (when-let* ((date (plist-get article :date-display)))
     (format "<span class=\"timestamp-wrapper\"><span class=\"timestamp\">&lt;%s&gt; </span></span> "
             (jfw/escape-html date)))
   (format "<a href=\"%s\">%s</a>"
           (jfw/escape-html (plist-get article :url))
           (jfw/escape-html (or (plist-get article :title) "")))
   (let ((description (plist-get article :description)))
     (if (and description (not (string-empty-p description)))
         (format " - %s" (jfw/escape-html description))
       ""))
   "\n</p>\n"))

(defun jfw/listing-html (kind path)
  "Return the listing KIND as HTML for the page at PATH, or nil.
Nil means there is nothing to write, which is a fair answer for a
category nobody has written in yet."
  (let* ((kind (downcase (or kind "")))
         (html (pcase kind
                 ("archive" (jfw/blog-archive-html))
                 ("keywords" (jfw/blog-keyword-index-html))
                 (_ (when-let* ((articles (jfw/listing-articles kind path)))
                      (mapconcat #'jfw/listing-entry-html articles "")))))
         (entries (pcase kind
                    ("archive" (length (jfw/blog-articles)))
                    ("keywords" (length (jfw/keyword-index (jfw/blog-articles))))
                    (_ (length (or (jfw/listing-articles kind path) '()))))))
    (when html
      (cl-incf jfw/listing-pages-written)
      (cl-incf jfw/listing-entries-written entries)
      html)))

;;; ---------------------------------------------------------------------
;;; Reading the articles together
;;; ---------------------------------------------------------------------
;; An article used to end where its last paragraph ended.  What a reader
;; wants there is the next thing to read, and the build already knows
;; every article, its category and its keywords, so the choice is made
;; from that rather than from a hand-written list that would drift.

(defconst jfw/related-articles-limit 3
  "How many related articles an article offers at its foot.")

(defun jfw/article-by-url (url)
  "Return the article published at URL, or nil when URL is not one."
  (cl-find url (jfw/blog-articles) :test #'equal
           :key (lambda (article) (plist-get article :url))))

(defun jfw/articles-share-keyword-p (article other)
  "Return non-nil when ARTICLE and OTHER name the same keyword."
  (let ((theirs (mapcar #'downcase (plist-get other :keywords))))
    (cl-some (lambda (word) (member (downcase word) theirs))
             (plist-get article :keywords))))

(defun jfw/article-related (article &optional limit)
  "Return the articles most related to ARTICLE, best first.
Two articles are related by the keywords they share and by sitting in the
same category, and keywords weigh more because they say what an article is
about rather than where it was filed.  An article with neither in common
is not offered at all: a list of unrelated reading is a list of noise."
  (let* ((limit (or limit jfw/related-articles-limit))
         (category (plist-get article :category))
         (scored
          (delq nil
                (mapcar (lambda (other)
                          (unless (equal (plist-get other :url)
                                         (plist-get article :url))
                            (let ((score (+ (if (jfw/articles-share-keyword-p article other) 3 0)
                                            (if (equal category (plist-get other :category)) 1 0))))
                              (when (> score 0) (cons score other)))))
                        (jfw/blog-articles))))
         (sorted (cl-stable-sort
                  scored
                  (lambda (a b)
                    (if (= (car a) (car b))
                        (> (or (plist-get (cdr a) :date-key) 0)
                           (or (plist-get (cdr b) :date-key) 0))
                      (> (car a) (car b)))))))
    (mapcar #'cdr (cl-subseq sorted 0 (min limit (length sorted))))))

(defun jfw/article-neighbours (article)
  "Return (NEWER . OLDER) for ARTICLE in the blog's own order.
The catalogue runs newest first, so the article above this one in it is the
next thing to read and the one below it was written before; either may be
nil at the ends of the list."
  (let* ((articles (jfw/blog-articles))
         (index (cl-position article articles :test #'equal)))
    (when index
      (cons (when (> index 0) (nth (1- index) articles))
            (nth (1+ index) articles)))))

(defun jfw/article-link-html (article)
  "Return ARTICLE as a link to itself, escaped for HTML."
  (format "<a href=\"%s\">%s</a>"
          (jfw/escape-html (plist-get article :url))
          (jfw/escape-html (or (plist-get article :title) ""))))

(defun jfw/article-neighbours-html (article)
  "Return the previous and next article links for ARTICLE as HTML.
The two are labelled by what they are to the reader rather than by their
position in a list: `previous' is the article written before this one."
  (let* ((neighbours (jfw/article-neighbours article))
         (newer (car neighbours))
         (older (cdr neighbours)))
    (when (or newer older)
      (concat
       "<nav class=\"jfw-article-neighbours\" aria-label=\"More articles\">\n"
       (if older
           (format (concat "<a class=\"jfw-article-neighbour is-previous\" href=\"%s\" rel=\"prev\">"
                           "<span class=\"jfw-article-neighbour-label\">previous</span>"
                           "<span class=\"jfw-article-neighbour-title\">%s</span></a>\n")
                   (jfw/escape-html (plist-get older :url))
                   (jfw/escape-html (or (plist-get older :title) "")))
         "<span></span>\n")
       (if newer
           (format (concat "<a class=\"jfw-article-neighbour is-next\" href=\"%s\" rel=\"next\">"
                           "<span class=\"jfw-article-neighbour-label\">next</span>"
                           "<span class=\"jfw-article-neighbour-title\">%s</span></a>\n")
                   (jfw/escape-html (plist-get newer :url))
                   (jfw/escape-html (or (plist-get newer :title) "")))
         "<span></span>\n")
       "</nav>\n"))))

(defun jfw/article-related-html (article)
  "Return the related reading of ARTICLE as HTML, or nil when it has none."
  (when-let* ((related (jfw/article-related article)))
    (concat
     "<section class=\"jfw-related\" aria-label=\"Related reading\">\n"
     "<h2 class=\"jfw-related-title\">related reading</h2>\n"
     "<ul class=\"jfw-related-list\">\n"
     (mapconcat (lambda (other)
                  (format "<li>%s</li>\n" (jfw/article-link-html other)))
                related "")
     "</ul>\n"
     "</section>\n")))

(defun jfw/article-chrome-html (path)
  "Return the reading aids the article at PATH carries at its foot, or nil.
A page that is not an article, and an article the catalogue does not know,
get nothing rather than a heading with no entries under it."
  (when-let* ((article (and (jfw/article-path-p path)
                            (jfw/article-by-url path))))
    (let ((chrome (concat (or (jfw/article-neighbours-html article) "")
                          (or (jfw/article-related-html article) ""))))
      ;; Nothing to offer is answered with nothing, not with an empty
      ;; string dressed up as chrome.
      (unless (string-empty-p chrome) chrome))))

(defun jfw/archive-groups (articles)
  "Return ARTICLES grouped by the year they were written.
Each group is (LABEL . ARTICLES), years run newest first, and articles
without a readable date come last under a label of their own rather than
disappearing from a page that claims to list every article."
  (let ((years (make-hash-table :test #'equal))
        (undated '()))
    (dolist (article articles)
      (let ((key (plist-get article :date-key)))
        (if key
            (let ((year (number-to-string (floor key 10000))))
              (puthash year (append (gethash year years) (list article)) years))
          (setq undated (append undated (list article))))))
    (append
     (mapcar (lambda (year) (cons year (gethash year years)))
             (sort (hash-table-keys years) #'string>))
     (when undated (list (cons "Undated" undated))))))

(defun jfw/blog-archive-html ()
  "Return every article as HTML, grouped by the year it was written.
The archive is built from the articles themselves, so it cannot list one
that no longer exists nor forget one that does."
  (when-let* ((articles (jfw/blog-articles)))
    (concat
     "<div class=\"jfw-archive\">\n"
     (mapconcat
      (lambda (group)
        (let ((label (car group)))
          (concat
           (format "<section class=\"jfw-archive-year\">\n<h2 id=\"%s\">%s</h2>\n<ul>\n"
                   (jfw/keyword-slug label) (jfw/escape-html label))
           (mapconcat
            (lambda (article)
              (format (concat "<li><time datetime=\"%s\">%s</time> %s"
                              " <span class=\"jfw-archive-category\">%s</span></li>\n")
                      (or (jfw/escape-html (plist-get article :date-display)) "")
                      (or (jfw/escape-html (plist-get article :date-display)) "")
                      (jfw/article-link-html article)
                      (or (jfw/escape-html (jfw/section-label (plist-get article :url))) "")))
            (cdr group) "")
           "</ul>\n</section>\n")))
      (jfw/archive-groups articles) "")
     "</div>\n")))

(defun jfw/keyword-index (articles)
  "Return (KEYWORD . ARTICLES) for every keyword in ARTICLES.
The pairs run from the keyword used most to the one used least, ties in
alphabetical order, and each keyword keeps the spelling of the first
article that used it.  The articles under a keyword stay in the blog's own
order, newest first."
  (let ((by-key (make-hash-table :test #'equal))
        (spelling (make-hash-table :test #'equal)))
    (dolist (article articles)
      (dolist (word (plist-get article :keywords))
        (let ((key (downcase word)))
          (unless (gethash key spelling) (puthash key word spelling))
          (puthash key (append (gethash key by-key) (list article)) by-key))))
    (sort (mapcar (lambda (key)
                    (cons (gethash key spelling) (gethash key by-key)))
                  (hash-table-keys by-key))
          (lambda (a b)
            (if (= (length (cdr a)) (length (cdr b)))
                (string-lessp (downcase (car a)) (downcase (car b)))
              (> (length (cdr a)) (length (cdr b))))))))

(defun jfw/blog-keyword-index-html ()
  "Return the keyword index of the blog as HTML, or nil.
A cloud of every keyword sits above one section per keyword, so a reader
can see at a glance what the blog keeps coming back to and then go straight
to the articles that say it."
  (when-let* ((index (jfw/keyword-index (jfw/blog-articles))))
    (concat
     "<div class=\"jfw-keywords\">\n"
     "<ul class=\"jfw-keyword-cloud\">\n"
     (mapconcat (lambda (entry)
                  (format (concat "<li><a href=\"#%s\">%s"
                                  " <span class=\"jfw-keyword-count\">%d</span></a></li>\n")
                          (jfw/keyword-slug (car entry))
                          (jfw/escape-html (car entry))
                          (length (cdr entry))))
                (sort (copy-sequence index)
                      (lambda (a b) (string-lessp (downcase (car a)) (downcase (car b)))))
                "")
     "</ul>\n"
     (mapconcat
      (lambda (entry)
        (concat
         (format "<section class=\"jfw-keyword-group\">\n<h2 id=\"%s\">%s</h2>\n<ul>\n"
                 (jfw/keyword-slug (car entry)) (jfw/escape-html (car entry)))
         (mapconcat (lambda (article)
                      (format "<li>%s</li>\n" (jfw/article-link-html article)))
                    (cdr entry) "")
         "</ul>\n</section>\n"))
      index "")
     "</div>\n")))

(defun jfw/org-html-special-block (special-block contents info)
  "Export SPECIAL-BLOCK, or write a blog listing when it asks for one.
An index page declares which listing it shows:

  #+begin_listing highlighted
  #+end_listing

and the build fills it with the articles it finds, so the page cannot
list an article that no longer exists, nor forget one that does."
  (let ((type (and (org-element-property :type special-block)
                   (downcase (org-element-property :type special-block)))))
    (cond
     ((string-equal type "listing")
      (or (jfw/listing-html (or (org-element-property :parameters special-block)
                                (org-element-property :value special-block))
                            (jfw/page-path info))
          ""))
     ;; The radar is drawn here, from the article that describes it, so the
     ;; page carries its picture instead of a script that has to draw one.
     ((string-equal type "radar") (jfw/radar-html info))
     (t (org-html-special-block special-block contents info)))))

(defun jfw/report-listings ()
  "Report what the listings found, once, at the end of a build."
  (let ((articles (jfw/blog-articles)))
    (message "blog keywords: %d in use"
             (length (jfw/keyword-index articles)))
    (message "blog listings: %d articles, %d highlighted, %d entries on %d pages"
             (length articles)
             (length (cl-remove-if-not (lambda (article) (plist-get article :highlight)) articles))
             jfw/listing-entries-written
             jfw/listing-pages-written)
    (dolist (article articles)
      (unless (plist-get article :date-key)
        (message "blog listing: %s has no readable #+DATE:, so it is listed last"
                 (file-name-nondirectory (plist-get article :file)))))))

(provide 'jfw-blog)

;;; lisp/jfw-blog.el ends here
