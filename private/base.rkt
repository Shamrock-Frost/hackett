#lang curly-fn racket/base

(require racket/require)

(require (for-syntax (multi-in racket [base dict format function list match splicing syntax])
                     (multi-in rascal [private/type util/stx])
                     (multi-in syntax/parse [class/local-value define
                                             experimental/specialize experimental/template])
                     (only-in srfi/1 list-index)
                     macrotypes/stx-utils
                     point-free
                     syntax/id-table)
         (for-meta 2 racket/base
                     syntax/transformer)
         (only-in macrotypes/typecheck postfix-in type-error)
         (postfix-in - (multi-in racket [base format]))
         syntax/id-table
         syntax/parse/define)

(provide (for-syntax (all-defined-out)
                     (all-from-out rascal/private/type))
         (all-defined-out))

;; ---------------------------------------------------------------------------------------------------
;; type constructors

(define-syntax (∀ stx) (raise-syntax-error #f "∀ cannot be used as an expression" stx))
(define-syntax (⇒ stx) (raise-syntax-error #f "⇒ cannot be used as an expression" stx))

(define-syntax-parser define-base-type
  [(_ τ:id
      {~or {~optional {~seq #:constructors constructors:expr}
                      #:defaults ([constructors #'#f])}
           other-option}
      ...)
   #'(begin
       (define-syntax τ (base-type #'τ constructors))
       (begin-for-syntax
         (define-base-type τ #:constructors constructors other-option ...)))])

(define-base-type → #:arity 2)
(define-base-type Integer)
(define-base-type String)

(begin-for-syntax
  ; a → type constructor that supports multiple arguments
  (define →/curried
    (match-lambda*
      [(list τa τb)
       (→ τa τb)]
      [(list τ τs ..2)
       (→ τ (apply →/curried τs))]))

  ; like →/curried, but interprets (→ τ) as τ
  (define →/curried*
    (match-lambda*
      [(list τ) τ]
      [other (apply →/curried other)]))

  (register-custom-type-printer!
   #'→ (match-lambda
         [(→ τa τb)
          (format "(→ ~a ~a)" (type->string τa) (type->string τb))])))

;; ---------------------------------------------------------------------------------------------------
;; types

(begin-for-syntax
  (define-syntax-class/specialize local-value/class
    (local-value class? #:failure-message "identifier was not bound to a class"))

  (define (type-eval stx #:ctx [ctx '()])
    (parameterize ([current-type-var-environment (extend-type-var-environment ctx)])
      (let loop ([stx stx])
        (syntax-parse stx
          #:context 'type-eval
          #:literals [∀ ⇒]
          [τ:id
           (or (free-id-table-ref (current-type-var-environment) #'τ #f)
               (syntax-local-value #'τ))]
          [(∀ [α:id ...] τ)
           #:do [(define α-types (map fresh (attribute α)))
                 (define α-ids (map τvar-id α-types))
                 (define τ* (type-eval #'τ #:ctx (map cons (attribute α) α-types)))
                 ; call type-free-vars to get the order the type variables appear in τ; this assures
                 ; they will have a canonical order, which allows type=? to work more easily
                 (define α-ids* (filter #{member % α-ids free-identifier=?}
                                        (type-free-vars τ*)))]
           (∀ α-ids* τ*)]
          [(⇒ [(class:local-value/class τ_pred) ...] τ)
           #:do [(define τ_preds (map loop (attribute τ_pred)))]
           (⇒ (map has-class (attribute class.local-value) τ_preds) (loop #'τ))]
          [(τ a)
           (τapp (loop #'τ)
                 (loop #'a))]
          [(τ a as ...)
           (loop #'((τ a) as ...))]))))

  (define-simple-macro (⊢ e {~literal :} τ)
    (assign-type #`e (type-eval #`τ))))

;; ---------------------------------------------------------------------------------------------------
;; general typed forms

(begin-for-syntax
  ; (listof identifier?) (listof type?) (listof syntax?)
  ; -> (or/c (list (listof type?) (listof identifier?) (listof syntax?))
  (define (typecheck-annotated-bindings xs τs_annotated exprs
                                        #:body [body #f]
                                        #:existing-dict-mapping [dict-mapping '()])
    ; run the typechecker
    (define-values [τs_inferred xs- exprs- τ_body body-]
      (let ([ctx (map cons xs τs_annotated)])
        (if body
            (let-values ([(τs xs- vals-) (infers+erase (cons body exprs) #:ctx ctx)])
              (values (rest τs) xs- (rest vals-) (first τs) (first vals-)))
            (let-values ([(τs xs- vals-) (infers+erase exprs #:ctx ctx)])
              (values τs xs- vals- #f #f)))))

    ; solve constraints and apply the resulting substitutions
    (define-values [annotation-constraints annotation-substs]
      (for/lists [constraints substs]
                 ([τ_annotated (in-list τs_annotated)]
                  [τ_inferred (in-list τs_inferred)]
                  [expr (in-list exprs)])
        (match-let*-values ([(τ_normalized) (type->normalized-scheme τ_annotated)]
                            ; TODO: actually validate that the preds in annotations are valid
                            [((⇒ _ τ) subst) (instantiate-type/subst τ_normalized)])
          (values (τ~ τ τ_inferred expr) subst))))
    (define subst (solve-constraints (append (collect-constraints (datum->syntax #f exprs-))
                                             annotation-constraints)))
    (define τs_substituted (map #{apply-subst subst %} τs_inferred))
    (define τ_body_substituted (and~> τ_body #{apply-subst subst %}))
    (define dict-mappings-substituted
      (for/list ([annotation-subst (in-list annotation-substs)])
        (for/list ([mapping (in-list dict-mapping)])
          (cons (apply-subst subst (apply-subst annotation-subst (car mapping)))
                (cdr mapping)))))

    ; collect predicates and apply the substitutions to those, too, then typecheck them
    (define predicatess (map collect-predicates exprs-))
    (define substituted-predicatess (map #{map #{apply-subst subst %} %} predicatess))
    (define reduced-predicatess
      (for/list ([predicates (in-list substituted-predicatess)])
        (reduce-context predicates)))

    ; generalize the resulting types, apply the results to the original syntax and return everything
    (define τs_generalized (map generalize-type (map ⇒ reduced-predicatess τs_substituted)))
    (let ([vals-generalized
           (for/list ([expr- (in-list exprs-)]
                      [τ (in-list τs_generalized)]
                      [preds (in-list reduced-predicatess)]
                      [dict-mapping (in-list dict-mappings-substituted)])
             (~> (apply-substitutions-to-types subst expr-)
                 #{erase-typeclasses % preds #:existing-dict-mapping dict-mapping}
                 #{assign-type % τ}))])
      (if body
          (list τs_generalized xs- vals-generalized τ_body_substituted body-)
          (list τs_generalized xs- vals-generalized)))))

(define-syntax (def stx) (raise-syntax-error #f "can only be used at the top level of a module" stx))

(define-syntax-parser λ1
  [(_ x:id e:expr)
   #:do [(define τv (fresh))
         (define/infer+erase [τ [x-] e-] #'e #:ctx (list (cons #'x τv)))]
   (assign-type #'(λ- (x-) e-)
                (→ τv τ))])

(define-syntax-parser λ
  [(_ (x:id) e:expr)
   #'(λ1 x e)]
  [(_ (x:id xs:id ...) e:expr)
   #'(λ1 x (λ (xs ...) e))])

(define-syntax-parser hash-percent-app1
  [(_ fn arg)
   #:do [(define τv (fresh))
         (define/infer+erase [τ_fn [] fn-] #'fn)
         (define/infer+erase [τ_arg [] arg-] #'arg)]
   (assign-constraint (assign-type (syntax/loc this-syntax
                                     (#%app- fn- arg-))
                                   τv)
                      τ_fn (→ τ_arg τv))])

(define-syntax-parser hash-percent-app
  [(_ fn arg)
   (syntax/loc this-syntax
     (hash-percent-app1 fn arg))]
  [(_ fn arg args ...+)
   (quasisyntax/loc this-syntax
     (hash-percent-app #,(syntax/loc this-syntax
                           (hash-percent-app1 fn arg))
                       args ...))])

(define-syntax-parser hash-percent-datum
  [(_ . n:integer)
   (⊢ (#%datum- . n) : Integer)]
  [(_ . n:str)
   (⊢ (#%datum- . n) : String)]
  [(_ . x)
   (type-error #:src #'x #:msg "Unsupported literal: ~v" #'x)])

(define-syntax-parser hash-percent-module-begin
  #:literals [def]
  [(_ {~seq {~or {~seq {~seq {~and definition (def . _)} ...+}
                       {~seq {~and other-form {~not (def . _)}} ...}}
                 {~seq {~seq {~and definition (def . _)} ...}
                       {~seq {~and other-form {~not (def . _)}} ...+}}}}
      ...)
   (template
    (#%plain-module-begin-
     (?@ (top-level-definitions definition ...)
         other-form ...)
     ...))])

(define-syntax-parser top-level-definitions
  #:literals [: def]
  [(_ (def x:id : τ-ann expr) ...)
   #:do [(match-define {list τs xs- vals-}
           (typecheck-annotated-bindings (attribute x)
                                         (map type-eval (attribute τ-ann))
                                         (attribute expr)))]
   #:with [[τ-proxy ...] [x- ...] [val- ...]] (list (map property-proxy τs) xs- vals-)
   #:with [main-submodule ...]
          (let ([n (list-index #{eq? 'main (syntax-e %)} (attribute x))])
            (if n
                #`((module+- main (println- #,(list-ref (attribute x-) n))))
                #'()))
   #'(begin-
      (define- x- val-) ...
      (define-syntax x
        (make-variable-like-transformer/thunk
         (λ (stx) (assign-type #'x- (instantiate-type (property-proxy-value #'τ-proxy))))))
      ...
      main-submodule ...)])

(define-syntax-parser let1
  [(_ [x:id val:expr] e:expr)
   #:do [(define/infer+erase [τ_val [] val-] #'val)
         (define subst (solve-constraints (collect-constraints #'val-)))
         (define τ_substituted (apply-subst subst τ_val))
         (define τ_generalized (generalize-type τ_substituted))]
   #:with val-* (assign-type #'val- τ_generalized)
   #:do [(define/infer+erase [τ [x-] e-] #'e #:ctx (list (cons #'x τ_generalized)))]
   (assign-type (syntax/loc this-syntax
                  (let- ([x- val-*]) e-))
                τ)])

(define-syntax-parser let
  [(_ () e:expr)
   #'e]
  [(_ ([x:id val:expr] [xs:id vals:expr] ...) e:expr)
   #'(let1 [x val]
       (let ([xs vals] ...)
         e))])

(define-syntax-parser :
  [(_ e:expr τ-expr)
   #:do [(define τ (type-eval #'τ-expr))
         (define/infer+erase [τ_inferred [] e-] #'e)]
   (assign-constraint (assign-type #'e- τ) τ τ_inferred)])

(define-syntax-parser letrec
  #:literals [:]
  [(_ ([x:id : τ-ann val:expr] ...) body:expr)
   #:do [(match-define {list _ xs- vals- τ_body body-}
           (typecheck-annotated-bindings (attribute x)
                                         (map type-eval (attribute τ-ann))
                                         (attribute val)
                                         #:body #'body))]
   #:with [[x- ...] [val- ...] body-] (list xs- vals- body-)
   (assign-type (syntax/loc this-syntax
                  (letrec- ([x- val-] ...) body-))
                τ_body)])

;; ---------------------------------------------------------------------------------------------------
;; typeclasses

(define (method-stub . _)
  (error 'method-stub "should never be called"))

(begin-for-syntax
  ; TODO: move this somewhere else and make types vs quantified types vs schemes more disciplined
  (define type->normalized-scheme
    (match-lambda
      [{and τ (∀ _ (⇒ _ _))}
       τ]
      [(∀ αs τ)
       (∀ αs (⇒ '[] τ))]
      [{and τ (⇒ _ _)}
       (∀ '[] τ)]
      [τ
       (∀ '[] (⇒ '[] τ))])))

(define-syntax-parser class
  #:literals [:]
  [(_ (id:id α:id) [method:id : τ_method-ann] ...)
   #:do [(define τvar (fresh #'α))
         (define τs_methods (map #{type-eval % #:ctx (list (cons #'α τvar))}
                                 (attribute τ_method-ann)))]
   #:with [method-impl ...] (generate-temporaries (attribute method))
   #:do [; create the class representation itself and its method types
         (define method-table (make-free-id-table))
         (define class (make-class #'id method-table (τvar-id τvar)))
         (define τs_methods*
           (for/list ([τ_method (in-list τs_methods)])
             ; extend the existing list of quantified vars and preds
             (match-let ([(∀ αs (⇒ ctx τ)) (type->normalized-scheme τ_method)])
               (∀ (cons (τvar-id τvar) αs)
                  (⇒ (cons (has-class class τvar) ctx) τ)))))
         (for ([method-id (in-list (attribute method))]
               [τ_method (in-list τs_methods*)])
           (free-id-table-set! method-table method-id τ_method))]
   #:with class-proxy (property-proxy class)
   #:with [τ_method-proxy ...] (map property-proxy τs_methods*)
   #'(begin-
       (define-syntax id (property-proxy-value #'class-proxy))
       (define- (method-impl dict) (free-id-table-ref dict #'method)) ...
       (define-syntax method
         (make-variable-like-transformer/thunk
          (λ (stx) (assign-type (syntax/loc stx method-impl)
                                (instantiate-type (property-proxy-value #'τ_method-proxy))))))
       ...)])

(begin-for-syntax
  (define-syntax-class instance-spec
    #:attributes [class type]
    #:literals [∀ ⇒]
    [pattern (∀ αs (⇒ ~! preds (id:local-value/class τ)))
             #:attr class (attribute id.local-value)
             #:attr type (type-eval #'(∀ αs (⇒ preds τ)))]
    [pattern (⇒ ~! preds (id:local-value/class τ))
             #:attr class (attribute id.local-value)
             #:attr type (type-eval #'(∀ [] (⇒ preds τ)))]
    [pattern (∀ ~! αs (id:local-value/class τ))
             #:attr class (attribute id.local-value)
             #:attr type (type-eval #'(∀ αs (⇒ [] τ)))]
    [pattern (id:local-value/class τ)
             #:attr class (attribute id.local-value)
             #:attr type (type-eval #'(∀ [] (⇒ [] τ)))]))

(define-syntax-parser instance
  [(_ spec:instance-spec [method:id impl] ...)
   #:with dict-id (generate-temporary 'dict)
   #:with [specialized-method ...] (generate-temporaries (attribute method))
   #:do [(define class (attribute spec.class))

         (match-define (∀ _ (⇒ dict-preds _)) (attribute spec.type))
         (define dict-pred-ids (generate-temporaries dict-preds))
         (define dict-mapping (map cons dict-preds dict-pred-ids))

         (define method-table (class-method-table/instantiate class (attribute spec.type)))
         (define τs_methods (map #{free-id-table-ref method-table %} (attribute method)))
         (match-define {list _ _ impls-}
           (typecheck-annotated-bindings (attribute specialized-method)
                                         τs_methods
                                         (attribute impl)
                                         #:existing-dict-mapping dict-mapping))]
   #:with [impl- ...] impls-
   #:do [(register-class-instance! (attribute spec.class)
                                   (attribute spec.type)
                                   (instance (syntax-local-introduce #'dict-id))
                                   #:src this-syntax)
         (define (app/dict-preds stx)
           (for/fold ([stx stx])
                     ([pred-id (in-list dict-pred-ids)])
             #`(#,stx #,pred-id)))]
   #:with [specialized-method-sig ...] (map app/dict-preds (attribute specialized-method))
   #`(begin-
       (define- specialized-method-sig impl-) ...
       (define- #,(app/dict-preds #'dict-id)
         (make-immutable-free-id-table
          (list (cons #'method specialized-method-sig) ...))))])

;; ---------------------------------------------------------------------------------------------------
;; primitive operators

(define-simple-macro (define-primop id:id [e:expr {~literal :} τ])
  (define-syntax id (make-variable-like-transformer (⊢ e : τ))))

(define ((+/c a) b) (+- a b))
(define ((-/c a) b) (-- a b))
(define ((*/c a) b) (*- a b))

(define-primop + [+/c : (→ Integer (→ Integer Integer))])
(define-primop - [-/c : (→ Integer (→ Integer Integer))])
(define-primop * [*/c : (→ Integer (→ Integer Integer))])
(define-primop show/Integer [~a- : (→ Integer String)])

(define ((string-append/c a) b) (string-append- a b))

(define-primop string-append [string-append/c : (→ String (→ String String))])