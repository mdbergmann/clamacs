;;;; test-mailbox.lisp -- the mailbox (lisp/mailbox.lisp): what the other
;;;; threads post, run by the editor's task.

(in-package :clamacs)

(defun mailbox-wait-for (predicate &optional (seconds 30))
  (let ((deadline (+ (get-universal-time) seconds)))
    (loop
      (when (funcall predicate) (return t))
      (when (> (get-universal-time) deadline) (return nil))
      (sleep 0.01))))

(deftest mailbox-drain-runs-what-was-posted-in-order
  (let* ((woken 0) (drains 0) (ran '())
         (box (make-mailbox :wake (lambda () (incf woken))
                            :after-drain (lambda () (incf drains)))))
    (is (not (mailbox-drain box)))
    (is-equal drains 0)
    (mailbox-post box (lambda () (push 1 ran)) :wait nil)
    (mailbox-post box (lambda () (push 2 ran)) :wait nil)
    (is-equal woken 2)
    (is-equal ran '())
    (is (mailbox-drain box))
    (is-equal (reverse ran) '(1 2))
    (is-equal drains 1)
    (is (not (mailbox-drain box)))
    (is-equal drains 1)))

(deftest mailbox-waiting-post-gets-the-values-from-another-thread
  (let* ((box (make-mailbox))
         (answer nil)
         (thread (mp:make-thread
                  (lambda ()
                    (setq answer (multiple-value-list
                                  (mailbox-post box (lambda () (values 1 "two" :three))))))
                  :name "test-mailbox-post")))
    ;; Play the editor's task until the poster has its answer
    (is (mailbox-wait-for (lambda ()
                            (mailbox-drain box)
                            (not (mp:thread-alive-p thread)))))
    (is-equal answer '(1 "two" :three))))

(deftest mailbox-error-in-a-waited-closure-answers-rc-fatal
  (let* ((box (make-mailbox))
         (answer nil)
         (thread (mp:make-thread
                  (lambda ()
                    (setq answer (multiple-value-list
                                  (mailbox-post box (lambda () (error "boom ~A" 7))))))
                  :name "test-mailbox-error")))
    (is (mailbox-wait-for (lambda ()
                            (mailbox-drain box)
                            (not (mp:thread-alive-p thread)))))
    (is-equal (first answer) +rc-fatal+)
    (is-equal (second answer) "ERROR: boom 7")))

(deftest mailbox-error-in-a-posted-closure-goes-to-on-error
  (let* ((reported '())
         (drains 0)
         (box (make-mailbox :on-error (lambda (e) (push (princ-to-string e) reported))
                            :after-drain (lambda () (incf drains))))
         (ran nil))
    (mailbox-post box (lambda () (error "quietly")) :wait nil)
    (mailbox-post box (lambda () (setq ran t)) :wait nil)
    (is (mailbox-drain box))
    (is-equal reported '("quietly"))
    ;; The failure did not stop the batch, and the drain still counted
    (is ran)
    (is-equal drains 1)))

(deftest mailbox-closed-refuses-posts-and-frees-waiters
  (let* ((box (make-mailbox))
         (answer nil)
         (thread (mp:make-thread
                  (lambda ()
                    (setq answer (multiple-value-list
                                  (mailbox-post box (lambda () :never)))))
                  :name "test-mailbox-close")))
    ;; The poster is parked; closing wakes it with the shutdown answer
    (is (mailbox-wait-for (lambda () (mailbox-items box))))
    (mailbox-close box)
    (is (mailbox-wait-for (lambda () (not (mp:thread-alive-p thread)))))
    (is-equal (first answer) +rc-fatal+)
    (is (search "shutting down" (second answer)))
    ;; A later post is refused at once, waiting or not
    (is-equal (multiple-value-list (mailbox-post box (lambda () 1)))
              (list +rc-fatal+ "ERROR: the editor is shutting down"))
    (is-equal (first (multiple-value-list (mailbox-post box (lambda () 1) :wait nil)))
              +rc-fatal+)
    (mailbox-close nil)))

(deftest call-in-editor-goes-through-the-editors-mailbox
  (let ((editor (make-fake-editor)))
    ;; No mailbox: no editor is running
    (is-equal (first (multiple-value-list (call-in-editor editor (lambda () 1))))
              +rc-fatal+)
    (let ((box (make-mailbox))
          (got nil))
      (setf (editor-mailbox editor) box)
      (call-in-editor editor (lambda () (setq got :posted)) :wait nil)
      (is (null got))
      (mailbox-drain box)
      (is-equal got :posted))))
