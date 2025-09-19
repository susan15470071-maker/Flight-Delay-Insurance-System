;; Airline Integration Contract
;; Direct integration with airline booking systems for policy activation
;; Manages customer policy information and handles policy lifecycle

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-BOOKING-NOT-FOUND (err u301))
(define-constant ERR-INVALID-BOOKING (err u302))
(define-constant ERR-AIRLINE-NOT-REGISTERED (err u303))
(define-constant ERR-POLICY-EXISTS (err u304))
(define-constant ERR-BOOKING-EXPIRED (err u305))
(define-constant ERR-INTEGRATION-DISABLED (err u306))

;; Booking status constants
(define-constant BOOKING-CONFIRMED u1)
(define-constant BOOKING-CANCELLED u2)
(define-constant BOOKING-MODIFIED u3)
(define-constant BOOKING-COMPLETED u4)

;; Airline tier constants
(define-constant AIRLINE-TIER-BASIC u1)
(define-constant AIRLINE-TIER-PREMIUM u2)
(define-constant AIRLINE-TIER-ENTERPRISE u3)

;; Data variables
(define-data-var contract-owner principal tx-sender)
(define-data-var total-bookings uint u0)
(define-data-var total-airlines uint u0)
(define-data-var integration-fee uint u100) ;; Fee in microSTX
(define-data-var system-active bool true)

;; Registered airlines mapping
(define-map registered-airlines
    { airline-code: (string-ascii 10) }
    {
        airline-name: (string-ascii 50),
        contact-email: (string-ascii 100),
        api-endpoint: (string-ascii 200),
        tier: uint,
        registration-date: uint,
        active: bool,
        total-bookings: uint,
        success-rate: uint
    }
)

;; Flight booking information
(define-map flight-bookings
    { booking-id: (string-ascii 32) }
    {
        passenger-name: (string-ascii 100),
        passenger-email: (string-ascii 100),
        flight-id: (string-ascii 20),
        airline-code: (string-ascii 10),
        departure-date: uint,
        arrival-date: uint,
        seat-class: (string-ascii 20),
        booking-amount: uint,
        status: uint,
        created-at: uint,
        policy-eligible: bool
    }
)

;; Policy activation records
(define-map policy-activations
    { booking-id: (string-ascii 32) }
    {
        policy-id: (string-ascii 32),
        coverage-amount: uint,
        premium-paid: uint,
        activation-date: uint,
        activated-by: principal,
        auto-activated: bool
    }
)

;; Airline integration statistics
(define-map airline-stats
    { airline-code: (string-ascii 10) }
    {
        monthly-bookings: uint,
        monthly-policies: uint,
        average-premium: uint,
        last-updated: uint
    }
)

;; Authorized airline partners
(define-map authorized-partners principal bool)

;; Public function to register airline
(define-public (register-airline
    (airline-code (string-ascii 10))
    (airline-name (string-ascii 50))
    (contact-email (string-ascii 100))
    (api-endpoint (string-ascii 200))
    (tier uint)
)
    (let (
        (existing-airline (map-get? registered-airlines { airline-code: airline-code }))
    )
        (asserts! (var-get system-active) ERR-INTEGRATION-DISABLED)
        (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
        (asserts! (is-none existing-airline) ERR-POLICY-EXISTS)
        (asserts! (<= tier u3) ERR-INVALID-BOOKING)
        
        (map-set registered-airlines
            { airline-code: airline-code }
            {
                airline-name: airline-name,
                contact-email: contact-email,
                api-endpoint: api-endpoint,
                tier: tier,
                registration-date: stacks-block-height,
                active: true,
                total-bookings: u0,
                success-rate: u100
            }
        )
        
        (var-set total-airlines (+ (var-get total-airlines) u1))
        (ok airline-code)
    )
)

;; Public function to create flight booking
(define-public (create-booking
    (booking-id (string-ascii 32))
    (passenger-name (string-ascii 100))
    (passenger-email (string-ascii 100))
    (flight-id (string-ascii 20))
    (airline-code (string-ascii 10))
    (departure-date uint)
    (arrival-date uint)
    (seat-class (string-ascii 20))
    (booking-amount uint)
)
    (let (
        (airline-info (unwrap! (map-get? registered-airlines { airline-code: airline-code }) ERR-AIRLINE-NOT-REGISTERED))
        (existing-booking (map-get? flight-bookings { booking-id: booking-id }))
    )
        (asserts! (var-get system-active) ERR-INTEGRATION-DISABLED)
        (asserts! (or (is-eq tx-sender (var-get contract-owner))
                      (default-to false (map-get? authorized-partners tx-sender))) ERR-NOT-AUTHORIZED)
        (asserts! (get active airline-info) ERR-AIRLINE-NOT-REGISTERED)
        (asserts! (is-none existing-booking) ERR-POLICY-EXISTS)
        (asserts! (> departure-date stacks-block-height) ERR-BOOKING-EXPIRED)
        (asserts! (> arrival-date departure-date) ERR-INVALID-BOOKING)
        (asserts! (> booking-amount u0) ERR-INVALID-BOOKING)
        
        ;; Create booking record
        (map-set flight-bookings
            { booking-id: booking-id }
            {
                passenger-name: passenger-name,
                passenger-email: passenger-email,
                flight-id: flight-id,
                airline-code: airline-code,
                departure-date: departure-date,
                arrival-date: arrival-date,
                seat-class: seat-class,
                booking-amount: booking-amount,
                status: BOOKING-CONFIRMED,
                created-at: stacks-block-height,
                policy-eligible: true
            }
        )
        
        ;; Update airline statistics
        (map-set registered-airlines
            { airline-code: airline-code }
            (merge airline-info {
                total-bookings: (+ (get total-bookings airline-info) u1)
            })
        )
        
        (var-set total-bookings (+ (var-get total-bookings) u1))
        (ok booking-id)
    )
)

;; Public function to activate insurance policy for booking
(define-public (activate-policy
    (booking-id (string-ascii 32))
    (policy-id (string-ascii 32))
    (coverage-amount uint)
    (auto-activated bool)
)
    (let (
        (booking-info (unwrap! (map-get? flight-bookings { booking-id: booking-id }) ERR-BOOKING-NOT-FOUND))
        (existing-activation (map-get? policy-activations { booking-id: booking-id }))
        (premium (calculate-policy-premium coverage-amount (get airline-code booking-info)))
    )
        (asserts! (var-get system-active) ERR-INTEGRATION-DISABLED)
        (asserts! (get policy-eligible booking-info) ERR-INVALID-BOOKING)
        (asserts! (is-none existing-activation) ERR-POLICY-EXISTS)
        (asserts! (> coverage-amount u0) ERR-INVALID-BOOKING)
        (asserts! (> (get departure-date booking-info) stacks-block-height) ERR-BOOKING-EXPIRED)
        
        ;; Transfer premium from user to contract
        (try! (stx-transfer? premium tx-sender (as-contract tx-sender)))
        
        ;; Record policy activation
        (map-set policy-activations
            { booking-id: booking-id }
            {
                policy-id: policy-id,
                coverage-amount: coverage-amount,
                premium-paid: premium,
                activation-date: stacks-block-height,
                activated-by: tx-sender,
                auto-activated: auto-activated
            }
        )
        
        ;; Update airline monthly statistics
        (let (
            (airline-code (get airline-code booking-info))
            (current-stats (default-to 
                { monthly-bookings: u0, monthly-policies: u0, average-premium: u0, last-updated: u0 }
                (map-get? airline-stats { airline-code: airline-code })
            ))
        )
            (map-set airline-stats
                { airline-code: airline-code }
                {
                    monthly-bookings: (get monthly-bookings current-stats),
                    monthly-policies: (+ (get monthly-policies current-stats) u1),
                    average-premium: (/ (+ (* (get average-premium current-stats) 
                                            (get monthly-policies current-stats)) premium)
                                       (+ (get monthly-policies current-stats) u1)),
                    last-updated: stacks-block-height
                }
            )
        )
        
        (ok policy-id)
    )
)

;; Public function to update booking status
(define-public (update-booking-status
    (booking-id (string-ascii 32))
    (new-status uint)
)
    (let (
        (booking-info (unwrap! (map-get? flight-bookings { booking-id: booking-id }) ERR-BOOKING-NOT-FOUND))
    )
        (asserts! (var-get system-active) ERR-INTEGRATION-DISABLED)
        (asserts! (or (is-eq tx-sender (var-get contract-owner))
                      (default-to false (map-get? authorized-partners tx-sender))) ERR-NOT-AUTHORIZED)
        (asserts! (<= new-status u4) ERR-INVALID-BOOKING)
        
        (map-set flight-bookings
            { booking-id: booking-id }
            (merge booking-info { status: new-status })
        )
        
        (ok true)
    )
)

;; Public function to authorize airline partner
(define-public (authorize-partner (partner principal))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
        (map-set authorized-partners partner true)
        (ok true)
    )
)

;; Public function to toggle system status
(define-public (set-system-status (active bool))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
        (var-set system-active active)
        (ok true)
    )
)

;; Private function to calculate policy premium based on coverage and airline tier
(define-private (calculate-policy-premium (coverage-amount uint) (airline-code (string-ascii 10)))
    (let (
        (airline-info (unwrap-panic (map-get? registered-airlines { airline-code: airline-code })))
        (base-premium (/ (* coverage-amount u3) u100)) ;; 3% base premium
        (tier-multiplier (if (is-eq (get tier airline-info) AIRLINE-TIER-ENTERPRISE)
                           u80  ;; 20% discount for enterprise
                           (if (is-eq (get tier airline-info) AIRLINE-TIER-PREMIUM)
                               u90  ;; 10% discount for premium
                               u100 ;; No discount for basic
                           )
                       ))
    )
        (/ (* base-premium tier-multiplier) u100)
    )
)

;; Read-only function to get airline information
(define-read-only (get-airline-info (airline-code (string-ascii 10)))
    (map-get? registered-airlines { airline-code: airline-code })
)

;; Read-only function to get booking information
(define-read-only (get-booking-info (booking-id (string-ascii 32)))
    (map-get? flight-bookings { booking-id: booking-id })
)

;; Read-only function to get policy activation details
(define-read-only (get-policy-activation (booking-id (string-ascii 32)))
    (map-get? policy-activations { booking-id: booking-id })
)

;; Read-only function to get airline statistics
(define-read-only (get-airline-stats (airline-code (string-ascii 10)))
    (map-get? airline-stats { airline-code: airline-code })
)

;; Read-only function to check if booking is eligible for insurance
(define-read-only (is-booking-eligible (booking-id (string-ascii 32)))
    (match (map-get? flight-bookings { booking-id: booking-id })
        booking-info (and (get policy-eligible booking-info)
                         (> (get departure-date booking-info) stacks-block-height)
                         (is-eq (get status booking-info) BOOKING-CONFIRMED))
        false
    )
)

;; Read-only function to calculate premium for coverage amount
(define-read-only (get-premium-quote (coverage-amount uint) (airline-code (string-ascii 10)))
    (match (map-get? registered-airlines { airline-code: airline-code })
        airline-info (ok (calculate-policy-premium coverage-amount airline-code))
        ERR-AIRLINE-NOT-REGISTERED
    )
)

;; Read-only function to check partner authorization
(define-read-only (is-partner-authorized (partner principal))
    (default-to false (map-get? authorized-partners partner))
)

;; Read-only function to get system statistics
(define-read-only (get-system-stats)
    {
        total-bookings: (var-get total-bookings),
        total-airlines: (var-get total-airlines),
        integration-fee: (var-get integration-fee),
        system-active: (var-get system-active)
    }
)

