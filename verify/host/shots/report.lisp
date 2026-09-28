;;;; report.lisp -- the accounts of accounts.lisp, printed together.
;;;;
;;;; Two mistakes are in here on purpose: C-c C-k lists them in the
;;;; diagnostics window, and C-x ` walks to them.

(in-package :cl-user)

(defparameter *accounts*
  (list (open-account "Ada" 120)
        (open-account "Grace" 75)
        (open-account "Linus" 40)))

(defun total-balance (accounts)
  (reduce #'+ accounts :key #'account-balance))

(defun print-report (accounts)
  (dolist (acct accounts)
    (statement acct))
  (format t "~&Total: ~D~%" (total-balance accounts)))

(print-report *accounts* :verbose t)

(defun richest (accounts)
  (first (sort (copy-list accounts) #'> :key #'account-balance)))

(richest *acounts*)
