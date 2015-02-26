(in-package :cl-user)
(defpackage dyna.error
  (:use :cl))
(in-package :dyna.error)

(syntax:use-syntax :annot)

@export
(define-condition <dyna-error> (simple-error) ())

@export
(define-condition <dyna-request-error> (<dyna-error>)
  ((status :initarg :status)
   (meta :initarg :meta)
   (message :initarg :message))
  (:report
   (lambda (condition stream)
     (format stream
             "Error occured in request.~%Sattus:~a~%Messssage: ~a~%Meta: ~a."
             (slot-value condition 'status)
             (slot-value condition 'message)
             (let ((meta (slot-value condition 'meta)))
               (etypecase meta
                 (cons meta)
                 (hash-table (alexandria:hash-table-plist meta))))))))

@export
(define-condition <dyna-incomplete-argumet-error> (<dyna-error>)
  ((args :initarg :args))
  (:report
   (lambda (condition stream)
     (format stream
             "You must complete ~{:~a~^,~}."
             (slot-value condition 'args)))))

@export
(define-condition <dyna-incompatible-table-schema> (<dyna-error>)
  ((table :initarg :table))
  (:report
   (lambda (condition stream)
     (format stream
             "Table:~a is incompatible with the table schema in DynamoDB."
             (slot-value condition 'table)))))
