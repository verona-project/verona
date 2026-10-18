;;; verona-mode.el --- Major mode for Verona source files -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; This file is free and unencumbered software released into the public domain.
;; For more information, please refer to <https://unlicense.org>.

;;; Commentary:

;; `verona-mode' provides editing support for Verona's S-expression syntax.
;; It recognizes source files ending in .vrn or .verona, as well as a project's
;; verona.build file.  Semicolons introduce comments that continue to the end
;; of the line.

;;; Code:

(require 'lisp-mode)

(defgroup verona nil
  "Editing Verona source code."
  :group 'languages)

(defconst verona--declaration-forms
  '("type" "function" "external-function" "macro" "constant" "variable"
    "generic" "protocol" "implementation" "import" "export" "native-export")
  "Top-level Verona declaration forms.")

(defconst verona--special-forms
  '("product" "sum" "pointer" "array" "for" "let" "match" "return" "do"
    "address-of" "deref" "dereference" "load" "assign" "store" "cast" "field")
  "Verona forms with language-defined meaning outside ordinary calls.")

(defconst verona--builtin-types
  '("bool" "string" "void" "exit-code"
    "i8" "i16" "i32" "i64" "isize"
    "u8" "u16" "u32" "u64" "usize" "f32" "f64")
  "Built-in Verona type names.")

(defvar verona-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?\( "()" table)
    (modify-syntax-entry ?\) ")(" table)
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?\\ "\\" table)
    (modify-syntax-entry ?\; "<" table)
    (modify-syntax-entry ?\n ">" table)
    table)
  "Syntax table for `verona-mode'.")

(defvar verona-font-lock-keywords
  `((,(concat "(\\s-*\\_<" (regexp-opt verona--declaration-forms t) "\\_>")
     1 font-lock-keyword-face)
    (,(concat "(\\s-*\\_<" (regexp-opt verona--special-forms t) "\\_>")
     1 font-lock-builtin-face)
    (,(concat "\\_<" (regexp-opt verona--builtin-types t) "\\_>")
     . font-lock-type-face)
    ("\\_<\\(?:unit\\|true\\|false\\)\\_>" . font-lock-constant-face)
    ("#[+-][[:alnum:]_]+" . font-lock-preprocessor-face)
    ("\\_<[+-]?[0-9]+\\(?:\\.[0-9]+\\)?\\_>" . font-lock-constant-face)
    ("[+*/]\\|[-]\\|==\\|!=\\|<=\\|>=\\|<\\|>\\|&" . font-lock-builtin-face))
  "Font-lock rules for `verona-mode'.")

(defconst verona--body-forms
  '("function" "macro" "implementation" "protocol" "let" "match" "do")
  "Forms whose final argument is normally a body expression.")

(defun verona-indent-function (indent-point state)
  "Indent a Verona form at INDENT-POINT using parse STATE.

Declaration and expression forms use a Lisp-like two-space layout.  Ordinary
calls keep Emacs's standard Lisp indentation, which also gives aligned
arguments for short forms."
  (goto-char (1+ (nth 1 state)))
  (let ((head (when (looking-at "\\s-*\\(\\(?:\\sw\\|\\s_\\)+\\)")
                (match-string-no-properties 1))))
    (cond
     ((member head verona--body-forms)
      (lisp-indent-defform state indent-point))
     ((member head verona--declaration-forms)
      (lisp-indent-defform state indent-point))
     (t
      (lisp-indent-function indent-point state)))))

;;;###autoload
(define-derived-mode verona-mode prog-mode "Verona"
  "Major mode for editing Verona source code."
  :syntax-table verona-mode-syntax-table
  (setq-local font-lock-defaults '(verona-font-lock-keywords))
  (setq-local indent-line-function #'lisp-indent-line)
  (setq-local lisp-indent-function #'verona-indent-function)
  (setq-local comment-start ";")
  (setq-local comment-end "")
  (setq-local indent-tabs-mode nil))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.vrn\\'" . verona-mode))
;;;###autoload
(add-to-list 'auto-mode-alist '("\\.verona\\'" . verona-mode))
;;;###autoload
(add-to-list 'auto-mode-alist '("/verona\\.build\\'" . verona-mode))

(provide 'verona-mode)

;;; verona-mode.el ends here
