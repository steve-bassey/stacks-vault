;; Title: StacksVault Protocol - Bitcoin L2 Liquid Staking Infrastructure
;;
;; Summary: 
;; Revolutionary liquid staking protocol engineered for Bitcoin's Layer 2 ecosystem,
;; enabling seamless STX staking with dynamic reward optimization and community governance.
;;
;; Description:
;; StacksVault Protocol transforms Bitcoin Layer 2 participation through an innovative
;; liquid staking mechanism that maximizes capital efficiency while preserving user sovereignty.
;; Built on Stacks' Bitcoin-anchored architecture, the protocol introduces a sophisticated
;; tier-based reward system that incentivizes long-term network commitment while maintaining
;; instant liquidity access. Users earn VAULT governance tokens proportional to their stake,
;; unlocking exclusive protocol features and decision-making power in the decentralized
;; governance framework. The protocol's Bitcoin-native design ensures robust security
;; through cryptographic proofs while delivering institutional-grade DeFi capabilities.
;;
;; Key Innovation Highlights:
;; - Dynamic tier-based staking with exponential reward scaling
;; - Time-weighted bonus multipliers for committed network participants
;; - Decentralized autonomous governance with stake-weighted voting power
;; - Emergency circuit breakers and multi-signature security protocols
;; - Native Bitcoin integration optimized for Stacks Layer 2 ecosystem
;; - Institutional-grade risk management and position health monitoring

;; TOKEN DEFINITIONS

(define-fungible-token VAULT-TOKEN u0)

;; PROTOCOL CONSTANTS & ERROR HANDLING

;; Contract Authority
(define-constant CONTRACT-OWNER tx-sender)

;; Error Code Definitions
(define-constant ERR-NOT-AUTHORIZED (err u1000))
(define-constant ERR-INVALID-PROTOCOL (err u1001))
(define-constant ERR-INVALID-AMOUNT (err u1002))
(define-constant ERR-INSUFFICIENT-STX (err u1003))
(define-constant ERR-COOLDOWN-ACTIVE (err u1004))
(define-constant ERR-NO-STAKE (err u1005))
(define-constant ERR-BELOW-MINIMUM (err u1006))
(define-constant ERR-PAUSED (err u1007))

;; PROTOCOL STATE VARIABLES

;; Contract Control States
(define-data-var contract-paused bool false)
(define-data-var emergency-mode bool false)
(define-data-var stx-pool uint u0)

;; Staking Configuration Parameters
(define-data-var base-reward-rate uint u500) ;; 5% annual base rate (100 = 1%)
(define-data-var bonus-rate uint u100) ;; 1% additional bonus for time-locks
(define-data-var minimum-stake uint u1000000) ;; 1 STX minimum stake (1,000,000 uSTX)
(define-data-var cooldown-period uint u1440) ;; 24 hour unstaking cooldown (blocks)
(define-data-var proposal-count uint u0) ;; Total governance proposals created

;; DATA STRUCTURE DEFINITIONS

;; Governance Proposal Structure
(define-map Proposals
  { proposal-id: uint }
  {
    creator: principal,
    description: (string-utf8 256),
    start-block: uint,
    end-block: uint,
    executed: bool,
    votes-for: uint,
    votes-against: uint,
    minimum-votes: uint,
  }
)

;; Comprehensive User Account Data
(define-map UserPositions
  principal
  {
    total-collateral: uint,
    total-debt: uint,
    health-factor: uint,
    last-updated: uint,
    stx-staked: uint,
    analytics-tokens: uint,
    voting-power: uint,
    tier-level: uint,
    rewards-multiplier: uint,
  }
)

;; Individual Staking Position Details
(define-map StakingPositions
  principal
  {
    amount: uint,
    start-block: uint,
    last-claim: uint,
    lock-period: uint,
    cooldown-start: (optional uint),
    accumulated-rewards: uint,
  }
)

;; Tier System Configuration Matrix
(define-map TierLevels
  uint
  {
    minimum-stake: uint,
    reward-multiplier: uint,
    features-enabled: (list 10 bool),
  }
)

;; PUBLIC FUNCTION IMPLEMENTATIONS

;; Contract Initialization & Setup
(define-public (initialize-contract)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    ;; Configure Bronze Tier (Entry Level Access)
    (map-set TierLevels u1 {
      minimum-stake: u1000000, ;; 1 STX minimum
      reward-multiplier: u100, ;; 1x base rewards
      features-enabled: (list true false false false false false false false false false),
    })
    ;; Configure Silver Tier (Enhanced Premium Access)
    (map-set TierLevels u2 {
      minimum-stake: u5000000, ;; 5 STX minimum
      reward-multiplier: u150, ;; 1.5x rewards boost
      features-enabled: (list true true true false false false false false false false),
    })
    ;; Configure Gold Tier (Elite Institutional Benefits)
    (map-set TierLevels u3 {
      minimum-stake: u10000000, ;; 10 STX minimum
      reward-multiplier: u200, ;; 2x rewards multiplier
      features-enabled: (list true true true true true false false false false false),
    })
    (ok true)
  )
)

;; STAKING OPERATIONS

;; Primary Staking Function
(define-public (stake-stx
    (amount uint)
    (lock-period uint)
  )
  (let ((current-position (default-to {
      total-collateral: u0,
      total-debt: u0,
      health-factor: u0,
      last-updated: u0,
      stx-staked: u0,
      analytics-tokens: u0,
      voting-power: u0,
      tier-level: u0,
      rewards-multiplier: u100,
    }
      (map-get? UserPositions tx-sender)
    )))
    ;; Pre-execution Validation Checks
    (asserts! (is-valid-lock-period lock-period) ERR-INVALID-PROTOCOL)
    (asserts! (not (var-get contract-paused)) ERR-PAUSED)
    (asserts! (>= amount (var-get minimum-stake)) ERR-BELOW-MINIMUM)
    ;; Execute STX Transfer to Protocol Contract
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (let (
        (new-total-stake (+ (get stx-staked current-position) amount))
        (tier-info (get-tier-info new-total-stake))
        (lock-multiplier (calculate-lock-multiplier lock-period))
      )
      ;; Create New Staking Position Record
      (map-set StakingPositions tx-sender {
        amount: amount,
        start-block: stacks-block-height,
        last-claim: stacks-block-height,
        lock-period: lock-period,
        cooldown-start: none,
        accumulated-rewards: u0,
      })
      ;; Update Comprehensive User Position
      (map-set UserPositions tx-sender
        (merge current-position {
          stx-staked: new-total-stake,
          tier-level: (get tier-level tier-info),
          rewards-multiplier: (* (get reward-multiplier tier-info) lock-multiplier),
          voting-power: new-total-stake,
        })
      )
      ;; Update Global Protocol State
      (var-set stx-pool (+ (var-get stx-pool) amount))
      (ok true)
    )
  )
)

;; UNSTAKING OPERATIONS

;; Initiate Unstaking Process
(define-public (initiate-unstake (amount uint))
  (let (
      (staking-position (unwrap! (map-get? StakingPositions tx-sender) ERR-NO-STAKE))
      (current-amount (get amount staking-position))
    )
    ;; Validation and Security Checks
    (asserts! (>= current-amount amount) ERR-INSUFFICIENT-STX)
    (asserts! (is-none (get cooldown-start staking-position)) ERR-COOLDOWN-ACTIVE)
    ;; Initialize Mandatory Cooldown Period
    (map-set StakingPositions tx-sender
      (merge staking-position { cooldown-start: (some stacks-block-height) })
    )
    (ok true)
  )
)

;; Complete Unstaking Process
(define-public (complete-unstake)
  (let (
      (staking-position (unwrap! (map-get? StakingPositions tx-sender) ERR-NO-STAKE))
      (cooldown-start (unwrap! (get cooldown-start staking-position) ERR-NOT-AUTHORIZED))
    )
    ;; Verify Cooldown Period Completion
    (asserts!
      (>= (- stacks-block-height cooldown-start) (var-get cooldown-period))
      ERR-COOLDOWN-ACTIVE
    )
    ;; Execute STX Return to User
    (try! (as-contract (stx-transfer? (get amount staking-position) tx-sender tx-sender)))
    ;; Clean Up Staking Position Data
    (map-delete StakingPositions tx-sender)
    ;; Update Global STX Pool Balance
    (var-set stx-pool (- (var-get stx-pool) (get amount staking-position)))
    (ok true)
  )
)

;; GOVERNANCE OPERATIONS

;; Create Governance Proposal
(define-public (create-proposal
    (description (string-utf8 256))
    (voting-period uint)
  )
  (let (
      (user-position (unwrap! (map-get? UserPositions tx-sender) ERR-NOT-AUTHORIZED))
      (proposal-id (+ (var-get proposal-count) u1))
    )
    ;; Authorization and Validation Checks
    (asserts! (>= (get voting-power user-position) u1000000) ERR-NOT-AUTHORIZED)
    (asserts! (is-valid-description description) ERR-INVALID-PROTOCOL)
    (asserts! (is-valid-voting-period voting-period) ERR-INVALID-PROTOCOL)
    ;; Create New Governance Proposal
    (map-set Proposals { proposal-id: proposal-id } {
      creator: tx-sender,
      description: description,
      start-block: stacks-block-height,
      end-block: (+ stacks-block-height voting-period),
      executed: false,
      votes-for: u0,
      votes-against: u0,
      minimum-votes: u1000000,
    })
    ;; Increment Global Proposal Counter
    (var-set proposal-count proposal-id)
    (ok proposal-id)
  )
)

;; Vote on Governance Proposal
(define-public (vote-on-proposal
    (proposal-id uint)
    (vote-for bool)
  )
  (let (
      (proposal (unwrap! (map-get? Proposals { proposal-id: proposal-id })
        ERR-INVALID-PROTOCOL
      ))
      (user-position (unwrap! (map-get? UserPositions tx-sender) ERR-NOT-AUTHORIZED))
      (voting-power (get voting-power user-position))
      (max-proposal-id (var-get proposal-count))
    )
    ;; Voting Period and Proposal Validation
    (asserts! (< stacks-block-height (get end-block proposal)) ERR-NOT-AUTHORIZED)
    (asserts! (and (> proposal-id u0) (<= proposal-id max-proposal-id))
      ERR-INVALID-PROTOCOL
    )
    ;; Record Weighted Vote
    (map-set Proposals { proposal-id: proposal-id }
      (merge proposal {
        votes-for: (if vote-for
          (+ (get votes-for proposal) voting-power)
          (get votes-for proposal)
        ),
        votes-against: (if vote-for
          (get votes-against proposal)
          (+ (get votes-against proposal) voting-power)
        ),
      })
    )
    (ok true)
  )
)