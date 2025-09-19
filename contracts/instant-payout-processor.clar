;; Instant Payout Processor Contract
;; Automated compensation based on delay duration thresholds
;; Manages insurance pool funds and executes instant payouts

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-POLICY-NOT-FOUND (err u201))
(define-constant ERR-INSUFFICIENT-FUNDS (err u202))
(define-constant ERR-ALREADY-PAID (err u203))
(define-constant ERR-INVALID-AMOUNT (err u204))
(define-constant ERR-POLICY-EXPIRED (err u205))
(define-constant ERR-NO-DELAY (err u206))
(define-constant ERR-TRANSFER-FAILED (err u207))

;; Policy status constants
(define-constant POLICY-ACTIVE u1)
(define-constant POLICY-CLAIMED u2)
(define-constant POLICY-EXPIRED u3)
(define-constant POLICY-CANCELLED u4)

;; Delay threshold constants (in minutes)
(define-constant DELAY-TIER-1 u30)   ;; 30 minutes - 25% payout
(define-constant DELAY-TIER-2 u60)   ;; 60 minutes - 50% payout  
(define-constant DELAY-TIER-3 u120)  ;; 120 minutes - 75% payout
(define-constant DELAY-TIER-4 u240)  ;; 240 minutes - 100% payout

;; Payout percentage constants
(define-constant PAYOUT-TIER-1 u25)
(define-constant PAYOUT-TIER-2 u50)
(define-constant PAYOUT-TIER-3 u75)
(define-constant PAYOUT-TIER-4 u100)

;; Data variables
(define-data-var contract-owner principal tx-sender)
(define-data-var total-pool-balance uint u0)
(define-data-var total-policies uint u0)
(define-data-var total-payouts uint u0)
(define-data-var processing-fee uint u50) ;; 0.5% processing fee
(define-data-var emergency-stop bool false)

;; Insurance policy data map
(define-map insurance-policies
    { policy-id: (string-ascii 32) }
    {
        holder: principal,
        flight-id: (string-ascii 20),
        premium-paid: uint,
        coverage-amount: uint,
        purchase-date: uint,
        expiry-date: uint,
        status: uint,
        payout-amount: uint,
        claim-date: (optional uint)
    }
)

;; Claims tracking map
(define-map claims-history
    { policy-id: (string-ascii 32) }
    {
        delay-minutes: uint,
        payout-percentage: uint,
        processed-at: uint,
        transaction-id: (string-ascii 64)
    }
)

;; Pool contributor tracking
(define-map pool-contributors
    principal
    {
        total-contributed: uint,
        contribution-count: uint,
        last-contribution: uint
    }
)

;; Authorized claim processors
(define-map authorized-processors principal bool)

;; Public function to create insurance policy
(define-public (create-policy
    (policy-id (string-ascii 32))
    (flight-id (string-ascii 20))
    (coverage-amount uint)
    (expiry-date uint)
)
    (let (
        (premium (calculate-premium coverage-amount))
        (existing-policy (map-get? insurance-policies { policy-id: policy-id }))
    )
        (asserts! (not (var-get emergency-stop)) ERR-NOT-AUTHORIZED)
        (asserts! (is-none existing-policy) ERR-ALREADY-PAID)
        (asserts! (> coverage-amount u0) ERR-INVALID-AMOUNT)
        (asserts! (> expiry-date stacks-block-height) ERR-POLICY-EXPIRED)
        
        ;; Transfer premium from user to contract
        (try! (stx-transfer? premium tx-sender (as-contract tx-sender)))
        
        ;; Create policy record
        (map-set insurance-policies
            { policy-id: policy-id }
            {
                holder: tx-sender,
                flight-id: flight-id,
                premium-paid: premium,
                coverage-amount: coverage-amount,
                purchase-date: stacks-block-height,
                expiry-date: expiry-date,
                status: POLICY-ACTIVE,
                payout-amount: u0,
                claim-date: none
            }
        )
        
        ;; Update pool balance and counters
        (var-set total-pool-balance (+ (var-get total-pool-balance) premium))
        (var-set total-policies (+ (var-get total-policies) u1))
        
        (ok policy-id)
    )
)

;; Public function to process instant payout
(define-public (process-payout
    (policy-id (string-ascii 32))
    (delay-minutes uint)
)
    (let (
        (policy-info (unwrap! (map-get? insurance-policies { policy-id: policy-id }) ERR-POLICY-NOT-FOUND))
        (payout-percentage (calculate-payout-percentage delay-minutes))
        (payout-amount (/ (* (get coverage-amount policy-info) payout-percentage) u100))
        (processing-fee-amount (/ (* payout-amount (var-get processing-fee)) u10000))
        (net-payout (- payout-amount processing-fee-amount))
    )
        (asserts! (not (var-get emergency-stop)) ERR-NOT-AUTHORIZED)
        (asserts! (or (is-eq tx-sender (var-get contract-owner))
                      (default-to false (map-get? authorized-processors tx-sender))) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status policy-info) POLICY-ACTIVE) ERR-ALREADY-PAID)
        (asserts! (< stacks-block-height (get expiry-date policy-info)) ERR-POLICY-EXPIRED)
        (asserts! (>= delay-minutes DELAY-TIER-1) ERR-NO-DELAY)
        (asserts! (>= (var-get total-pool-balance) net-payout) ERR-INSUFFICIENT-FUNDS)
        
        ;; Execute payout transfer
        (try! (as-contract (stx-transfer? net-payout tx-sender (get holder policy-info))))
        
        ;; Update policy status
        (map-set insurance-policies
            { policy-id: policy-id }
            (merge policy-info {
                status: POLICY-CLAIMED,
                payout-amount: net-payout,
                claim-date: (some stacks-block-height)
            })
        )
        
        ;; Record claim history
        (map-set claims-history
            { policy-id: policy-id }
            {
                delay-minutes: delay-minutes,
                payout-percentage: payout-percentage,
                processed-at: stacks-block-height,
                transaction-id: "AUTO_PAYOUT"
            }
        )
        
        ;; Update pool balance and counters
        (var-set total-pool-balance (- (var-get total-pool-balance) net-payout))
        (var-set total-payouts (+ (var-get total-payouts) net-payout))
        
        (ok net-payout)
    )
)

;; Public function to contribute to insurance pool
(define-public (contribute-to-pool (amount uint))
    (let (
        (contributor-stats (default-to { total-contributed: u0, contribution-count: u0, last-contribution: u0 }
                                      (map-get? pool-contributors tx-sender)))
    )
        (asserts! (> amount u0) ERR-INVALID-AMOUNT)
        
        ;; Transfer contribution to contract
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        
        ;; Update contributor stats
        (map-set pool-contributors tx-sender
            {
                total-contributed: (+ (get total-contributed contributor-stats) amount),
                contribution-count: (+ (get contribution-count contributor-stats) u1),
                last-contribution: stacks-block-height
            }
        )
        
        ;; Update total pool balance
        (var-set total-pool-balance (+ (var-get total-pool-balance) amount))
        
        (ok amount)
    )
)

;; Public function to authorize claim processor
(define-public (authorize-processor (processor principal))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
        (map-set authorized-processors processor true)
        (ok true)
    )
)

;; Public function to toggle emergency stop
(define-public (set-emergency-stop (stop bool))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
        (var-set emergency-stop stop)
        (ok true)
    )
)

;; Private function to calculate premium based on coverage
(define-private (calculate-premium (coverage-amount uint))
    ;; Premium is 5% of coverage amount (minimum 1000 microSTX)
    (let ((calculated-premium (/ (* coverage-amount u5) u100)))
        (if (>= calculated-premium u1000)
            calculated-premium
            u1000
        )
    )
)

;; Private function to calculate payout percentage based on delay
(define-private (calculate-payout-percentage (delay-minutes uint))
    (if (>= delay-minutes DELAY-TIER-4)
        PAYOUT-TIER-4
        (if (>= delay-minutes DELAY-TIER-3)
            PAYOUT-TIER-3
            (if (>= delay-minutes DELAY-TIER-2)
                PAYOUT-TIER-2
                (if (>= delay-minutes DELAY-TIER-1)
                    PAYOUT-TIER-1
                    u0
                )
            )
        )
    )
)

;; Read-only function to get policy information
(define-read-only (get-policy-info (policy-id (string-ascii 32)))
    (map-get? insurance-policies { policy-id: policy-id })
)

;; Read-only function to get claim history
(define-read-only (get-claim-history (policy-id (string-ascii 32)))
    (map-get? claims-history { policy-id: policy-id })
)

;; Read-only function to calculate expected payout
(define-read-only (calculate-expected-payout (coverage-amount uint) (delay-minutes uint))
    (let (
        (payout-percentage (calculate-payout-percentage delay-minutes))
        (gross-payout (/ (* coverage-amount payout-percentage) u100))
        (fee-amount (/ (* gross-payout (var-get processing-fee)) u10000))
    )
        (ok (- gross-payout fee-amount))
    )
)

;; Read-only function to get pool statistics
(define-read-only (get-pool-stats)
    {
        total-balance: (var-get total-pool-balance),
        total-policies: (var-get total-policies),
        total-payouts: (var-get total-payouts),
        processing-fee: (var-get processing-fee)
    }
)

;; Read-only function to check if processor is authorized
(define-read-only (is-processor-authorized (processor principal))
    (default-to false (map-get? authorized-processors processor))
)

;; Read-only function to get contributor stats
(define-read-only (get-contributor-stats (contributor principal))
    (map-get? pool-contributors contributor)
)

