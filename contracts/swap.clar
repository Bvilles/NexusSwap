;; NexusSwap - Next-Generation Decentralized Trading Protocol

;; Define error constants
(define-constant ERROR_MARKET_EXISTS (err "Trading market already exists"))
(define-constant ERROR_MARKET_NOT_FOUND (err "Trading market not found"))
(define-constant ERROR_INSUFFICIENT_FUNDS (err "Insufficient token balance"))
(define-constant ERROR_INSUFFICIENT_DEPTH (err "Insufficient market depth"))
(define-constant ERROR_INVALID_QUANTITY (err "Invalid quantity: must be greater than zero"))
(define-constant ERROR_SLIPPAGE_BREACH (err "Transaction exceeds maximum slippage tolerance"))
(define-constant ERROR_ACCESS_DENIED (err "Unauthorized operation"))
(define-constant ERROR_INVALID_CONTRACT (err "Invalid token contract"))
(define-constant ERROR_MINIMUM_DEPTH (err "Below minimum market depth threshold"))
(define-constant ERROR_TIMEOUT_EXCEEDED (err "Transaction deadline expired"))
(define-constant ERROR_DUPLICATE_ASSETS (err "Cannot create market with identical assets"))
(define-constant ERROR_ZERO_POSITION (err "Cannot remove zero position"))
(define-constant ERROR_IMPACT_EXCESSIVE (err "Price impact too high"))
(define-constant ERROR_ORACLE_OUTDATED (err "Price oracle data is stale"))

;; Define storage maps
(define-map trading-markets 
  { asset-primary: principal, asset-secondary: principal }
  {
    depth-primary: uint,
    depth-secondary: uint,
    total-shares: uint,
    commission-rate: uint,
    last-activity: uint,
    daily-volume: uint,
    accumulated-fees: uint
  }
)

(define-map participant-holdings
  { holder: principal, market-id: { asset-primary: principal, asset-secondary: principal } }
  {
    share-tokens: uint,
    earned-rewards: uint,
    last-distribution: uint,
    stake-timestamp: uint
  }
)

(define-map trader-metrics principal
  {
    cumulative-volume: uint,
    transaction-count: uint,
    commission-paid: uint,
    last-activity: uint,
    elite-tier: bool
  }
)

(define-map oracle-feeds principal
  {
    usd-valuation: uint,
    timestamp-updated: uint,
    reliability-score: uint,
    data-provider: (string-ascii 50)
  }
)

(define-map protocol-proposals uint
  {
    creator: principal,
    proposal-name: (string-utf8 100),
    proposal-details: (string-utf8 500),
    support-votes: uint,
    opposition-votes: uint,
    current-status: (string-ascii 20),
    deadline: uint,
    submission-time: uint
  }
)

;; Define global variables
(define-data-var contract-admin principal tx-sender)
(define-data-var base-commission uint u300) ;; 0.3%
(define-data-var minimum-depth uint u1000)
(define-data-var slippage-limit uint u500) ;; 5%
(define-data-var active-markets uint u0)
(define-data-var protocol-volume uint u0)
(define-data-var voting-power-threshold uint u10000)
(define-data-var oracle-freshness-window uint u3600) ;; 1 hour
(define-data-var elite-volume-requirement uint u1000000)

;; Private utility functions
(define-private (compute-swap-result (input-amount uint) (input-depth uint) (output-depth uint))
  (let
    ((adjusted-input (* input-amount (- u10000 (var-get base-commission))))
     (calculation-numerator (* adjusted-input output-depth))
     (calculation-denominator (+ (* input-depth u10000) adjusted-input)))
    (/ calculation-numerator calculation-denominator)
  )
)

(define-private (verify-slippage-bounds (expected-amount uint) (received-amount uint) (max-slippage-basis uint))
  (let
    ((slippage-basis (if (> expected-amount received-amount)
                    (/ (* (- expected-amount received-amount) u10000) expected-amount)
                    u0)))
    (asserts! (<= slippage-basis max-slippage-basis) ERROR_SLIPPAGE_BREACH)
    (ok true)
  )
)

(define-private (refresh-trader-metrics (participant principal) (trade-volume uint) (commission-amount uint))
  (let
    ((existing-metrics (default-to 
      { cumulative-volume: u0, transaction-count: u0, commission-paid: u0, last-activity: u0, elite-tier: false }
      (map-get? trader-metrics participant)))
     (updated-volume (+ (get cumulative-volume existing-metrics) trade-volume))
     (elite-qualification (>= updated-volume (var-get elite-volume-requirement))))
    
    (map-set trader-metrics participant
      {
        cumulative-volume: updated-volume,
        transaction-count: (+ (get transaction-count existing-metrics) u1),
        commission-paid: (+ (get commission-paid existing-metrics) commission-amount),
        last-activity: block-height,
        elite-tier: elite-qualification
      }
    )
  )
)

;; New function: Emergency market pause
(define-private (emergency-market-halt (asset-primary principal) (asset-secondary principal))
  (let
    ((market-key { asset-primary: asset-primary, asset-secondary: asset-secondary })
     (current-market (unwrap! (map-get? trading-markets market-key) ERROR_MARKET_NOT_FOUND)))
    
    ;; Set market depth to zero to effectively halt trading
    (map-set trading-markets market-key
      (merge current-market { depth-primary: u0, depth-secondary: u0 }))
    (ok true)
  )
)

;; Public functions

;; Create new trading market
(define-public (establish-market 
    (asset-primary principal) 
    (asset-secondary principal)
    (initial-primary uint)
    (initial-secondary uint))
  (let
    ((market-key { asset-primary: asset-primary, asset-secondary: asset-secondary })
     (initiator tx-sender))
    
    ;; Validation
    (asserts! (not (is-eq asset-primary asset-secondary)) ERROR_DUPLICATE_ASSETS)
    (asserts! (is-none (map-get? trading-markets market-key)) ERROR_MARKET_EXISTS)
    (asserts! (and (> initial-primary u0) (> initial-secondary u0)) ERROR_INVALID_QUANTITY)
    (asserts! (>= (* initial-primary initial-secondary) (var-get minimum-depth)) ERROR_MINIMUM_DEPTH)
    
    ;; Calculate initial share allocation
    (let
      ((initial-shares (sqrti (* initial-primary initial-secondary))))
      
      ;; Create market
      (map-set trading-markets market-key
        {
          depth-primary: initial-primary,
          depth-secondary: initial-secondary,
          total-shares: initial-shares,
          commission-rate: (var-get base-commission),
          last-activity: block-height,
          daily-volume: u0,
          accumulated-fees: u0
        }
      )
      
      ;; Set initial participant holding
      (map-set participant-holdings
        { holder: initiator, market-id: market-key }
        {
          share-tokens: initial-shares,
          earned-rewards: u0,
          last-distribution: block-height,
          stake-timestamp: block-height
        }
      )
      
      (var-set active-markets (+ (var-get active-markets) u1))
      (ok initial-shares)
    )
  )
)

;; Enhanced swap function with additional validations
(define-public (execute-swap
    (asset-in principal)
    (asset-out principal) 
    (amount-in uint)
    (min-amount-out uint)
    (deadline uint))
  (let
    ((trader tx-sender)
     (market-key { asset-primary: asset-in, asset-secondary: asset-out }))
    
    ;; Validate deadline
    (asserts! (< block-height deadline) ERROR_TIMEOUT_EXCEEDED)
    (asserts! (> amount-in u0) ERROR_INVALID_QUANTITY)
    
    ;; Get market data
    (let
      ((market-data (unwrap! (map-get? trading-markets market-key) ERROR_MARKET_NOT_FOUND))
       (input-depth (get depth-primary market-data))
       (output-depth (get depth-secondary market-data)))
      
      ;; Check sufficient depth
      (asserts! (> input-depth u0) ERROR_INSUFFICIENT_DEPTH)
      (asserts! (> output-depth amount-in) ERROR_INSUFFICIENT_DEPTH)
      
      ;; Calculate swap output
      (let
        ((amount-out (compute-swap-result amount-in input-depth output-depth))
         (commission-fee (/ (* amount-in (var-get base-commission)) u10000)))
        
        ;; Validate minimum output
        (asserts! (>= amount-out min-amount-out) ERROR_SLIPPAGE_BREACH)
        
        ;; Update market state
        (map-set trading-markets market-key
          (merge market-data {
            depth-primary: (+ input-depth amount-in),
            depth-secondary: (- output-depth amount-out),
            last-activity: block-height,
            daily-volume: (+ (get daily-volume market-data) amount-in),
            accumulated-fees: (+ (get accumulated-fees market-data) commission-fee)
          }))
        
        ;; Update trader metrics
        (refresh-trader-metrics trader amount-in commission-fee)
        (var-set protocol-volume (+ (var-get protocol-volume) amount-in))
        
        (ok amount-out)
      )
    )
  )
)

;; Price oracle management system
(define-public (update-oracle-feed
    (asset principal)
    (usd-price uint)
    (reliability uint)
    (provider (string-ascii 50)))
  (let
    ((caller tx-sender))
    
    ;; Only authorized entities can update feeds
    (asserts! (is-eq caller (var-get contract-admin)) ERROR_ACCESS_DENIED)
    (asserts! (> usd-price u0) ERROR_INVALID_QUANTITY)
    (asserts! (<= reliability u100) ERROR_INVALID_QUANTITY)
    
    (map-set oracle-feeds asset
      {
        usd-valuation: usd-price,
        timestamp-updated: block-height,
        reliability-score: reliability,
        data-provider: provider
      }
    )
    (ok true)
  )
)

;; Governance proposal system
(define-public (submit-proposal
    (proposal-name (string-utf8 100))
    (proposal-details (string-utf8 500)))
  (let
    ((caller tx-sender)
     (proposal-id (var-get active-markets))) ;; Simple ID generation
    
    ;; Check if user has sufficient governance power
    (let
      ((participant-metrics (default-to 
        { cumulative-volume: u0, transaction-count: u0, commission-paid: u0, last-activity: u0, elite-tier: false }
        (map-get? trader-metrics caller))))
      
      (asserts! (>= (get cumulative-volume participant-metrics) (var-get voting-power-threshold)) ERROR_ACCESS_DENIED)
      
      (map-set protocol-proposals proposal-id
        {
          creator: caller,
          proposal-name: proposal-name,
          proposal-details: proposal-details,
          support-votes: u0,
          opposition-votes: u0,
          current-status: "active",
          deadline: (+ block-height u1440), ;; 1 day voting period
          submission-time: block-height
        }
      )
      (ok proposal-id)
    )
  )
)

;; New function: Batch market analytics
(define-public (get-market-analytics-batch (markets (list 10 { asset-primary: principal, asset-secondary: principal })))
  (ok (map get-single-market-analytics markets))
)

(define-private (get-single-market-analytics (market-key { asset-primary: principal, asset-secondary: principal }))
  (let
    ((market-info (map-get? trading-markets market-key)))
    (match market-info
      market-data {
        market-id: market-key,
        total-liquidity: (+ (get depth-primary market-data) (get depth-secondary market-data)),
        volume-24h: (get daily-volume market-data),
        fee-tier: (get commission-rate market-data),
        active: (> (get depth-primary market-data) u0)
      }
      { 
        market-id: market-key, 
        total-liquidity: u0, 
        volume-24h: u0, 
        fee-tier: u0, 
        active: false 
      }
    )
  )
)

;; Read-only functions

(define-read-only (get-market-details (asset-primary principal) (asset-secondary principal))
  (map-get? trading-markets { asset-primary: asset-primary, asset-secondary: asset-secondary })
)

(define-read-only (get-participant-position (participant principal) (asset-primary principal) (asset-secondary principal))
  (map-get? participant-holdings { holder: participant, market-id: { asset-primary: asset-primary, asset-secondary: asset-secondary } })
)

(define-read-only (get-trader-profile (participant principal))
  (map-get? trader-metrics participant)
)

(define-read-only (get-oracle-data (asset principal))
  (map-get? oracle-feeds asset)
)

(define-read-only (get-protocol-overview)
  {
    active-markets: (var-get active-markets),
    protocol-volume: (var-get protocol-volume),
    base-commission: (var-get base-commission),
    elite-threshold: (var-get elite-volume-requirement)
  }
)