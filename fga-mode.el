;;; fga-mode.el --- Major mode for OpenFGA authorization model files -*- lexical-binding: t; -*-

;; Author: Generated for OpenFGA DSL editing
;; Version: 1.0.0
;; Keywords: languages, authorization, fga, openfga
;; URL: https://openfga.dev
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; A major mode for editing OpenFGA authorization model files (.fga) and
;; modular model manifest files (fga.mod).
;;
;; OpenFGA uses a human-readable DSL to define authorization models based
;; on relationship-based access control (ReBAC).  A model declares object
;; types and the relations users can have with those objects.  The DSL is
;; compiled to JSON for consumption by the OpenFGA API.
;;
;; Two file formats are handled:
;;
;;   .fga       Standard single-file authorization models, as well as the
;;              individual module files that make up a modular model.  Both
;;              are identical in syntax; module files additionally use the
;;              `extend type' construct to augment types declared elsewhere.
;;
;;   fga.mod    Modular model manifest.  Lists the schema version, the
;;              module name, and the .fga source files that together form
;;              the complete model.
;;
;; Features:
;;   - Syntax highlighting for the full FGA DSL: structural keywords,
;;     type and relation names, conditions, boolean operators (`or', `and',
;;     `but not', `from', `with'), direct type restrictions ([user],
;;     [group#member], [org:*]), wildcards, and `self'.
;;   - Dedicated highlighting for fga.mod manifest files.
;;   - Indentation driven by the structural nesting of the DSL:
;;     top-level declarations at column 0, `relations' at one level,
;;     `define' at two levels.  Configurable via `fga-indent-offset'.
;;   - Imenu index with separate sections for Types, Conditions, and
;;     Relations, enabling fast in-buffer navigation.
;;   - `fga-goto-type' (C-c C-t) and `fga-goto-define' (C-c C-d) for
;;     completing-read-based jumps to definitions.
;;   - Comment toggling via M-; or C-c C-/.  FGA uses # for comments.
;;   - `outline-minor-mode' compatibility: each `type' and `condition'
;;     declaration is treated as a top-level heading, allowing folding
;;     with the standard C-c @ bindings.
;;
;; Installation:
;;   Put this file somewhere on your load-path and add to your init:
;;
;;     (require 'fga-mode)
;;
;;   Or with use-package:
;;
;;     (use-package fga-mode
;;       :load-path "/path/to/fga-mode.el")
;;
;; File associations for .fga and fga.mod are registered automatically
;; via `auto-mode-alist'.

;;; Code:

(require 'rx)
(require 'smie nil t)


;;;; Customisation

(defgroup fga nil
  "Major mode for OpenFGA authorization model files."
  :group 'languages
  :prefix "fga-")

(defcustom fga-indent-offset 2
  "Number of spaces per indentation level in FGA files.

The DSL has three structural nesting levels:

  0  Type declarations (`type', `extend type', `condition', `model').
  1  The `relations' block inside a type definition.
  2  Individual `define' statements inside a `relations' block.

Each level is indented by this many spaces relative to the one above."
  :type 'integer
  :group 'fga)


;;;; Faces

(defface fga-keyword-face
  '((t :inherit font-lock-keyword-face))
  "Face for FGA structural keywords.

Applied to: model, schema, type, relations, define, condition, extend."
  :group 'fga)

(defface fga-schema-version-face
  '((t :inherit font-lock-constant-face :weight bold))
  "Face for the schema version literal that follows the `schema' keyword.

Example: in `schema 1.1' the string \"1.1\" uses this face."
  :group 'fga)

(defface fga-type-name-face
  '((t :inherit font-lock-type-face))
  "Face for type names introduced by `type' or `extend type'.

Also used for file names listed in fga.mod `contents' blocks."
  :group 'fga)

(defface fga-relation-name-face
  '((t :inherit font-lock-variable-name-face))
  "Face for the relation identifier on the left-hand side of a `define'.

Example: in `define viewer: [user] or owner' the word \"viewer\" uses
this face."
  :group 'fga)

(defface fga-condition-name-face
  '((t :inherit font-lock-function-name-face))
  "Face for the identifier that names a `condition' block.

Example: in `condition non_expired(expiry: timestamp)' the identifier
\"non_expired\" uses this face."
  :group 'fga)

(defface fga-operator-face
  '((t :inherit font-lock-builtin-face))
  "Face for relation-algebra and boolean operators in `define' expressions.

Applied to: or, and, not, but not, from, with."
  :group 'fga)

(defface fga-direct-rel-face
  '((t :inherit font-lock-string-face))
  "Face for the contents of direct type restriction brackets.

The bracketed expression in `define viewer: [user, group#member]'
specifies which object types may be directly assigned to the relation.
The text between the brackets, including the brackets themselves, uses
this face.

Syntax variants handled:
  [user]              single type
  [user, group]       multiple types
  [group#member]      specific relation on another type
  [org:*]             public wildcard for a type"
  :group 'fga)

(defface fga-wildcard-face
  '((t :inherit font-lock-warning-face :weight bold))
  "Face for the public wildcard token `*'.

A wildcard in a type restriction (e.g. `[user:*]') grants access to
every object of that type.  The warning styling is intentional: wildcard
grants are high-impact and deserve to stand out during review."
  :group 'fga)

(defface fga-self-face
  '((t :inherit font-lock-preprocessor-face))
  "Face for the `self' keyword in relation expressions.

`self' refers to the set of users directly related to the current object
via the relation being defined, used in userset rewrites."
  :group 'fga)

(defface fga-module-keyword-face
  '((t :inherit font-lock-preprocessor-face :weight bold))
  "Face for top-level keys in fga.mod manifest files.

Applied to: module, schema, contents."
  :group 'fga)

(defface fga-comment-face
  '((t :inherit font-lock-comment-face))
  "Face for FGA line comments.

FGA uses `#' as the comment character; the comment extends to the end
of the line."
  :group 'fga)


;;;; Syntax table

(defvar fga-mode-syntax-table
  (let ((st (make-syntax-table)))
    (modify-syntax-entry ?# "<" st)
    (modify-syntax-entry ?\n ">" st)
    (modify-syntax-entry ?\[ "(]" st)
    (modify-syntax-entry ?\] ")[" st)
    (modify-syntax-entry ?_ "_" st)
    (modify-syntax-entry ?: "." st)
    st)
  "Syntax table shared by `fga-mode' and `fga-mod-mode'.

`#' is a line-comment starter and `\\n' closes it.  Square brackets are
treated as a matched pair so that direct type restriction lists like
`[user, group#member]' are navigable with `forward-sexp'.  Underscore
is a symbol constituent so that identifiers such as `can_share' are
treated as single tokens.  Colon is punctuation rather than a word
character, which prevents it from being included in identifier tokens
during navigation.")


;;;; Font-lock — standard .fga files

(defconst fga--structural-keywords
  '("model" "schema" "type" "relations" "define" "condition" "extend")
  "Structural keywords of the FGA DSL.

These form the skeleton of every authorization model.  They are not
directly used by font-lock (which builds its own patterns), but serve as
a single authoritative list for tooling, completion, and documentation.")

(defconst fga--operator-keywords
  '("or" "and" "not" "but" "from" "with")
  "Relation-algebra and boolean operator keywords of the FGA DSL.

These appear on the right-hand side of `define' expressions to compose
relations:

  or       union of two usersets
  and      intersection of two usersets
  but not  set difference (exclude one userset from another)
  from     tuple-to-userset: look up a relation on a related object
  with     attach a condition to a relation expression
  not      negation (used as part of `but not')")

(defconst fga--font-lock-keywords
  (list
   (list (rx "schema" (+ space) (group (+ (any digit "."))))
         1 'fga-schema-version-face)

   (list (rx (group "extend") (+ space) (group "type") (+ space)
             (group (+ (any alnum "_" "-"))))
         '(1 'fga-keyword-face)
         '(2 'fga-keyword-face)
         '(3 'fga-type-name-face))

   (list (rx line-start (* space) (group "type") (+ space)
             (group (+ (any alnum "_" "-"))))
         '(1 'fga-keyword-face)
         '(2 'fga-type-name-face))

   (list (rx line-start (* space) (group "condition") (+ space)
             (group (+ (any alnum "_" "-"))))
         '(1 'fga-keyword-face)
         '(2 'fga-condition-name-face))

   (list (rx line-start (* space) (group "define") (+ space)
             (group (+ (any alnum "_"))) (* space) ":")
         '(1 'fga-keyword-face)
         '(2 'fga-relation-name-face))

   (list (rx "[" (group (*? anything)) "]")
         1 'fga-direct-rel-face)

   (list (rx (not (any "[")) (group "*") (not (any "]")))
         1 'fga-wildcard-face)

   (list (rx symbol-start
             (group (or "or" "and" "but not" "from" "with" "not"))
             symbol-end)
         1 'fga-operator-face)

   (list (rx symbol-start (group "self") symbol-end)
         1 'fga-self-face)

   (list (rx symbol-start
             (group (or "model" "schema" "relations"))
             symbol-end)
         1 'fga-keyword-face))
  "Font-lock keyword list for `fga-mode'.

Rules are ordered from most to least specific because font-lock applies
them in sequence and the first match wins for a given buffer position:

  1. Schema version literal (the number after `schema').
  2. `extend type NAME' — must precede the plain `type' rule to avoid
     matching just the `type' keyword and leaving `extend' unhighlighted.
  3. Plain `type NAME' declarations.
  4. `condition NAME' declarations.
  5. `define RELATION:' statements.
  6. Direct type restriction bracket contents `[...]'.
  7. Public wildcard `*' outside brackets.
  8. Boolean / relation operators.
  9. `self' keyword.
  10. Remaining structural keywords that appear without a following name
      (`model', `schema', `relations').")


;;;; Font-lock — fga.mod manifest files

(defconst fga--mod-font-lock-keywords
  (list
   (list (rx line-start (* space)
             (group (or "module" "schema" "contents")) (* space) ":")
         1 'fga-module-keyword-face)

   (list (rx "schema" (* space) ":" (* space)
             (group (+ (any digit "."))))
         1 'fga-schema-version-face)

   (list (rx line-start (* space) "-" (+ space)
             (group (+ nonl)))
         1 'fga-type-name-face)

   (list (rx "#" (* nonl)) 0 'fga-comment-face))
  "Font-lock keyword list for `fga-mod-mode'.

fga.mod uses a simple YAML-inspired syntax:

  schema 1.2
  module my-app
  contents:
    - core.fga
    - projects.fga

Rules highlight the three top-level manifest keys (`module', `schema',
`contents'), the schema version literal, content file entries (lines
beginning with `-'), and line comments.")


;;;; Indentation

(defun fga--current-line-indent ()
  "Return the indentation column of the current line.

Moves point to the first non-whitespace character on the line and
returns its column number, without modifying the buffer or point
permanently."
  (save-excursion
    (back-to-indentation)
    (current-column)))

(defun fga--indent-line ()
  "Indent the current line according to FGA DSL nesting rules.

Delegates to `fga--calculate-indent' for the target column, then
adjusts the leading whitespace on the current line to match.  If point
is within the indentation prefix, it is moved to the first
non-whitespace character after re-indenting."
  (let* ((indent (fga--calculate-indent)))
    (when indent
      (save-excursion
        (back-to-indentation)
        (let ((cur (current-column)))
          (unless (= cur indent)
            (delete-region (line-beginning-position) (point))
            (indent-to indent))))
      (when (< (current-column) (fga--calculate-indent))
        (back-to-indentation)))))

(defun fga--looking-at-keyword (kw)
  "Return non-nil if the current line begins with the keyword KW.

Comparison is made after skipping leading whitespace, and KW must be
followed by a word boundary so that, for example, \"type\" does not
match \"types\"."
  (save-excursion
    (back-to-indentation)
    (looking-at (concat (regexp-quote kw) "\\b"))))

(defun fga--calculate-indent ()
  "Return the target indentation column for the current line.

The FGA DSL has a fixed three-level nesting structure:

  Level 0 (`model', `type', `extend type', `condition') — top-level
    declarations that are never nested inside anything else.

  Level 1 (`relations') — the keyword that opens the relation block
    inside a type definition.  Indented by one `fga-indent-offset'.

  Level 2 (`define') — individual relation definitions inside a
    `relations' block.  Indented by two `fga-indent-offset' units.

Any other line (condition body, blank line, comment, continuation)
inherits the indentation of the nearest preceding non-blank line."
  (save-excursion
    (beginning-of-line)
    (let ((cur-pos (point)))
      (cond
       ((or (fga--looking-at-keyword "model")
            (fga--looking-at-keyword "type")
            (fga--looking-at-keyword "extend")
            (fga--looking-at-keyword "condition"))
        0)
       ((fga--looking-at-keyword "relations")
        fga-indent-offset)
       ((fga--looking-at-keyword "define")
        (* 2 fga-indent-offset))
       (t
        (let ((prev-indent (fga--prev-meaningful-indent cur-pos)))
          (or prev-indent 0)))))))

(defun fga--prev-meaningful-indent (limit)
  "Return the indentation column of the first non-blank line before LIMIT.

Walks backward from LIMIT, skipping lines that contain only whitespace,
and returns the column of the first non-whitespace character on the
first substantial line found.  Returns 0 if the beginning of the buffer
is reached without finding such a line."
  (save-excursion
    (goto-char limit)
    (forward-line -1)
    (while (and (not (bobp))
                (looking-at "^[[:space:]]*$"))
      (forward-line -1))
    (if (bobp) 0
      (back-to-indentation)
      (current-column))))


;;;; Imenu integration

(defvar fga--imenu-generic-expression
  `(("Types"
     ,(rx line-start (* space) (? "extend ") "type" (+ space)
          (group (+ (any alnum "_" "-"))))
     1)
    ("Conditions"
     ,(rx line-start (* space) "condition" (+ space)
          (group (+ (any alnum "_" "-"))))
     1)
    ("Relations"
     ,(rx line-start (* space) "define" (+ space)
          (group (+ (any alnum "_"))) (* space) ":")
     1))
  "Imenu index expressions for `fga-mode'.

Produces three index sections:

  Types       Every `type' and `extend type' declaration.  Both plain
              definitions and modular extensions are indexed so that
              jumping works across a multi-file modular model when
              buffers are visited individually.

  Conditions  Every `condition' declaration.

  Relations   Every `define' statement.  Because relation names are
              scoped to their enclosing type and the same name may appear
              in multiple types, the completion list may contain
              duplicates; the jump always goes to the first match.")


;;;; Keymap and interactive commands

(defvar fga-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-t") #'fga-goto-type)
    (define-key map (kbd "C-c C-d") #'fga-goto-define)
    (define-key map (kbd "C-c C-/") #'fga-toggle-comment-region)
    map)
  "Keymap for `fga-mode'.

\\`C-c C-t'  `fga-goto-type'              Jump to a type definition.
\\`C-c C-d'  `fga-goto-define'            Jump to a relation definition.
\\`C-c C-/'  `fga-toggle-comment-region'  Toggle # comments on region.")

(defun fga-goto-type ()
  "Prompt for a type name and jump to its definition in the current buffer.

All `type' and `extend type' declarations are offered as completion
candidates.  The search matches both canonical definitions and modular
extensions."
  (interactive)
  (let* ((types (fga--collect-definitions "type"))
         (choice (completing-read "Jump to type: " types nil t)))
    (when choice
      (fga--jump-to-definition "type" choice))))

(defun fga-goto-define ()
  "Prompt for a relation name and jump to its `define' in the current buffer.

All `define' statements are offered as completion candidates.  Because
the same relation name can appear in multiple types, the jump always
moves to the first textual occurrence."
  (interactive)
  (let* ((rels (fga--collect-definitions "define"))
         (choice (completing-read "Jump to relation: " rels nil t)))
    (when choice
      (fga--jump-to-definition "define" choice))))

(defun fga--collect-definitions (keyword)
  "Return a list of all identifiers introduced by KEYWORD in the current buffer.

Scans the buffer from the beginning for lines of the form:

  [extend] KEYWORD IDENTIFIER

and returns the IDENTIFIER strings in buffer order.  Used by
`fga-goto-type' and `fga-goto-define' to build completion candidates."
  (let ((re (concat "^[[:space:]]*\\(?:extend \\)?" (regexp-quote keyword)
                    "[[:space:]]+\\([[:alnum:]_-]+\\)"))
        results)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward re nil t)
        (push (match-string-no-properties 1) results)))
    (nreverse results)))

(defun fga--jump-to-definition (keyword name)
  "Move point to the first definition of NAME introduced by KEYWORD.

Searches from the beginning of the buffer for a line matching:

  [extend] KEYWORD NAME

If found, moves point to the beginning of that line and recenters the
window.  If no match is found, displays a message instead."
  (let ((re (concat "^[[:space:]]*\\(?:extend \\)?" (regexp-quote keyword)
                    "[[:space:]]+" (regexp-quote name) "\\b")))
    (goto-char (point-min))
    (if (re-search-forward re nil t)
        (progn (beginning-of-line) (recenter))
      (message "Definition of '%s' not found." name))))

(defun fga-toggle-comment-region (beg end)
  "Toggle `#' comments on the region between BEG and END.

When the region is active, delegates to `comment-or-uncomment-region'.
FGA uses `#' as its sole comment character; comments extend to the end
of the line."
  (interactive "r")
  (comment-or-uncomment-region beg end))


;;;; Outline support

(defvar fga--outline-regexp
  (rx line-start (* space) (? "extend ") (or "type" "condition") (+ space))
  "Regexp matching lines that `outline-minor-mode' treats as headings.

Each `type', `extend type', and `condition' declaration is considered a
top-level heading (depth 1).  This allows the body of a type — its
`relations' block and `define' statements — to be folded and unfolded
with the standard `outline-minor-mode' commands (C-c @ C-c to hide,
C-c @ C-e to show).")


;;;; fga.mod mode

;;;###autoload
(define-derived-mode fga-mod-mode text-mode "FGA-Mod"
  "Major mode for OpenFGA modular model manifest files (fga.mod).

A fga.mod file is the entry point for a modular authorization model: a
model split across several .fga files and composed together by the FGA
toolchain.  The manifest declares which schema version the model targets,
an optional module name, and the ordered list of .fga source files whose
`type' and `extend type' declarations together form the complete model.

Manifest syntax:

  schema 1.2
  module my-app
  contents:
    - core.fga
    - projects.fga
    - organizations.fga

  `schema'    Required.  Must match the schema version used in the
              constituent .fga files.  Valid values are 1.1 and 1.2.

  `module'    Optional module name, used when composing multiple modules.

  `contents'  Required.  An indented list of .fga file paths (relative
              to the directory containing fga.mod) that make up the
              model.  Files are processed in the order listed.

This mode provides syntax highlighting for manifest keys, the schema
version, content file entries, and comments.  It shares the syntax table
and comment settings of `fga-mode'.

\\{fga-mode-map}"
  :syntax-table fga-mode-syntax-table
  (setq-local font-lock-defaults '(fga--mod-font-lock-keywords nil nil))
  (setq-local comment-start "# ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "#+[[:space:]]*")
  (setq-local indent-tabs-mode nil)
  (font-lock-mode 1))


;;;; Main mode

;;;###autoload
(define-derived-mode fga-mode prog-mode "FGA"
  "Major mode for editing OpenFGA authorization model files (.fga).

OpenFGA is a relationship-based access control (ReBAC) system.
Authorization models are written in a DSL that declares object types,
the relations users can have with those objects, and optional conditions
that guard when a relation applies.

── DSL structure ────────────────────────────────────────────────────────

  model
    schema 1.1

  type user

  type document
    relations
      define owner:    [user]
      define editor:   [user] or owner
      define viewer:   [user, group#member] or editor
      define can_share: owner and editor

  condition non_expired(expiry: timestamp) {
    now < expiry
  }

Each model begins with a `model' block specifying the schema version.
Type declarations follow at the top level.  Each type contains a
`relations' block with one or more `define' statements.  A `define'
statement names a relation and gives its userset expression.

Userset expression syntax:
  [TypeA, TypeB#rel]    direct assignment from listed types / relations
  relation-name         computed from another relation on this object
  expr or expr          union
  expr and expr         intersection
  expr but not expr     set difference
  rel from rel          tuple-to-userset: follow a relation to another
                        object and evaluate a relation there
  expr with condition   conditional relation (requires a `condition')
  *                     public wildcard — all objects of the type

── Modular models ───────────────────────────────────────────────────────

A model may be split across multiple .fga files, coordinated by a
fga.mod manifest (see `fga-mod-mode').  Individual module files use
`extend type' to add relations to types declared in other files:

  extend type document
    relations
      define can_archive: owner

Both plain `type' and `extend type' are fully supported by this mode's
highlighting, indentation, and navigation.

── This mode provides ───────────────────────────────────────────────────

  Syntax highlighting  Structural keywords, type and relation names,
                       condition names, operators, bracket expressions,
                       wildcards, and `self'.

  Indentation          Three fixed levels driven by the DSL structure:
                       column 0 for top-level declarations, one offset
                       for `relations', two offsets for `define'.
                       Configurable via `fga-indent-offset'.

  Imenu                Index sections for Types, Conditions, and
                       Relations.  Access via M-x imenu.

  Definition jumping   C-c C-t  `fga-goto-type'    jump to a type
                       C-c C-d  `fga-goto-define'   jump to a relation

  Comments             M-; or C-c C-/  toggle # comments on region.

  Outline folding      Each `type' / `condition' declaration is an
                       outline heading.  Enable with
                       `fga-enable-outline', then fold/unfold with
                       the C-c @ prefix.

\\{fga-mode-map}"
  :syntax-table fga-mode-syntax-table

  (setq-local font-lock-defaults
              '(fga--font-lock-keywords nil nil nil nil))

  (setq-local comment-start "# ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "#+[[:space:]]*")

  (setq-local indent-line-function #'fga--indent-line)
  (setq-local indent-tabs-mode nil)
  (setq-local tab-width fga-indent-offset)
  (setq-local electric-indent-chars (append ":{}" electric-indent-chars))

  (setq-local imenu-generic-expression fga--imenu-generic-expression)
  (setq-local imenu-case-fold-search nil)

  (setq-local outline-regexp fga--outline-regexp)
  (setq-local outline-level (lambda () 1))

  (setq-local which-func-functions nil)

  (font-lock-mode 1))


;;;; Auto-mode associations

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.fga\\'" . fga-mode))

;;;###autoload
(add-to-list 'auto-mode-alist '("fga\\.mod\\'" . fga-mod-mode))


;;;; Outline helper

(defun fga-enable-outline ()
  "Enable `outline-minor-mode' in the current FGA buffer.

Each `type', `extend type', and `condition' declaration becomes an
outline heading at depth 1, making it possible to collapse the body of
individual type definitions with the standard outline commands:

  C-c @ C-c   Hide the body below the heading at point.
  C-c @ C-e   Show the body below the heading at point.
  C-c @ C-t   Hide all bodies in the buffer.
  C-c @ C-a   Show all bodies in the buffer.

The outline regexp is stored in `fga--outline-regexp'."
  (interactive)
  (outline-minor-mode 1)
  (message "Outline minor mode enabled. Use C-c @ commands to fold/unfold."))


(provide 'fga-mode)

;;; fga-mode.el ends here
