;; Escrow & Closing Coordination Smart Contract
;; A comprehensive contract for managing real estate transactions
;; with secure escrow services and automated closing coordination

;; === CONSTANTS ===

;; Error constants
(define-constant ERR-UNAUTHORIZED (err u200))
(define-constant ERR-NOT-FOUND (err u201))
(define-constant ERR-ALREADY-EXISTS (err u202))
(define-constant ERR-INVALID-STATUS (err u203))
(define-constant ERR-INSUFFICIENT-FUNDS (err u204))
(define-constant ERR-INVALID-AMOUNT (err u205))
(define-constant ERR-TRANSACTION-LOCKED (err u206))
(define-constant ERR-INVALID-PARTY (err u207))
(define-constant ERR-DEADLINE-EXPIRED (err u208))
(define-constant ERR-CONDITIONS-NOT-MET (err u209))
(define-constant ERR-DISPUTE-PENDING (err u210))

;; Transaction status constants
(define-constant STATUS-CREATED u0)
(define-constant STATUS-FUNDED u1)
(define-constant STATUS-IN-PROGRESS u2)
(define-constant STATUS-COMPLETED u3)
(define-constant STATUS-CANCELLED u4)
(define-constant STATUS-DISPUTED u5)
(define-constant STATUS-RESOLVED u6)

;; Party type constants
(define-constant PARTY-BUYER u0)
(define-constant PARTY-SELLER u1)
(define-constant PARTY-ESCROW-AGENT u2)
(define-constant PARTY-INSPECTOR u3)

;; Deposit type constants
(define-constant DEPOSIT-EARNEST u0)
(define-constant DEPOSIT-DOWN-PAYMENT u1)
(define-constant DEPOSIT-CLOSING-COSTS u2)
(define-constant DEPOSIT-INSPECTION u3)

;; === DATA VARIABLES ===

;; Contract owner and escrow agent
(define-data-var contract-owner principal tx-sender)
(define-data-var escrow-agent principal tx-sender)

;; Transaction counter for unique IDs
(define-data-var transaction-counter uint u0)

;; Contract emergency pause state
(define-data-var emergency-pause bool false)

;; Default escrow fee percentage (basis points: 100 = 1%)
(define-data-var default-escrow-fee uint u250) ;; 2.5%

;; === DATA MAPS ===

;; Primary escrow transaction storage
;; Key: transaction-id
;; Value: transaction data structure
(define-map escrow-transactions
  uint
  {
    buyer: principal,
    seller: principal,
    property-id: (buff 32),
    purchase-price: uint,
    earnest-money: uint,
    status: uint,
    created-at: uint,
    deadline: uint,
    conditions-met: bool,
    inspection-passed: bool,
    financing-approved: bool,
    title-clear: bool,
    is-locked: bool
  }
)

;; Deposit tracking per transaction
;; Key: (transaction-id, party-address, deposit-type)
;; Value: deposit information
(define-map transaction-deposits
  {transaction-id: uint, depositor: principal, deposit-type: uint}
  {
    amount: uint,
    deposited-at: uint,
    released: bool,
    released-at: (optional uint),
    released-to: (optional principal)
  }
)

;; Balance tracking per party per transaction
;; Key: (transaction-id, party-address)
;; Value: balance amount
(define-map party-balances
  {transaction-id: uint, party: principal}
  uint
)

;; Transaction participants and their roles
;; Key: (transaction-id, principal)
;; Value: role information
(define-map transaction-parties
  {transaction-id: uint, party: principal}
  {
    role: uint,
    authorized: bool,
    signed-off: bool,
    signed-at: (optional uint)
  }
)

;; Dispute records
;; Key: transaction-id
;; Value: dispute information
(define-map disputes
  uint
  {
    raised-by: principal,
    raised-at: uint,
    description: (string-utf8 512),
    resolved: bool,
    resolution: (optional (string-utf8 512)),
    resolved-at: (optional uint),
    resolved-by: (optional principal)
  }
)

;; Fee structure per transaction
;; Key: transaction-id
;; Value: fee information
(define-map transaction-fees
  uint
  {
    escrow-fee: uint,
    inspection-fee: uint,
    title-fee: uint,
    total-fees: uint,
    fees-paid: bool
  }
)

;; === PRIVATE FUNCTIONS ===

;; Check if caller is contract owner
(define-private (is-contract-owner (caller principal))
  (is-eq caller (var-get contract-owner))
)

;; Check if caller is escrow agent
(define-private (is-escrow-agent (caller principal))
  (is-eq caller (var-get escrow-agent))
)

;; Check if contract is paused
(define-private (is-emergency-paused)
  (var-get emergency-pause)
)

;; Validate party role
(define-private (is-valid-party-role (role uint))
  (or
    (is-eq role PARTY-BUYER)
    (is-eq role PARTY-SELLER)
    (is-eq role PARTY-ESCROW-AGENT)
    (is-eq role PARTY-INSPECTOR)
  )
)

;; Check if caller is authorized for transaction
(define-private (is-authorized-party (transaction-id uint) (caller principal))
  (match (map-get? transaction-parties {transaction-id: transaction-id, party: caller})
    party-info (get authorized party-info)
    false
  )
)

;; Calculate escrow fees
(define-private (calculate-escrow-fee (purchase-price uint))
  (/ (* purchase-price (var-get default-escrow-fee)) u10000)
)

;; Update party balance
(define-private (update-party-balance (transaction-id uint) (party principal) (amount uint))
  (let (
    (current-balance (default-to u0 (map-get? party-balances {transaction-id: transaction-id, party: party})))
    (new-balance (+ current-balance amount))
  )
    (map-set party-balances {transaction-id: transaction-id, party: party} new-balance)
    (ok new-balance)
  )
)

;; === PUBLIC FUNCTIONS ===

;; Initialize escrow transaction
(define-public (create-escrow-transaction
    (buyer principal)
    (seller principal)
    (property-id (buff 32))
    (purchase-price uint)
    (earnest-money uint)
    (deadline uint))
  (let (
    (caller tx-sender)
    (current-id (var-get transaction-counter))
    (new-id (+ current-id u1))
    (current-time block-height)
    (escrow-fee (calculate-escrow-fee purchase-price))
  )
    ;; Check if contract is paused
    (asserts! (not (is-emergency-paused)) ERR-UNAUTHORIZED)
    
    ;; Validate inputs
    (asserts! (> purchase-price u0) ERR-INVALID-AMOUNT)
    (asserts! (> earnest-money u0) ERR-INVALID-AMOUNT)
    (asserts! (> deadline current-time) ERR-DEADLINE-EXPIRED)
    
    ;; Only escrow agent can create transactions
    (asserts! (is-escrow-agent caller) ERR-UNAUTHORIZED)
    
    ;; Create transaction
    (map-set escrow-transactions new-id
      {
        buyer: buyer,
        seller: seller,
        property-id: property-id,
        purchase-price: purchase-price,
        earnest-money: earnest-money,
        status: STATUS-CREATED,
        created-at: current-time,
        deadline: deadline,
        conditions-met: false,
        inspection-passed: false,
        financing-approved: false,
        title-clear: false,
        is-locked: false
      }
    )
    
    ;; Register parties
    (map-set transaction-parties {transaction-id: new-id, party: buyer}
      {role: PARTY-BUYER, authorized: true, signed-off: false, signed-at: none})
    
    (map-set transaction-parties {transaction-id: new-id, party: seller}
      {role: PARTY-SELLER, authorized: true, signed-off: false, signed-at: none})
    
    (map-set transaction-parties {transaction-id: new-id, party: caller}
      {role: PARTY-ESCROW-AGENT, authorized: true, signed-off: false, signed-at: none})
    
    ;; Set fees
    (map-set transaction-fees new-id
      {
        escrow-fee: escrow-fee,
        inspection-fee: u0,
        title-fee: u0,
        total-fees: escrow-fee,
        fees-paid: false
      }
    )
    
    ;; Update counter
    (var-set transaction-counter new-id)
    
    ;; Emit event
    (print {
      event: "escrow-created",
      transaction-id: new-id,
      buyer: buyer,
      seller: seller,
      purchase-price: purchase-price,
      earnest-money: earnest-money,
      deadline: deadline
    })
    
    (ok new-id)
  )
)

;; Make deposit into escrow
(define-public (make-deposit
    (transaction-id uint)
    (deposit-type uint)
    (amount uint))
  (let (
    (caller tx-sender)
    (current-time block-height)
    (transaction-data (unwrap! (map-get? escrow-transactions transaction-id) ERR-NOT-FOUND))
  )
    ;; Check if contract is paused
    (asserts! (not (is-emergency-paused)) ERR-UNAUTHORIZED)
    
    ;; Validate amount
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    
    ;; Check if transaction is locked
    (asserts! (not (get is-locked transaction-data)) ERR-TRANSACTION-LOCKED)
    
    ;; Check if caller is authorized
    (asserts! (is-authorized-party transaction-id caller) ERR-UNAUTHORIZED)
    
    ;; Check if deposit already exists
    (asserts! (is-none (map-get? transaction-deposits 
                        {transaction-id: transaction-id, 
                         depositor: caller, 
                         deposit-type: deposit-type})) 
              ERR-ALREADY-EXISTS)
    
    ;; Record deposit
    (map-set transaction-deposits
      {transaction-id: transaction-id, depositor: caller, deposit-type: deposit-type}
      {
        amount: amount,
        deposited-at: current-time,
        released: false,
        released-at: none,
        released-to: none
      }
    )
    
    ;; Update party balance
    (unwrap-panic (update-party-balance transaction-id caller amount))
    
    ;; Update transaction status if earnest money is deposited
    (if (and (is-eq deposit-type DEPOSIT-EARNEST)
             (is-eq (get status transaction-data) STATUS-CREATED))
      (map-set escrow-transactions transaction-id
        (merge transaction-data {status: STATUS-FUNDED}))
      true
    )
    
    ;; Emit event
    (print {
      event: "deposit-made",
      transaction-id: transaction-id,
      depositor: caller,
      deposit-type: deposit-type,
      amount: amount
    })
    
    (ok true)
  )
)

;; Release funds from escrow
(define-public (release-funds
    (transaction-id uint)
    (depositor principal)
    (deposit-type uint)
    (release-to principal))
  (let (
    (caller tx-sender)
    (current-time block-height)
    (deposit-key {transaction-id: transaction-id, depositor: depositor, deposit-type: deposit-type})
    (deposit-data (unwrap! (map-get? transaction-deposits deposit-key) ERR-NOT-FOUND))
    (transaction-data (unwrap! (map-get? escrow-transactions transaction-id) ERR-NOT-FOUND))
  )
    ;; Check if contract is paused
    (asserts! (not (is-emergency-paused)) ERR-UNAUTHORIZED)
    
    ;; Only escrow agent can release funds
    (asserts! (is-escrow-agent caller) ERR-UNAUTHORIZED)
    
    ;; Check if already released
    (asserts! (not (get released deposit-data)) ERR-INVALID-STATUS)
    
    ;; Check if conditions are met for release
    (asserts! (get conditions-met transaction-data) ERR-CONDITIONS-NOT-MET)
    
    ;; Update deposit record
    (map-set transaction-deposits deposit-key
      (merge deposit-data {
        released: true,
        released-at: (some current-time),
        released-to: (some release-to)
      })
    )
    
    ;; Emit event
    (print {
      event: "funds-released",
      transaction-id: transaction-id,
      depositor: depositor,
      deposit-type: deposit-type,
      amount: (get amount deposit-data),
      released-to: release-to
    })
    
    (ok true)
  )
)

;; Update transaction conditions
(define-public (update-conditions
    (transaction-id uint)
    (inspection-passed bool)
    (financing-approved bool)
    (title-clear bool))
  (let (
    (caller tx-sender)
    (transaction-data (unwrap! (map-get? escrow-transactions transaction-id) ERR-NOT-FOUND))
    (all-conditions-met (and inspection-passed financing-approved title-clear))
  )
    ;; Only escrow agent can update conditions
    (asserts! (is-escrow-agent caller) ERR-UNAUTHORIZED)
    
    ;; Check if contract is paused
    (asserts! (not (is-emergency-paused)) ERR-UNAUTHORIZED)
    
    ;; Update transaction conditions
    (map-set escrow-transactions transaction-id
      (merge transaction-data {
        inspection-passed: inspection-passed,
        financing-approved: financing-approved,
        title-clear: title-clear,
        conditions-met: all-conditions-met,
        status: (if all-conditions-met STATUS-IN-PROGRESS (get status transaction-data))
      })
    )
    
    ;; Emit event
    (print {
      event: "conditions-updated",
      transaction-id: transaction-id,
      inspection-passed: inspection-passed,
      financing-approved: financing-approved,
      title-clear: title-clear,
      all-conditions-met: all-conditions-met
    })
    
    (ok true)
  )
)

;; Complete transaction (close escrow)
(define-public (complete-transaction (transaction-id uint))
  (let (
    (caller tx-sender)
    (current-time block-height)
    (transaction-data (unwrap! (map-get? escrow-transactions transaction-id) ERR-NOT-FOUND))
  )
    ;; Only escrow agent can complete transactions
    (asserts! (is-escrow-agent caller) ERR-UNAUTHORIZED)
    
    ;; Check if contract is paused
    (asserts! (not (is-emergency-paused)) ERR-UNAUTHORIZED)
    
    ;; Check if all conditions are met
    (asserts! (get conditions-met transaction-data) ERR-CONDITIONS-NOT-MET)
    
    ;; Check if transaction is in progress
    (asserts! (is-eq (get status transaction-data) STATUS-IN-PROGRESS) ERR-INVALID-STATUS)
    
    ;; Update transaction status
    (map-set escrow-transactions transaction-id
      (merge transaction-data {status: STATUS-COMPLETED})
    )
    
    ;; Emit event
    (print {
      event: "transaction-completed",
      transaction-id: transaction-id,
      buyer: (get buyer transaction-data),
      seller: (get seller transaction-data),
      purchase-price: (get purchase-price transaction-data),
      completed-at: current-time
    })
    
    (ok true)
  )
)

;; Raise dispute
(define-public (raise-dispute
    (transaction-id uint)
    (description (string-utf8 512)))
  (let (
    (caller tx-sender)
    (current-time block-height)
    (transaction-data (unwrap! (map-get? escrow-transactions transaction-id) ERR-NOT-FOUND))
  )
    ;; Check if contract is paused
    (asserts! (not (is-emergency-paused)) ERR-UNAUTHORIZED)
    
    ;; Check if caller is authorized
    (asserts! (is-authorized-party transaction-id caller) ERR-UNAUTHORIZED)
    
    ;; Check if dispute already exists
    (asserts! (is-none (map-get? disputes transaction-id)) ERR-ALREADY-EXISTS)
    
    ;; Create dispute record
    (map-set disputes transaction-id
      {
        raised-by: caller,
        raised-at: current-time,
        description: description,
        resolved: false,
        resolution: none,
        resolved-at: none,
        resolved-by: none
      }
    )
    
    ;; Update transaction status
    (map-set escrow-transactions transaction-id
      (merge transaction-data {status: STATUS-DISPUTED})
    )
    
    ;; Emit event
    (print {
      event: "dispute-raised",
      transaction-id: transaction-id,
      raised-by: caller,
      description: description
    })
    
    (ok true)
  )
)

;; Resolve dispute (owner only)
(define-public (resolve-dispute
    (transaction-id uint)
    (resolution (string-utf8 512))
    (new-status uint))
  (let (
    (caller tx-sender)
    (current-time block-height)
    (dispute-data (unwrap! (map-get? disputes transaction-id) ERR-NOT-FOUND))
    (transaction-data (unwrap! (map-get? escrow-transactions transaction-id) ERR-NOT-FOUND))
  )
    ;; Only contract owner can resolve disputes
    (asserts! (is-contract-owner caller) ERR-UNAUTHORIZED)
    
    ;; Check if contract is paused
    (asserts! (not (is-emergency-paused)) ERR-UNAUTHORIZED)
    
    ;; Check if dispute is not already resolved
    (asserts! (not (get resolved dispute-data)) ERR-INVALID-STATUS)
    
    ;; Update dispute record
    (map-set disputes transaction-id
      (merge dispute-data {
        resolved: true,
        resolution: (some resolution),
        resolved-at: (some current-time),
        resolved-by: (some caller)
      })
    )
    
    ;; Update transaction status
    (map-set escrow-transactions transaction-id
      (merge transaction-data {status: new-status})
    )
    
    ;; Emit event
    (print {
      event: "dispute-resolved",
      transaction-id: transaction-id,
      resolved-by: caller,
      resolution: resolution,
      new-status: new-status
    })
    
    (ok true)
  )
)

;; === READ-ONLY FUNCTIONS ===

;; Get transaction details
(define-read-only (get-transaction (transaction-id uint))
  (map-get? escrow-transactions transaction-id)
)

;; Get deposit information
(define-read-only (get-deposit (transaction-id uint) (depositor principal) (deposit-type uint))
  (map-get? transaction-deposits {transaction-id: transaction-id, depositor: depositor, deposit-type: deposit-type})
)

;; Get party balance
(define-read-only (get-party-balance (transaction-id uint) (party principal))
  (default-to u0 (map-get? party-balances {transaction-id: transaction-id, party: party}))
)

;; Get party information
(define-read-only (get-party-info (transaction-id uint) (party principal))
  (map-get? transaction-parties {transaction-id: transaction-id, party: party})
)

;; Get dispute information
(define-read-only (get-dispute (transaction-id uint))
  (map-get? disputes transaction-id)
)

;; Get transaction fees
(define-read-only (get-transaction-fees (transaction-id uint))
  (map-get? transaction-fees transaction-id)
)

;; Get transaction counter
(define-read-only (get-transaction-counter)
  (var-get transaction-counter)
)

;; Get escrow agent
(define-read-only (get-escrow-agent)
  (var-get escrow-agent)
)

;; Get contract owner
(define-read-only (get-contract-owner)
  (var-get contract-owner)
)

;; Check if contract is paused
(define-read-only (is-contract-paused)
  (var-get emergency-pause)
)

;; === ADMIN FUNCTIONS ===

;; Set escrow agent (owner only)
(define-public (set-escrow-agent (new-agent principal))
  (let (
    (caller tx-sender)
  )
    ;; Check if caller is contract owner
    (asserts! (is-contract-owner caller) ERR-UNAUTHORIZED)
    
    ;; Update escrow agent
    (var-set escrow-agent new-agent)
    
    ;; Emit event
    (print {
      event: "escrow-agent-changed",
      old-agent: (var-get escrow-agent),
      new-agent: new-agent,
      changed-by: caller
    })
    
    (ok true)
  )
)

;; Emergency pause contract (owner only)
(define-public (emergency-pause-escrow)
  (let (
    (caller tx-sender)
  )
    ;; Check if caller is contract owner
    (asserts! (is-contract-owner caller) ERR-UNAUTHORIZED)
    
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

;; Resume operations (owner only)
(define-public (resume-escrow-operations)
  (let (
    (caller tx-sender)
  )
    ;; Check if caller is contract owner
    (asserts! (is-contract-owner caller) ERR-UNAUTHORIZED)
    
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
