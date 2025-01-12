(in-package :cl-user)
(defpackage dyna.sxql
  (:use :cl
        :dyna.error
        :dyna.util
        :dyna.column
        :dyna.table)
  (:import-from :sxql.sql-type
                :conjunctive-op
                :conjunctive-op-name
                :conjunctive-op-expressions
                :make-conjunctive-op
                :unary-op
                :unary-op-var
                :infix-op
                :infix-list-op
                :conjunctive-op
                :sql-op-name
                :infix-op-name
                :infix-op-left
                :infix-op-right
                :infix-list-op-name
                :infix-list-op-left
                :infix-list-op-right
                :sql-symbol
                :sql-symbol-name
                :sql-variable
                :sql-variable-value)
  (:import-from :sxql.clause
                :where-clause
                :where-clause-expression
                :make-where-clause)
  (:import-from :sxql.operator
                :define-op
                :=-op
                :is-null-op
                :not-null-op)
  (:import-from :alexandria
                :ensure-list
                :make-keyword
                :length=
                :flatten
                :symbolicate)
  (:import-from :c2mop
                :class-direct-slots
                :slot-definition-name))
(in-package :dyna.sxql)

(syntax:use-syntax :annot)

(defmacro define-sxql-op (sym type)
  `(progn
     (define-op (,sym ,type :package :dyna.sxql))
     (import (symbolicate ,sym '-op) (find-package 'sxql.operator))
     (import (symbolicate 'make- ,sym '-op) (find-package 'sxql.operator))))

(cl-package-locks:with-packages-unlocked 'sxql.operator
  (define-sxql-op :list-in infix-list-op)
  (define-sxql-op :list= infix-list-op)
  (define-sxql-op :between infix-list-op)
  (define-sxql-op :list-in infix-list-op)
  (define-sxql-op :begins-with infix-op)
  (define-sxql-op :between infix-list-op)
  (define-sxql-op :contains infix-op)
  (define-sxql-op :begins-with infix-op)
  (define-sxql-op :contains infix-op))

(defun op-comparison-name (op)
  (let ((op-name (make-keyword (sql-op-name op))))
    (case op-name
      (:= "EQ")
      (:> "GT")
      (:>= "GE")
      (:< "LT")
      (:<= "LE")
      (:list= "EQ")
      (:between "BETWEEN")
      (:|BEGINS WITH| "BEGINS_WITH")
      (t nil))))

@export
(defgeneric yield (obj table)
  (:method (obj table)
    (declare (ignore table))
    (error '<dyna-unsupported-op-erorr> :op obj))

  (:method ((sym sql-symbol) table)
    (let ((slot (find-slot-by-name (sql-symbol-name sym) table)))
      (if slot (attr-name slot) (sql-symbol-name sym))))

  (:method ((var sql-variable) table)
    (sql-variable-value var)))

(defun find-slot-by-name (name class)
  (find (etypecase name
          (symbol (symbol-name name))
          (string (format nil "~@:(~a~)" name)))
        (class-direct-slots class)
        :key #'(lambda (slot)
                 (symbol-name (slot-definition-name slot)))
        :test #'equal))

@export
(defgeneric queryable-op-p (op table)
  (:method ((where-clause where-clause) table)
    (queryable-op-p (where-clause-expression where-clause) table))

  (:method ((op conjunctive-op) table)
    (let ((expressions (conjunctive-op-expressions op)))
      (and (and-op-p op)
           (some #'(lambda (op)
                     (queryable-op-p op table))
                 expressions))))

  (:method ((op =-op) table)
    t)

  (:method ((op t) table)
    nil))

(defun conjunctive-op-p (op)
  (typep op 'conjunctive-op))

(defun and-op-p (op)
  (equal (conjunctive-op-name op) "AND"))

(defgeneric op-keys (op table)
  (:method ((op conjunctive-op) table)
    (mapcan #'(lambda (item) (op-keys item table))
            (conjunctive-op-expressions op)))

  (:method ((op infix-op) table)
    (list (yield (infix-op-left op) table)))

  (:method ((op unary-op) table)
    (list (yield (unary-op-var op) table)))

  (:method ((op infix-list-op) table)
    (list (yield (infix-list-op-left op) table))))

(defgeneric op-values (op table)
  (:method ((op conjunctive-op) table)
    (mapcan #'(lambda (item) (op-values item table))
            (conjunctive-op-expressions op)))

  (:method ((op infix-op) table)
    (list (yield (infix-op-right op) table)))

  (:method ((op list=-op) table)
    (list (mapcar #'(lambda (item) (yield item table))
                  (infix-list-op-right op))))

  (:method ((op list-in-op) table)
    (mapcar #'(lambda (lst)
                (mapcar #'(lambda (item)
                            (yield item table))
                        lst))
            (infix-list-op-right op)))

  (:method ((op unary-op) table)
    (declare (ignore table))
    nil)

  (:method ((op infix-list-op) table)
    (mapcar #'(lambda (item) (yield item table))
            (infix-list-op-right op))))

(defun include-hash-key (keys table)
  (find (attr-name (table-hash-key table)) keys :test #'equal))

@export
(defun to-filter-expression (where-clause table)
  (let* ((expression (where-clause-expression where-clause))
         (keys (remove-duplicates (op-keys expression table) :test #'equal))
         (values (remove-duplicates (op-values expression table) :test #'equal))
         (attr-names (gen-attr-table keys "#filter"))
         (attr-values (gen-attr-table values ":filter")))
    (values (%to-filter-expression expression attr-names attr-values table)
            attr-names
            attr-values)))

(defun %to-filter-expression (expression name-env value-env table)
  (labels ((find-attr-thing (list) (lambda (item) (car (find-if #'(lambda (pair) (equal (cdr pair) item)) list))))
           (find-attr-name (name) (funcall (find-attr-thing name-env) name))
           (find-attr-value (value) (funcall (find-attr-thing value-env) value))
           (sub (exp)
             (etypecase exp
               (conjunctive-op (if (null (cdr (conjunctive-op-expressions exp)))
                                   (format nil "~a" (sub (car (conjunctive-op-expressions exp))))
                                   (format nil (format nil "(~~{~~a~~^ ~a ~~})" (conjunctive-op-name exp))
                                           (mapcar #'sub (conjunctive-op-expressions exp)))))
               (list-in-op (format nil "~a IN ~a"
                                   (find-attr-name (car (op-keys exp table)))
                                   (format nil "(~{~a~^,~})" (mapcar #'find-attr-value (op-values exp table)))))
               (not-null-op (format nil "attribute_exists( ~a )"
                                    (find-attr-name (car (op-keys exp table)))))
               (is-null-op (format nil "attribute_not_exists( ~a )"
                                   (find-attr-name (car (op-keys exp table)))))
               (begins-with-op (format nil "begins_with(~a, ~a)"
                                       (find-attr-name (car (op-keys exp table)))
                                       (find-attr-value (car (op-values exp table)))))
               (contains-op (format nil "contains(~a, ~a)"
                                    (find-attr-name (car (op-keys exp table)))
                                    (find-attr-value (car (op-values exp table)))))
               (infix-op (format nil "~a ~a ~a"
                                 (find-attr-name (car (op-keys exp table)))
                                 (infix-op-name exp)
                                 (find-attr-value (car (op-values exp table)))))
               (between-op (format nil "~a BETWEEN ~a"
                                   (find-attr-name (car (op-keys exp table)))
                                   (apply #'format nil "~a AND ~a"
                                          (mapcar #'find-attr-value (op-values exp table)))))
               (list=-op (format nil "~a = ~a"
                                 (find-attr-name (car (op-keys exp table)))
                                 (find-attr-value (car (op-values exp table)))))
               (infix-list-op (format nil "~a ~a ~a"
                                      (find-attr-name (car (op-keys exp table)))
                                      (infix-list-op-name exp)
                                      (format nil "(~{~a~^,~})" (mapcar #'find-attr-value (op-values exp table))))))))
    (sub expression)))

@export
(defgeneric to-key-conditions (op table)
  (:method ((clause where-clause) table)
    (multiple-value-bind (result index-name rest) (to-key-conditions (where-clause-expression clause) table)
      (if rest
          (multiple-value-bind (expression attr-names attr-values)
              (to-filter-expression (make-where-clause rest) table)
            (values result index-name expression attr-names attr-values))
          (values result index-name))))

  (:method ((op infix-list-op) table)
    `((,(yield (infix-list-op-left op) table)
       ("AttributeValueList" . ,(mapcar #'(lambda (op) (yield op table)) (infix-list-op-right op)))
       ("ComparisonOperator"  . ,(op-comparison-name op)))))

  (:method ((op infix-op) table)
    (let* ((attr-name (yield (infix-op-left op) table))
           (index (find attr-name (table-gsi table)
                        :test #'(lambda (name gsi)
                                  (equal name (attr-name (getf gsi :hash))))))
           (index-name (when index (gsi-to-index-name index)))
           (result `((,attr-name
                      ("AttributeValueList" . ,(ensure-list (yield (infix-op-right op) table)))
                      ("ComparisonOperator" . ,(op-comparison-name op))))))
      (if index
          (values result index-name)
          result)))

  (:method ((op list=-op) table)
    `((,(yield (list=-op-left op) table)
       ("AttributeValueList" . ,(mapcar #'(lambda (op) (yield op table)) (infix-list-op-right op)))
       ("ComparisonOperator"  . "EQ"))))

  (:method ((op conjunctive-op) table)
    (let ((hash-key (attr-name (table-hash-key table)))
          (range-key (attr-name (table-range-key table)))
          (lsi (mapcar #'attr-name (table-lsi table)))
          (using-range-key-p)
          (used-index)
          (rest))
      (values (mapcan #'(lambda (item)
                          (let ((attr-name (car (op-keys item table))))
                            (if (op-comparison-name item)
                                (if (and (equal attr-name hash-key)
                                         (typep item '=-op))
                                    (progn (setf used-index t)
                                           (to-key-conditions item table))
                                    (let ((index (and (not used-index)
                                                      (find attr-name (table-gsi table)
                                                            :test #'(lambda (name gsi)
                                                                      (equal name (attr-name (getf gsi :hash))))))))
                                      (if index
                                          (progn (setf used-index index)
                                                 (to-key-conditions item table))
                                          (if (not using-range-key-p)
                                              (cond
                                                ((equal attr-name range-key)
                                                 (progn (setf using-range-key-p t)
                                                        (to-key-conditions item table)))
                                                ((and (typep used-index 'cons)
                                                      (getf used-index :range)
                                                      (equal attr-name (attr-name (getf used-index :range))))
                                                 (progn (setf using-range-key-p t)
                                                        (to-key-conditions item table)))
                                                ((and (eq used-index t)
                                                      (find attr-name lsi :test #'equal))
                                                 (progn (setf using-range-key-p t)
                                                        (setf used-index (gen-lsi-name attr-name))
                                                        (to-key-conditions item table)))
                                                (t (progn (push item rest) nil)))
                                              (progn (push item rest) nil)))))
                                (progn (push item rest) nil))))
                      (conjunctive-op-expressions op))
              (when used-index
                (typecase used-index
                  (string used-index)
                  (cons (gsi-to-index-name used-index))
                  (t nil)))
              (when rest (apply #'make-conjunctive-op (conjunctive-op-name op) rest))))))
