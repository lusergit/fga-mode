;;; fga-mode.el --- Major mode for OpenFGA files using tree-sitter -*- lexical-binding: t; -*-

(require 'treesit)

(defvar fga-ts-font-lock-settings
  (treesit-font-lock-rules
   :language 'fga
   :feature 'comment
   '((comment) @font-lock-comment-face)

   :language 'fga
   :feature 'keyword
   '((["model" "schema" "type" "relations" "define" "module"]) @font-lock-keyword-face)

   :language 'fga
   :feature 'operator
   '((["or" "and" "but not" "from" "as"]) @font-lock-keyword-face)

   :language 'fga
   :feature 'type
   '((type_name) @font-lock-type-face)

   :language 'fga
   :feature 'relation
   '((relation_name) @font-lock-function-name-face)

   :language 'fga
   :feature 'constant
   '((version) @font-lock-constant-face))
  "Tree-sitter font-lock settings for `fga-mode'.")

;;;###autoload
(define-derived-mode fga-mode prog-mode "FGA"
  "Major mode for editing OpenFGA files using tree-sitter."
  :group 'fga
  
  (when (treesit-ready-p 'fga)
    (treesit-parser-create 'fga)
    
    ;; Configure font-lock
    (setq-local treesit-font-lock-settings fga-ts-font-lock-settings)
    (setq-local treesit-font-lock-feature-list
                '((comment keyword operator)
                  (type relation constant)
                  () ()))
    
    ;; Setup tree-sitter indents if needed, or default to prog-mode fallback
    (treesit-major-mode-setup)))

;;;###autoload
(progn
  (add-to-list 'auto-mode-alist '("\\.fga\\'" . fga-mode))
  (add-to-list 'auto-mode-alist '("fga\\.mod\\'" . fga-mode)))

(provide 'fga-mode)
;;; fga-mode.el ends here
