;;; fga-mode.el --- Major mode for OpenFGA authorization model files -*- lexical-binding: t; -*-

;; Author: Generated for OpenFGA DSL editing
;; Version: 2.0.0
;; Keywords: languages, authorization, fga, openfga
;; URL: https://openfga.dev
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; A major mode for editing OpenFGA authorization model files (.fga) and
;; modular model manifest files (fga.mod).
;;
;; Two implementations are provided for .fga files:
;;
;;   `fga-ts-mode'   Tree-sitter implementation (Emacs 29+).  Requires
;;                   the `fga' grammar; install it with:
;;
;;                     (add-to-list 'treesit-language-source-alist
;;                       '(fga "https://github.com/matoous/tree-sitter-fga"))
;;                     (treesit-install-language-grammar 'fga)
;;
;;                   The tree-sitter grammar parses `#' in context, so
;;                   `group#member' and `# comment' are disambiguated
;;                   structurally — no regex heuristics needed.
;;
;;   `fga-mode'      Pure Elisp fallback (Emacs 27+).  Uses font-lock
;;                   plus `syntax-propertize-function' to distinguish
;;                   `#' as a relation separator vs. comment starter.
;;
;;   `fga-mod-mode'  Manifest mode for fga.mod files (both impls share
;;                   this; tree-sitter is not used for the simple manifest
;;                   format).
;;
;; Opening a .fga file activates `fga-ts-mode' when the grammar is
;; available, otherwise `fga-mode'.  fga.mod files always use
;; `fga-mod-mode'.
;;
;; All three modes share: custom faces, the syntax table, the keymap,
;; interactive navigation commands, and outline support.

;;; Code:

(require 'rx)
(require 'cl-lib)
(require 'smie nil t)


;;;; ──────────────────────────────────────────────────────────────
;;;; Customisation
;;;; ──────────────────────────────────────────────────────────────

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


;;;; ──────────────────────────────────────────────────────────────
;;;; Faces
;;;; ──────────────────────────────────────────────────────────────

(defface fga-keyword-face
  '((t :inherit font-lock-keyword-face))
  "Face for FGA structural keywords: model, schema, type, relations, define,
condition, extend."
  :group 'fga)

(defface fga-schema-version-face
  '((t :inherit font-lock-constant-face :weight bold))
  "Face for the schema version literal after the `schema' keyword.
Example: the \"1.1\" in `schema 1.1'."
  :group 'fga)

(defface fga-type-name-face
  '((t :inherit font-lock-type-face))
  "Face for type names introduced by `type' or `extend type'.
Also used for file names listed in fga.mod `contents' blocks."
  :group 'fga)

(defface fga-relation-name-face
  '((t :inherit font-lock-variable-name-face))
  "Face for the relation identifier on the left-hand side of a `define'.
Example: \"viewer\" in `define viewer: [user] or owner'."
  :group 'fga)

(defface fga-condition-name-face
  '((t :inherit font-lock-function-name-face))
  "Face for the identifier naming a `condition' block.
Example: \"non_expired\" in `condition non_expired(expiry: timestamp)'."
  :group 'fga)

(defface fga-operator-face
  '((t :inherit font-lock-builtin-face))
  "Face for relation-algebra and boolean operators in `define' expressions.
Applied to: or, and, not, but not, from, with."
  :group 'fga)

(defface fga-direct-rel-face
  '((t :inherit font-lock-string-face))
  "Face for the contents of direct type restriction brackets.
Example: the text inside `[user, group#member]'.
Note: `group#member' is further highlighted by `fga-relation-ref-face'."
  :group 'fga)

(defface fga-relation-ref-type-face
  '((t :inherit font-lock-type-face))
  "Face for the type part of a type#relation reference.
Example: \"group\" in `[group#member]'."
  :group 'fga)

(defface fga-relation-ref-rel-face
  '((t :inherit font-lock-variable-name-face))
  "Face for the relation part of a type#relation reference.
Example: \"member\" in `[group#member]'."
  :group 'fga)

(defface fga-wildcard-face
  '((t :inherit font-lock-warning-face :weight bold))
  "Face for the public wildcard token `*'.
Styled as a warning because wildcard grants are high-impact."
  :group 'fga)

(defface fga-self-face
  '((t :inherit font-lock-preprocessor-face))
  "Face for the `self' keyword in relation expressions."
  :group 'fga)

(defface fga-module-keyword-face
  '((t :inherit font-lock-preprocessor-face :weight bold))
  "Face for top-level keys in fga.mod manifest files.
Applied to: module, schema, contents."
  :group 'fga)

(defface fga-comment-face
  '((t :inherit font-lock-comment-face))
  "Face for FGA line comments (# to end of line)."
  :group 'fga)


;;;; ──────────────────────────────────────────────────────────────
;;;; Syntax table  (shared by all three modes)
;;;; ──────────────────────────────────────────────────────────────

;; IMPORTANT: `#' must NOT be given comment syntax here.
;;
;; In the FGA DSL `#' serves two distinct purposes:
;;
;;   1. Line comment starter when it appears at the start of a token:
;;        # This is a comment
;;        define viewer: [user] # <- also a comment
;;
;;   2. Type-relation separator inside direct type restriction brackets:
;;        define viewer: [group#member]
;;
;; Giving `#' static comment syntax would cause Emacs's parser to treat
;; everything after `group#' as a comment.
;;
;; The disambiguation is handled differently in each implementation:
;;
;;   fga-ts-mode   The tree-sitter grammar already parses `relation_ref'
;;                 nodes as (identifier "#" identifier), so `#' inside
;;                 a bracket context is never a comment node.  No
;;                 additional Elisp is needed.
;;
;;   fga-mode      `fga-syntax-propertize' runs after each edit and
;;                 assigns text properties: `#' preceded by a word char
;;                 gets punctuation syntax "."; all other `#' get
;;                 comment-start syntax "<".

(defvar fga-mode-syntax-table
  (let ((st (make-syntax-table)))
    (modify-syntax-entry ?# "." st)     ; plain punctuation — see above
    (modify-syntax-entry ?\n ">" st)    ; newline ends a comment
    (modify-syntax-entry ?\[ "(]" st)   ; bracket pair for sexp navigation
    (modify-syntax-entry ?\] ")[" st)
    (modify-syntax-entry ?_ "_" st)     ; identifier constituent
    (modify-syntax-entry ?: "." st)     ; punctuation: user:anne
    (modify-syntax-entry ?. "." st)     ; punctuation: user_ip.in_cidr()
    st)
  "Syntax table shared by `fga-mode', `fga-ts-mode', and `fga-mod-mode'.

`#' is plain punctuation.  See the commentary above for the full
explanation of the `#' disambiguation strategy.")


;;;; ──────────────────────────────────────────────────────────────
;;;; Keymap and interactive commands  (shared)
;;;; ──────────────────────────────────────────────────────────────

(defvar fga-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-t") #'fga-goto-type)
    (define-key map (kbd "C-c C-d") #'fga-goto-define)
    (define-key map (kbd "C-c C-/") #'fga-toggle-comment-region)
    map)
  "Keymap shared by `fga-mode', `fga-ts-mode', and `fga-mod-mode'.

\\`C-c C-t'  `fga-goto-type'             Jump to a type definition.
\\`C-c C-d'  `fga-goto-define'           Jump to a relation definition.
\\`C-c C-/'  `fga-toggle-comment-region' Toggle # comments on region.")

(defun fga-goto-type ()
  "Prompt for a type name and jump to its definition in the current buffer."
  (interactive)
  (let* ((types (fga--collect-definitions "type"))
         (choice (completing-read "Jump to type: " types nil t)))
    (when choice (fga--jump-to-definition "type" choice))))

(defun fga-goto-define ()
  "Prompt for a relation name and jump to its `define' in the current buffer."
  (interactive)
  (let* ((rels (fga--collect-definitions "define"))
         (choice (completing-read "Jump to relation: " rels nil t)))
    (when choice (fga--jump-to-definition "define" choice))))

(defun fga--collect-definitions (keyword)
  "Return a list of identifiers introduced by KEYWORD in the current buffer."
  (let ((re (concat "^[[:space:]]*\\(?:extend \\)?" (regexp-quote keyword)
                    "[[:space:]]+\\([[:alnum:]_-]+\\)"))
        results)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward re nil t)
        (push (match-string-no-properties 1) results)))
    (nreverse results)))

(defun fga--jump-to-definition (keyword name)
  "Move point to the first definition of NAME introduced by KEYWORD."
  (let ((re (concat "^[[:space:]]*\\(?:extend \\)?" (regexp-quote keyword)
                    "[[:space:]]+" (regexp-quote name) "\\b")))
    (goto-char (point-min))
    (if (re-search-forward re nil t)
        (progn (beginning-of-line) (recenter))
      (message "Definition of '%s' not found." name))))

(defun fga-toggle-comment-region (beg end)
  "Toggle `#' comments on the region between BEG and END."
  (interactive "r")
  (comment-or-uncomment-region beg end))


;;;; ──────────────────────────────────────────────────────────────
;;;; Shared locals helper
;;;; ──────────────────────────────────────────────────────────────

(defun fga--set-common-locals ()
  "Set buffer-local variables common to `fga-mode' and `fga-ts-mode'."
  (setq-local comment-start "# ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "#+[[:space:]]*")
  (setq-local tab-width fga-indent-offset)
  (setq-local indent-tabs-mode nil)
  (setq-local imenu-case-fold-search nil)
  (setq-local outline-regexp fga--outline-regexp)
  (setq-local outline-level (lambda () 1)))


;;;; ──────────────────────────────────────────────────────────────
;;;; Outline  (shared)
;;;; ──────────────────────────────────────────────────────────────

(defvar fga--outline-regexp
  (rx line-start (* space) (? "extend ") (or "type" "condition") (+ space))
  "Regexp for `outline-minor-mode' headings in FGA buffers.
Each `type', `extend type', and `condition' declaration is a heading.")

(defun fga-enable-outline ()
  "Enable `outline-minor-mode' in the current FGA buffer.
Each `type' / `condition' declaration becomes a foldable heading."
  (interactive)
  (outline-minor-mode 1)
  (message "Outline minor mode enabled.  Use C-c @ commands to fold/unfold."))


;;;; ================================================================
;;;; PART 1 — Pure Elisp fallback: `fga-mode'
;;;; ================================================================

;;;;; Syntax propertization — disambiguate `#' ;;;;;;;;;;;;;;;;;;;

(defun fga-syntax-propertize (start end)
  "Assign syntax text properties to `#' characters between START and END.

A `#' immediately preceded by a word-constituent character is the
type#relation separator (e.g. group#member) and receives punctuation
syntax (\".\") so it does not open a comment.

Any other `#' — at the start of a line, after whitespace, after
punctuation — receives comment-start syntax (\"<\") so the rest of
the line is treated as a comment."
  (goto-char start)
  (funcall
   (syntax-propertize-rules
    ;; The pattern matches either:
    ;;   group 1 present: a word character immediately before `#'
    ;;                    → relation separator, give `#' punctuation syntax
    ;;   group 1 absent:  a bare `#' not preceded by a word character
    ;;                    → comment start, give `#' comment-start syntax
    ((rx (or (group (any word) "#")
             "#"))
     (0 (if (match-beginning 1) "." "<"))))
   start end))

;;;;; Font-lock ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defconst fga--font-lock-keywords
  (list
   ;; schema version literal: the number after `schema'
   (list (rx "schema" (+ space) (group (+ (any digit "."))))
         1 'fga-schema-version-face)

   ;; `extend type NAME' — must precede the plain `type' rule
   (list (rx (group "extend") (+ space) (group "type") (+ space)
             (group (+ (any alnum "_" "-"))))
         '(1 'fga-keyword-face)
         '(2 'fga-keyword-face)
         '(3 'fga-type-name-face))

   ;; `type NAME'
   (list (rx line-start (* space) (group "type") (+ space)
             (group (+ (any alnum "_" "-"))))
         '(1 'fga-keyword-face)
         '(2 'fga-type-name-face))

   ;; `condition NAME'
   (list (rx line-start (* space) (group "condition") (+ space)
             (group (+ (any alnum "_" "-"))))
         '(1 'fga-keyword-face)
         '(2 'fga-condition-name-face))

   ;; `define RELATION:'
   (list (rx line-start (* space) (group "define") (+ space)
             (group (+ (any alnum "_"))) (* space) ":")
         '(1 'fga-keyword-face)
         '(2 'fga-relation-name-face))

   ;; direct type restriction bracket contents: [user, group#member]
   ;; Highlight the entire bracket content with fga-direct-rel-face first …
   (list (rx "[" (group (*? anything)) "]")
         1 'fga-direct-rel-face)

   ;; … then re-highlight the type#relation sub-expressions inside brackets.
   ;; This rule runs after the bracket rule and overrides it for type#rel spans.
   (list (rx (group (+ (any alnum "_" "-")))
             "#"
             (group (+ (any alnum "_" "-"))))
         '(1 'fga-relation-ref-type-face t)   ; t = override earlier face
         '(2 'fga-relation-ref-rel-face t))

   ;; public wildcard `*'
   (list (rx (group "*"))
         1 'fga-wildcard-face)

   ;; boolean / relation operators
   (list (rx symbol-start
             (group (or "or" "and" "but not" "from" "with" "not"))
             symbol-end)
         1 'fga-operator-face)

   ;; `self'
   (list (rx symbol-start (group "self") symbol-end)
         1 'fga-self-face)

   ;; remaining structural keywords without a following name
   (list (rx symbol-start
             (group (or "model" "schema" "relations"))
             symbol-end)
         1 'fga-keyword-face))
  "Font-lock keyword list for `fga-mode' (pure Elisp implementation).

Rules are ordered from most to least specific; font-lock applies them
in sequence and later rules can override earlier ones when the override
flag is t (used for relation-ref highlighting inside brackets).")

;;;;; Indentation ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun fga--indent-line ()
  "Indent the current line according to FGA DSL nesting rules."
  (let ((indent (fga--calculate-indent)))
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
  "Return non-nil if the current line begins (after whitespace) with KW."
  (save-excursion
    (back-to-indentation)
    (looking-at (concat (regexp-quote kw) "\\b"))))

(defun fga--calculate-indent ()
  "Return the target indentation column for the current line.

  Level 0  `model', `type', `extend type', `condition'
  Level 1  `relations'
  Level 2  `define'
  Other    inherit nearest preceding non-blank line's indentation"
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
        (or (fga--prev-meaningful-indent cur-pos) 0))))))

(defun fga--prev-meaningful-indent (limit)
  "Return the indentation of the first non-blank line before LIMIT."
  (save-excursion
    (goto-char limit)
    (forward-line -1)
    (while (and (not (bobp))
                (looking-at "^[[:space:]]*$"))
      (forward-line -1))
    (if (bobp) 0
      (back-to-indentation)
      (current-column))))

;;;;; Imenu ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

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
Sections: Types (including `extend type'), Conditions, Relations.")

;;;;; Mode ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(define-derived-mode fga-mode prog-mode "FGA"
  "Major mode for OpenFGA DSL authorization model files (.fga).

Pure Elisp implementation — see `fga-ts-mode' for the tree-sitter variant.
`#' is handled via `fga-syntax-propertize': when preceded by a word char
it is the type#relation separator; otherwise it starts a line comment.

\\{fga-mode-map}"
  :syntax-table fga-mode-syntax-table
  (fga--set-common-locals)
  ;; Disambiguate `#' as relation separator vs. comment
  (setq-local syntax-propertize-function #'fga-syntax-propertize)
  (setq-local font-lock-defaults '(fga--font-lock-keywords nil nil nil nil))
  (setq-local indent-line-function #'fga--indent-line)
  (setq-local electric-indent-chars (append ":{}" electric-indent-chars))
  (setq-local imenu-generic-expression fga--imenu-generic-expression)
  (font-lock-mode 1))


;;;; ================================================================
;;;; PART 2 — Tree-sitter mode: `fga-ts-mode'  (Emacs 29+)
;;;; ================================================================
;;
;; Grammar: https://github.com/matoous/tree-sitter-fga
;;
;; Node types (verified against the parsed tree in nvim-treesitter PR #7992):
;;
;;   source_file
;;   model, schema, version
;;   type_declaration, identifier
;;   relations, definition
;;   relation_def, direct_relationship, indirect_relation
;;   relation_ref          — (identifier) "#" (identifier)
;;   conditional           — "with" (identifier)
;;   operator              — "and" / "or" / "but not"
;;   condition_declaration, param, type_identifier, condition_body
;;   call_expression, selector_expression, argument_list
;;   comment               — # … newline
;;
;; The grammar gives `#' the correct syntactic role in every context, so
;; `fga-syntax-propertize' is NOT used in this mode.

(when (and (fboundp 'treesit-available-p) (treesit-available-p))
  (require 'treesit)

  ;;;;; Indentation rules ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
  ;;
  ;; Defined as a defvar (not defconst) outside the mode body because it
  ;; references `fga-indent-offset' at eval time via backquote, which is
  ;; fine — it's just a number, not a grammar query.

  (defvar fga-ts-indent-rules
    `((fga
       ;; Top-level: no indent
       ((parent-is "source_file") column-0 0)

       ;; Closing brace back to its parent
       ((node-is "}") parent-bol 0)

       ;; Inside a relations block
       ((parent-is "relations") parent-bol ,fga-indent-offset)

       ;; Inside a condition body  { ... }
       ((parent-is "condition_body") parent-bol ,fga-indent-offset)

       ;; Multi-line relation_def (and / or / but not chains)
       ((parent-is "relation_def") parent-bol ,fga-indent-offset)

       ;; Condition parameter list
       ((parent-is "param") parent-bol ,fga-indent-offset)

       ;; Fallback
       (no-node parent-bol 0)
       (catch-all parent-bol 0)))
    "Tree-sitter indentation rules for `fga-ts-mode'.")

  ;;;;; Imenu ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

  (defvar fga-ts-imenu-settings
    '(("Types"      "type_declaration"      nil nil)
      ("Conditions" "condition_declaration" nil nil))
    "Imenu settings for `fga-ts-mode'.
Relations are not indexed here because `define' nodes are deeply nested
and the same name may appear in many types; use `fga-goto-define' instead.")

  ;;;;; Mode ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

  ;;;###autoload
  (define-derived-mode fga-ts-mode prog-mode "FGA[ts]"
    "Major mode for OpenFGA DSL files (.fga), powered by tree-sitter.

Requires Emacs 29+ and the `fga' tree-sitter grammar.  To install:

  (add-to-list \\='treesit-language-source-alist
               \\='(fga \"https://github.com/matoous/tree-sitter-fga\"))
  (treesit-install-language-grammar \\='fga)

The tree-sitter grammar parses `#' in context: inside `relation_ref'
nodes (e.g. [group#member]) it is a structural token, never a comment.
No `syntax-propertize-function' is needed.

Falls back to `fga-mode' when the grammar is not available.

\\{fga-mode-map}"
    :syntax-table fga-mode-syntax-table

    ;; Guard: fall back to fga-mode if the grammar is absent.
    ;; We cannot use `cl-return-from' here because `define-derived-mode'
    ;; does not establish a named block; use a top-level `if' instead.
    (if (not (treesit-ready-p 'fga))
        (progn
          (message "fga-ts-mode: `fga' grammar not found — falling back to fga-mode")
          (fga-mode))

      (fga--set-common-locals)
      (treesit-parser-create 'fga)

      ;; Font-lock rules are built here, inside the mode body, not at
      ;; load time.  `treesit-font-lock-rules' validates node names
      ;; against the live grammar, so it must run after the parser is
      ;; created.  Building them here also means re-loading the file
      ;; after installing the grammar will always pick up a fresh set.
      ;;
      ;; Keywords present in the grammar (from tree-sitter-fga grammar.js):
      ;;   "model"  "schema"  "type"  "relations"  "define"
      ;;   "condition"  "extend"  "module"
      ;; `module' is used in module-file declarations (e.g. `module hardware_type').
      (setq-local treesit-font-lock-settings
                  (treesit-font-lock-rules

                   :language 'fga
                   :feature 'comment
                   '((comment) @fga-comment-face)

                   :language 'fga
                   :feature 'keyword
                   ;; `module' appears in module-file declarations:
                   ;;   module hardware_type
                   ;; `extend' and `type' are separate tokens in `extend type'.
                   '(["model" "schema" "type" "relations" "define"
                      "condition" "extend" "module"]
                     @fga-keyword-face)

                   :language 'fga
                   :feature 'constant
                   '((version) @fga-schema-version-face)

                   :language 'fga
                   :feature 'type
                   ;; type declaration names and condition parameter types
                   '((type_declaration (identifier) @fga-type-name-face)
                     (type_identifier) @fga-type-name-face)

                   :language 'fga
                   :feature 'definition
                   ;; relation name on the left-hand side of `define RELATION:'
                   '((definition (identifier) @fga-relation-name-face))

                   :language 'fga
                   :feature 'function
                   ;; condition name; method calls in condition bodies
                   '((condition_declaration (identifier) @fga-condition-name-face)
                     (call_expression
                      function: (selector_expression
                                 field: (identifier) @font-lock-function-call-face)))

                   :language 'fga
                   :feature 'variable
                   ;; condition parameter names and relation-reference identifiers
                   '((param (identifier) @font-lock-variable-use-face)
                     (indirect_relation (identifier) @font-lock-variable-use-face)
                     (conditional (identifier) @font-lock-variable-use-face))

                   :language 'fga
                   :feature 'relation-ref
                   ;; [group#member] — `relation_ref' node has two (identifier)
                   ;; children separated by "#".  The grammar knows this is not
                   ;; a comment, so no syntax-propertize is needed.
                   '((relation_ref
                      (identifier) @fga-relation-ref-type-face
                      (identifier) @fga-relation-ref-rel-face))

                   :language 'fga
                   :feature 'operator
                   '((operator) @fga-operator-face
                     ["from" "with"] @fga-operator-face)

                   :language 'fga
                   :feature 'bracket
                   '(["(" ")" "[" "]" "{" "}"] @font-lock-bracket-face)))

      (setq-local treesit-font-lock-feature-list
                  '((comment)
                    (keyword constant)
                    (type definition function)
                    (variable relation-ref operator bracket)))

      ;; Indentation
      (setq-local treesit-simple-indent-rules fga-ts-indent-rules)
      (setq-local indent-line-function #'treesit-indent)

      ;; Imenu — Types and Conditions via treesit; Relations via fga-goto-define
      (setq-local treesit-simple-imenu-settings fga-ts-imenu-settings)
      (setq-local imenu-create-index-function #'treesit-simple-imenu)

      ;; which-func / breadcrumb
      (setq-local treesit-defun-type-regexp
                  (rx (or "type_declaration" "condition_declaration")))

      (setq-local electric-indent-chars (append ":{}" electric-indent-chars))

      (treesit-major-mode-setup)))

  ) ; end (when treesit-available-p ...)


;;;; ================================================================
;;;; PART 3 — fga.mod manifest mode
;;;; ================================================================

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
   ;; Comments: the propertize function is NOT active here, but `#' in a
   ;; manifest file is always a comment (no type#relation syntax in .mod),
   ;; so we can match it directly in font-lock.
   (list (rx "#" (* nonl)) 0 'fga-comment-face))
  "Font-lock keyword list for `fga-mod-mode'.")

;;;###autoload
(define-derived-mode fga-mod-mode text-mode "FGA-Mod"
  "Major mode for OpenFGA modular model manifest files (fga.mod).

A fga.mod file lists the schema version, an optional module name, and
the .fga source files that together form a modular authorization model:

  schema 1.2
  module my-app
  contents:
    - core.fga
    - projects.fga

`#' is always a line comment in manifest files — there are no
type#relation references in this format.

\\{fga-mode-map}"
  :syntax-table fga-mode-syntax-table
  ;; In .mod files `#' IS always a comment, so we give it comment syntax
  ;; directly rather than via syntax-propertize.
  (modify-syntax-entry ?# "<" fga-mode-syntax-table)
  (setq-local font-lock-defaults '(fga--mod-font-lock-keywords nil nil))
  (setq-local comment-start "# ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "#+[[:space:]]*")
  (setq-local indent-tabs-mode nil)
  (font-lock-mode 1))


;;;; ──────────────────────────────────────────────────────────────
;;;; Auto-mode associations
;;;; ──────────────────────────────────────────────────────────────

;;;###autoload
(defun fga--auto-mode ()
  "Activate `fga-ts-mode' or `fga-mode' based on tree-sitter availability."
  (if (and (fboundp 'treesit-available-p)
           (treesit-available-p)
           (treesit-ready-p 'fga t))   ; t = quiet, no error if grammar absent
      (fga-ts-mode)
    (fga-mode)))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.fga\\'" . fga--auto-mode))

;;;###autoload
(add-to-list 'auto-mode-alist '("fga\\.mod\\'" . fga-mod-mode))


(provide 'fga-mode)

;;; fga-mode.el ends here
