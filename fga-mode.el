;;; fga-mode.el --- Major mode for OpenFGA files -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;; Major mode for OpenFGA models.
;; Supports both Tree-Sitter (requires Emacs 29.1+ and the fga grammar) 
;; and a standard regex font-lock fallback.

;;; Code:

(require 'rx)

(defgroup fga nil
  "Major mode for OpenFGA files."
  :group 'languages)

;; --- Syntax Table ---

(defvar fga-mode-syntax-table
  (let ((st (make-syntax-table)))
    ;; Comments start with # and end with a newline
    (modify-syntax-entry ?# "<" st)
    (modify-syntax-entry ?\n ">" st)
    ;; Treat underscores and dashes as part of words/symbols
    (modify-syntax-entry ?_ "_" st)
    (modify-syntax-entry ?- "_" st)
    st)
  "Syntax table for `fga-mode'.")

;; --- Regex Fallback Font-Lock ---

(defconst fga-font-lock-keywords
  `((,(rx symbol-start (or "model" "schema" "type" "relations" "define" "module") symbol-end) . font-lock-keyword-face)
    (,(rx symbol-start (or "or" "and" "but not" "from" "as") symbol-end) . font-lock-builtin-face)
    ;; Best-effort regex captures for types and relation names
    (,(rx "type" (+ space) (group (+ (or word ?_ ?-)))) (1 font-lock-type-face))
    (,(rx "define" (+ space) (group (+ (or word ?_ ?-)))) (1 font-lock-function-name-face)))
  "Regex-based font-lock keywords for `fga-mode' fallback.")

;; --- Tree-Sitter Setup ---

(defvar fga-ts-font-lock-settings
  (when (fboundp 'treesit-font-lock-rules)
    (treesit-font-lock-rules
     :language 'fga
     :feature 'comment
     '((comment) @font-lock-comment-face)

     :language 'fga
     :feature 'keyword
     '((["model" "schema" "type" "relations" "define" "module"]) @font-lock-keyword-face)

     :language 'fga
     :feature 'operator
     '((["or" "and" "but not" "from" "as"]) @font-lock-builtin-face)

     :language 'fga
     :feature 'type
     '((type_name) @font-lock-type-face)

     :language 'fga
     :feature 'relation
     '((relation_name) @font-lock-function-name-face)

     :language 'fga
     :feature 'constant
     '((version) @font-lock-constant-face)))
  "Tree-sitter font-lock settings for `fga-mode'.")

;;;###autoload
(define-derived-mode fga-mode prog-mode "FGA"
  "Major mode for editing OpenFGA files."
  :group 'fga
  :syntax-table fga-mode-syntax-table

  ;; Standard Emacs comment configuration
  (setq-local comment-start "# ")
  (setq-local comment-start-skip "#+ *")
  (setq-local comment-end "")

  (cond
   ;; 1. Modern setup: Tree-sitter (Emacs 29.1+)
   ((and (fboundp 'treesit-ready-p)
         (treesit-ready-p 'fga))
    (treesit-parser-create 'fga)
    (setq-local treesit-font-lock-settings fga-ts-font-lock-settings)
    (setq-local treesit-font-lock-feature-list
                '((comment keyword operator)
                  (type relation constant)
                  () ()))
    (treesit-major-mode-setup))

   ;; 2. Legacy setup: Standard Regex Fallback
   (t
    (setq-local font-lock-defaults '(fga-font-lock-keywords)))))

;;;###autoload
(progn
  (add-to-list 'auto-mode-alist '("\\.fga\\'" . fga-mode))
  (add-to-list 'auto-mode-alist '("fga\\.mod\\'" . fga-mode)))

(provide 'fga-mode)
;;; fga-mode.el ends here
