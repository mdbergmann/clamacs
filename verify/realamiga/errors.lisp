;;; errors.lisp -- deliberately broken, for the diagnostics leg of the test.
;;; Two errors, and a form after them: LOAD recovers per top-level form, so
;;; the editor must receive BOTH diagnostics, not just the first.

(defvar *errors-start* t)

(error "first deliberate error")

(no-such-function-in-this-image)

(defvar *errors-end* t)
