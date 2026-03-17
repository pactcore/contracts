# CLAUDE.md — PACT Contracts

## Project
Solidity smart contracts for PACT Network (ERC-8183 commerce kernel).

## Stack
- Framework: Foundry (forge build, forge test)
- Language: Solidity ^0.8.20
- Dependency manager: Soldeer

## Commands
- `forge build` — compile
- `forge test` — run all tests
- `forge test -vvv` — verbose output
- `forge fmt` — format

## Rules
- Do not fix tests by weakening domain rules
- All new contracts need test coverage
- Follow Checks-Effects-Interactions pattern
- Keep interfaces in src/interfaces/
- Keep hooks in src/hooks/
- Keep evaluators in src/evaluators/
- Preserve existing test count baseline (103+)
- Use OpenZeppelin where applicable for standard patterns

## Architecture
- PactCommerce.sol — main commerce kernel (jobs, disputes, settlements)
- PactEscrow.sol — USDC escrow vault
- PactGovernance.sol — governance parameter management
- PactStaking.sol — validator staking
- PactIdentitySBT.sol — soulbound identity tokens
- PactPayRouter.sol — payment routing
- PactRewards.sol — reward distribution
- HumanJury.sol — human jury dispute resolution
- evaluators/ — pluggable evaluator contracts
- hooks/ — commerce lifecycle hooks
- interfaces/ — contract interfaces

## Current Task: Whitepaper-Aligned Expansion
The whitepaper (PACT v3) specifies several subsystems not yet on-chain. Next priority:

### 1. PactDataMarket.sol (§5.4)
- Data listing with metadata hash, price, and seller
- Purchase flow through escrow with revenue split: 70% seller, 10% validators, 20% treasury
- Listing deactivation and buyer access tracking
- Events for all state transitions

### 2. X402 Payment Integration (§5.2)
- PactX402Gateway.sol — gasless meta-transaction relay for USDC payments
- EIP-712 typed-data signature verification
- Nonce management for replay protection
- Relayer fee deduction from payment amount
- Integration with PactPayRouter for settlement

### 3. On-chain Reputation Score Storage (§6.4)
- PactReputation.sol — stores and updates participant reputation on-chain
- Multi-role scores: worker, validator, issuer (0-100 range)
- Score adjustment with bounds checking
- Decay mechanism for inactive participants
- Events for score changes
- View functions for reputation queries
