;; Flight Data Oracle Contract
;; Integrates with flight tracking APIs for real-time delay monitoring
;; Validates and stores flight delay data on-chain

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-FLIGHT-NOT-FOUND (err u101))
(define-constant ERR-INVALID-DATA (err u102))
(define-constant ERR-ALREADY-EXISTS (err u103))
(define-constant ERR-ORACLE-OFFLINE (err u104))

;; Oracle status constants
(define-constant ORACLE-ACTIVE u1)
(define-constant ORACLE-INACTIVE u2)
(define-constant ORACLE-MAINTENANCE u3)

;; Flight status constants
(define-constant STATUS-ON-TIME u0)
(define-constant STATUS-DELAYED u1)
(define-constant STATUS-CANCELLED u2)
(define-constant STATUS-DEPARTED u3)
(define-constant STATUS-ARRIVED u4)

;; Data variables
(define-data-var contract-owner principal tx-sender)
(define-data-var oracle-status uint ORACLE-ACTIVE)
(define-data-var total-flights uint u0)
(define-data-var oracle-fee uint u1000) ;; Fee in microSTX
(define-data-var last-update-block uint u0)

;; Data maps for flight information
(define-map flight-data
    { flight-id: (string-ascii 20) }
    {
        airline-code: (string-ascii 10),
        flight-number: (string-ascii 10),
        departure-airport: (string-ascii 10),
        arrival-airport: (string-ascii 10),
        scheduled-departure: uint,
        actual-departure: (optional uint),
        scheduled-arrival: uint,
        actual-arrival: (optional uint),
        status: uint,
        delay-minutes: uint,
        created-at: uint,
        updated-at: uint,
        data-source: (string-ascii 50)
    }
)

;; Map to track authorized data providers
(define-map authorized-oracles principal bool)

;; Map to track flight delay history
(define-map delay-history
    { flight-id: (string-ascii 20), date: uint }
    { delay-minutes: uint, reason: (string-ascii 100) }
)

;; Map for oracle statistics
(define-map oracle-stats
    principal
    {
        updates-count: uint,
        last-update: uint,
        reputation-score: uint
    }
)

;; Public function to register flight data
(define-public (register-flight-data
    (flight-id (string-ascii 20))
    (airline-code (string-ascii 10))
    (flight-number (string-ascii 10))
    (departure-airport (string-ascii 10))
    (arrival-airport (string-ascii 10))
    (scheduled-departure uint)
    (scheduled-arrival uint)
    (data-source (string-ascii 50))
)
    (let (
        (existing-flight (map-get? flight-data { flight-id: flight-id }))
    )
        (asserts! (is-eq (var-get oracle-status) ORACLE-ACTIVE) ERR-ORACLE-OFFLINE)
        (asserts! (or (is-eq tx-sender (var-get contract-owner)) 
                      (default-to false (map-get? authorized-oracles tx-sender))) ERR-NOT-AUTHORIZED)
        (asserts! (is-none existing-flight) ERR-ALREADY-EXISTS)
        (asserts! (> scheduled-arrival scheduled-departure) ERR-INVALID-DATA)
        
        (map-set flight-data
            { flight-id: flight-id }
            {
                airline-code: airline-code,
                flight-number: flight-number,
                departure-airport: departure-airport,
                arrival-airport: arrival-airport,
                scheduled-departure: scheduled-departure,
                actual-departure: none,
                scheduled-arrival: scheduled-arrival,
                actual-arrival: none,
                status: STATUS-ON-TIME,
                delay-minutes: u0,
                created-at: stacks-block-height,
                updated-at: stacks-block-height,
                data-source: data-source
            }
        )
        
        (var-set total-flights (+ (var-get total-flights) u1))
        (var-set last-update-block stacks-block-height)
        (ok flight-id)
    )
)

;; Public function to update flight status
(define-public (update-flight-status
    (flight-id (string-ascii 20))
    (actual-departure (optional uint))
    (actual-arrival (optional uint))
    (status uint)
    (delay-minutes uint)
)
    (let (
        (flight-info (unwrap! (map-get? flight-data { flight-id: flight-id }) ERR-FLIGHT-NOT-FOUND))
        (current-stats (default-to { updates-count: u0, last-update: u0, reputation-score: u100 }
                                  (map-get? oracle-stats tx-sender)))
    )
        (asserts! (is-eq (var-get oracle-status) ORACLE-ACTIVE) ERR-ORACLE-OFFLINE)
        (asserts! (or (is-eq tx-sender (var-get contract-owner)) 
                      (default-to false (map-get? authorized-oracles tx-sender))) ERR-NOT-AUTHORIZED)
        (asserts! (<= status u4) ERR-INVALID-DATA)
        
        ;; Update flight data
        (map-set flight-data
            { flight-id: flight-id }
            (merge flight-info {
                actual-departure: actual-departure,
                actual-arrival: actual-arrival,
                status: status,
                delay-minutes: delay-minutes,
                updated-at: stacks-block-height
            })
        )
        
        ;; Update oracle statistics
        (map-set oracle-stats tx-sender
            (merge current-stats {
                updates-count: (+ (get updates-count current-stats) u1),
                last-update: stacks-block-height
            })
        )
        
        ;; Record delay history if flight is delayed
        (if (> delay-minutes u0)
            (map-set delay-history
                { flight-id: flight-id, date: stacks-block-height }
                { delay-minutes: delay-minutes, reason: "API_UPDATE" }
            )
            true
        )
        
        (var-set last-update-block stacks-block-height)
        (ok true)
    )
)

;; Public function to authorize oracle
(define-public (authorize-oracle (oracle principal))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
        (map-set authorized-oracles oracle true)
        (ok true)
    )
)

;; Public function to revoke oracle authorization
(define-public (revoke-oracle-authorization (oracle principal))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
        (map-delete authorized-oracles oracle)
        (ok true)
    )
)

;; Public function to update oracle status
(define-public (set-oracle-status (new-status uint))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
        (asserts! (<= new-status u3) ERR-INVALID-DATA)
        (var-set oracle-status new-status)
        (ok true)
    )
)

;; Read-only function to get flight data
(define-read-only (get-flight-data (flight-id (string-ascii 20)))
    (map-get? flight-data { flight-id: flight-id })
)

;; Read-only function to check if flight is delayed
(define-read-only (is-flight-delayed (flight-id (string-ascii 20)))
    (match (map-get? flight-data { flight-id: flight-id })
        flight-info (ok (> (get delay-minutes flight-info) u0))
        ERR-FLIGHT-NOT-FOUND
    )
)

;; Read-only function to get delay minutes
(define-read-only (get-delay-minutes (flight-id (string-ascii 20)))
    (match (map-get? flight-data { flight-id: flight-id })
        flight-info (ok (get delay-minutes flight-info))
        ERR-FLIGHT-NOT-FOUND
    )
)

;; Read-only function to check oracle authorization
(define-read-only (is-oracle-authorized (oracle principal))
    (default-to false (map-get? authorized-oracles oracle))
)

;; Read-only function to get oracle statistics
(define-read-only (get-oracle-stats (oracle principal))
    (map-get? oracle-stats oracle)
)

;; Read-only function to get delay history
(define-read-only (get-delay-history (flight-id (string-ascii 20)) (date uint))
    (map-get? delay-history { flight-id: flight-id, date: date })
)

;; Read-only function to get oracle status
(define-read-only (get-oracle-status)
    (var-get oracle-status)
)

;; Read-only function to get total flights count
(define-read-only (get-total-flights)
    (var-get total-flights)
)

;; Read-only function to get contract owner
(define-read-only (get-contract-owner)
    (var-get contract-owner)
)

