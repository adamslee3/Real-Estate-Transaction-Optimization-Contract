;; Document Management & Verification Smart Contract
;; A comprehensive contract for managing real estate property documents
;; with cryptographic verification and audit trails

;; === CONSTANTS ===

;; Error constants
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-NOT-FOUND (err u101))
(define-constant ERR-ALREADY-EXISTS (err u102))
(define-constant ERR-INVALID-HASH (err u103))
(define-constant ERR-INVALID-TYPE (err u104))
(define-constant ERR-PERMISSION-DENIED (err u105))
(define-constant ERR-DOCUMENT-LOCKED (err u106))
(define-constant ERR-INVALID-STATUS (err u107))

;; Document status constants
(define-constant STATUS-PENDING u0)
(define-constant STATUS-VERIFIED u1)
(define-constant STATUS-REJECTED u2)
(define-constant STATUS-ARCHIVED u3)

;; Document type constants
(define-constant TYPE-DEED u0)
(define-constant TYPE-TITLE u1)
(define-constant TYPE-INSPECTION u2)
(define-constant TYPE-APPRAISAL u3)
(define-constant TYPE-SURVEY u4)
(define-constant TYPE-OTHER u99)

;; === DATA VARIABLES ===

;; Contract owner (deployer)
(define-data-var contract-owner principal tx-sender)

;; Document counter for unique IDs
(define-data-var document-counter uint u0)

;; Contract emergency pause state
(define-data-var emergency-pause bool false)

;; === DATA MAPS ===

;; Primary document storage map
;; Key: (principal, document-id)
;; Value: document data structure
(define-map documents
  {owner: principal, document-id: uint}
  {
    hash: (buff 32),
    document-type: uint,
    status: uint,
    created-at: uint,
    updated-at: uint,
    verified-by: (optional principal),
    metadata: (string-utf8 256),
    is-locked: bool
  }
)

;; Document hash verification map
;; Key: (buff 32) - document hash
;; Value: verification data
(define-map hash-registry
  (buff 32)
  {
    owner: principal,
    document-id: uint,
    verified: bool,
    verification-count: uint
  }
)

;; User permissions map
;; Key: principal
;; Value: permission level
(define-map user-permissions
  principal
  {
    can-verify: bool,
    can-admin: bool,
    is-authorized: bool
  }
)

;; Document access log for audit trail
;; Key: (principal, document-id, access-counter)
;; Value: access record
(define-map access-log
  {owner: principal, document-id: uint, access-id: uint}
  {
    accessor: principal,
    action: (string-ascii 32),
    timestamp: uint,
    success: bool
  }
)

;; Access counter per document
(define-map document-access-counter
  {owner: principal, document-id: uint}
  uint
)

;; === PRIVATE FUNCTIONS ===

;; Check if caller is contract owner
(define-private (is-contract-owner (caller principal))
  (is-eq caller (var-get contract-owner))
)

;; Check if caller has admin permissions
(define-private (has-admin-permission (caller principal))
  (match (map-get? user-permissions caller)
    permission (get can-admin permission)
    false
  )
)

;; Check if caller can verify documents
(define-private (can-verify-documents (caller principal))
  (match (map-get? user-permissions caller)
    permission (get can-verify permission)
    false
  )
)

;; Check if contract is paused
(define-private (is-emergency-paused)
  (var-get emergency-pause)
)

;; Validate document type
(define-private (is-valid-document-type (doc-type uint))
  (or
    (is-eq doc-type TYPE-DEED)
    (is-eq doc-type TYPE-TITLE)
    (is-eq doc-type TYPE-INSPECTION)
    (is-eq doc-type TYPE-APPRAISAL)
    (is-eq doc-type TYPE-SURVEY)
    (is-eq doc-type TYPE-OTHER)
  )
)

;; Log document access
(define-private (log-document-access 
    (owner principal) 
    (document-id uint) 
    (accessor principal)
    (action (string-ascii 32))
    (success bool))
  (let (
    (current-counter (default-to u0 (map-get? document-access-counter {owner: owner, document-id: document-id})))
    (new-counter (+ current-counter u1))
  )
    (map-set document-access-counter {owner: owner, document-id: document-id} new-counter)
    (map-set access-log 
      {owner: owner, document-id: document-id, access-id: new-counter}
      {
        accessor: accessor,
        action: action,
        timestamp: block-height,
        success: success
      }
    )
    (ok new-counter)
  )
)

;; === PUBLIC FUNCTIONS ===

;; Store a new property document
(define-public (store-document 
    (hash (buff 32))
    (document-type uint)
    (metadata (string-utf8 256)))
  (let (
    (caller tx-sender)
    (current-id (var-get document-counter))
    (new-id (+ current-id u1))
    (current-time block-height)
  )
    ;; Check if contract is paused
    (asserts! (not (is-emergency-paused)) ERR-UNAUTHORIZED)
    
    ;; Validate document type
    (asserts! (is-valid-document-type document-type) ERR-INVALID-TYPE)
    
    ;; Check if hash already exists
    (asserts! (is-none (map-get? hash-registry hash)) ERR-ALREADY-EXISTS)
    
    ;; Store document
    (map-set documents
      {owner: caller, document-id: new-id}
      {
        hash: hash,
        document-type: document-type,
        status: STATUS-PENDING,
        created-at: current-time,
        updated-at: current-time,
        verified-by: none,
        metadata: metadata,
        is-locked: false
      }
    )
    
    ;; Register hash
    (map-set hash-registry hash
      {
        owner: caller,
        document-id: new-id,
        verified: false,
        verification-count: u0
      }
    )
    
    ;; Update counter
    (var-set document-counter new-id)
    
    ;; Log access
    (unwrap-panic (log-document-access caller new-id caller "STORE" true))
    
    ;; Emit event
    (print {
      event: "document-stored",
      owner: caller,
      document-id: new-id,
      hash: hash,
      document-type: document-type
    })
    
    (ok new-id)
  )
)

;; Verify a document hash
(define-public (verify-document-hash (hash (buff 32)) (expected-hash (buff 32)))
  (let (
    (caller tx-sender)
    (hash-data (unwrap! (map-get? hash-registry hash) ERR-NOT-FOUND))
    (document-data (unwrap! (map-get? documents 
                            {owner: (get owner hash-data), 
                             document-id: (get document-id hash-data)}) 
                            ERR-NOT-FOUND))
  )
    ;; Check if contract is paused
    (asserts! (not (is-emergency-paused)) ERR-UNAUTHORIZED)
    
    ;; Check if hashes match
    (asserts! (is-eq hash expected-hash) ERR-INVALID-HASH)
    
    ;; Update hash registry
    (map-set hash-registry hash
      (merge hash-data {
        verified: true,
        verification-count: (+ (get verification-count hash-data) u1)
      })
    )
    
    ;; Log access
    (unwrap-panic (log-document-access 
      (get owner hash-data) 
      (get document-id hash-data)
      caller 
      "VERIFY_HASH" 
      true))
    
    ;; Emit event
    (print {
      event: "hash-verified",
      hash: hash,
      verifier: caller,
      verification-count: (+ (get verification-count hash-data) u1)
    })
    
    (ok true)
  )
)

;; Verify document status (admin only)
(define-public (verify-document 
    (owner principal) 
    (document-id uint) 
    (new-status uint))
  (let (
    (caller tx-sender)
    (document-key {owner: owner, document-id: document-id})
    (document-data (unwrap! (map-get? documents document-key) ERR-NOT-FOUND))
  )
    ;; Check permissions
    (asserts! (or (can-verify-documents caller) 
                  (is-contract-owner caller)) ERR-PERMISSION-DENIED)
    
    ;; Check if contract is paused
    (asserts! (not (is-emergency-paused)) ERR-UNAUTHORIZED)
    
    ;; Check if document is locked
    (asserts! (not (get is-locked document-data)) ERR-DOCUMENT-LOCKED)
    
    ;; Validate status
    (asserts! (or (is-eq new-status STATUS-VERIFIED)
                  (is-eq new-status STATUS-REJECTED)) ERR-INVALID-STATUS)
    
    ;; Update document
    (map-set documents document-key
      (merge document-data {
        status: new-status,
        updated-at: block-height,
        verified-by: (some caller)
      })
    )
    
    ;; Log access
    (unwrap-panic (log-document-access owner document-id caller "VERIFY" true))
    
    ;; Emit event
    (print {
      event: "document-verified",
      owner: owner,
      document-id: document-id,
      verifier: caller,
      new-status: new-status
    })
    
    (ok true)
  )
)

;; === READ-ONLY FUNCTIONS ===

;; Get document by owner and ID
(define-read-only (get-document (owner principal) (document-id uint))
  (map-get? documents {owner: owner, document-id: document-id})
)

;; Get document hash information
(define-read-only (get-hash-info (hash (buff 32)))
  (map-get? hash-registry hash)
)

;; Get user permissions
(define-read-only (get-user-permissions (user principal))
  (map-get? user-permissions user)
)

;; Get access log entry
(define-read-only (get-access-log (owner principal) (document-id uint) (access-id uint))
  (map-get? access-log {owner: owner, document-id: document-id, access-id: access-id})
)

;; Get document access counter
(define-read-only (get-access-counter (owner principal) (document-id uint))
  (default-to u0 (map-get? document-access-counter {owner: owner, document-id: document-id}))
)

;; Get current document counter
(define-read-only (get-document-counter)
  (var-get document-counter)
)

;; Check if contract is paused
(define-read-only (is-contract-paused)
  (var-get emergency-pause)
)

;; Get contract owner
(define-read-only (get-contract-owner)
  (var-get contract-owner)
)

;; Check if user is contract owner
(define-read-only (is-owner (user principal))
  (is-eq user (var-get contract-owner))
)

;; === ADMIN FUNCTIONS ===

;; Grant permissions to user (owner only)
(define-public (grant-permissions 
    (user principal) 
    (can-verify bool) 
    (can-admin bool) 
    (is-authorized bool))
  (let (
    (caller tx-sender)
  )
    ;; Check if caller is contract owner
    (asserts! (is-contract-owner caller) ERR-PERMISSION-DENIED)
    
    ;; Set permissions
    (map-set user-permissions user
      {
        can-verify: can-verify,
        can-admin: can-admin,
        is-authorized: is-authorized
      }
    )
    
    ;; Emit event
    (print {
      event: "permissions-granted",
      user: user,
      grantor: caller,
      can-verify: can-verify,
      can-admin: can-admin,
      is-authorized: is-authorized
    })
    
    (ok true)
  )
)

;; Emergency pause contract (owner only)
(define-public (emergency-pause-documents)
  (let (
    (caller tx-sender)
  )
    ;; Check if caller is contract owner
    (asserts! (is-contract-owner caller) ERR-PERMISSION-DENIED)
    
    ;; Set pause state
    (var-set emergency-pause true)
    
    ;; Emit event
    (print {
      event: "emergency-pause",
      paused-by: caller,
      timestamp: block-height
    })
    
    (ok true)
  )
)

;; Resume contract operations (owner only)
(define-public (resume-document-operations)
  (let (
    (caller tx-sender)
  )
    ;; Check if caller is contract owner
    (asserts! (is-contract-owner caller) ERR-PERMISSION-DENIED)
    
    ;; Resume operations
    (var-set emergency-pause false)
    
    ;; Emit event
    (print {
      event: "operations-resumed",
      resumed-by: caller,
      timestamp: block-height
    })
    
    (ok true)
  )
)

;; Lock/unlock document (admin only)
(define-public (set-document-lock 
    (owner principal) 
    (document-id uint) 
    (locked bool))
  (let (
    (caller tx-sender)
    (document-key {owner: owner, document-id: document-id})
    (document-data (unwrap! (map-get? documents document-key) ERR-NOT-FOUND))
  )
    ;; Check permissions
    (asserts! (or (has-admin-permission caller) 
                  (is-contract-owner caller)
                  (is-eq caller owner)) ERR-PERMISSION-DENIED)
    
    ;; Update document lock status
    (map-set documents document-key
      (merge document-data {
        is-locked: locked,
        updated-at: block-height
      })
    )
    
    ;; Log access
    (unwrap-panic (log-document-access owner document-id caller "LOCK_TOGGLE" true))
    
    ;; Emit event
    (print {
      event: "document-lock-changed",
      owner: owner,
      document-id: document-id,
      locked: locked,
      admin: caller
    })
    
    (ok true)
  )
)
