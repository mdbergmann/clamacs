;;;; accounts.lisp -- a small ledger, for trying the editor on.
;;;;
;;;; Load it with C-c C-k, then talk to it at the REPL (C-c C-z):
;;;;
;;;;   (defparameter *acct* (open-account "Ada" 100))
;;;;   (deposit *acct* 50)
;;;;   (statement *acct*)

(in-package :cl-user)

(defstruct (account (:constructor %make-account))
  (owner "" :type string)
  (balance 0 :type integer)
  (history '() :type list))

(define-condition insufficient-funds (error)
  ((account :initarg :account :reader account)
   (amount :initarg :amount :reader amount))
  (:report (lambda (c stream)
             (format stream "~A cannot withdraw ~D: the balance is ~D"
                     (account-owner (account c)) (amount c)
                     (account-balance (account c))))))

(defun open-account (owner &optional (deposit 0))
  "A new account for OWNER, with DEPOSIT in it."
  (let ((acct (%make-account :owner owner)))
    (when (plusp deposit)
      (deposit acct deposit))
    acct))

(defun deposit (acct amount)
  "Put AMOUNT into ACCT; the new balance."
  (check-type amount (integer 1))
  (push (cons :deposit amount) (account-history acct))
  (incf (account-balance acct) amount))

(defun withdraw (acct amount)
  "Take AMOUNT out of ACCT, if it is there; the new balance."
  (when (> amount (account-balance acct))
    (error 'insufficient-funds :account acct :amount amount))
  (push (cons :withdrawal amount) (account-history acct))
  (decf (account-balance acct) amount))

(defun statement (acct &optional (stream *standard-output*))
  "Print ACCT's history, oldest entry first, then the balance."
  (format stream "~&Statement for ~A~%" (account-owner acct))
  (loop for (kind . amount) in (reverse (account-history acct))
        do (format stream "  ~12A ~6D~%" kind amount))
  (format stream "  ~12A ~6D~%" "balance" (account-balance acct))
  (account-balance acct))
