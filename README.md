# Pact Contracts

Smart contract suite for escrow, identity, staking, payments, governance, and reward distribution.

## Build and Test

```bash
forge build
forge test
```

## Contract Interfaces

### `PactEscrow`
File: `src/PactEscrow.sol`

Purpose:
- Creates USDC escrow by `taskId`.
- Releases escrow with fixed split: worker `85%`, validators `5%`, treasury `5%`, issuer `5%`.
- Supports owner-triggered refund.

State:
- `uint16 public constant WORKER_BPS = 8500`
- `uint16 public constant VALIDATORS_BPS = 500`
- `uint16 public constant TREASURY_BPS = 500`
- `uint16 public constant ISSUER_BPS = 500`
- `IERC20 public immutable usdc`

Structs:
- `Escrow { address payer; uint256 amount; bool released; bool refunded; }`
- `Payouts { address worker; address validators; address treasury; address issuer; }`

Constructor:
- `constructor(address usdcAddress)`

External Functions:
- `createEscrow(uint256 taskId, address payer, uint256 amount)`
- `releaseEscrow(uint256 taskId, Payouts calldata payouts)` (`onlyOwner`)
- `refundEscrow(uint256 taskId)` (`onlyOwner`)
- `getEscrow(uint256 taskId) external view returns (Escrow memory)`

Events:
- `EscrowCreated(uint256 indexed taskId, address indexed payer, uint256 amount)`
- `EscrowReleased(uint256 indexed taskId, uint256 workerAmount, uint256 validatorsAmount, uint256 treasuryAmount, uint256 issuerAmount)`
- `EscrowRefunded(uint256 indexed taskId, address indexed payer, uint256 amount)`

Custom Errors:
- `ZeroAddress()`
- `InvalidAmount()`
- `EscrowAlreadyExists()`
- `EscrowNotFound()`
- `EscrowAlreadyResolved()`
- `UnauthorizedPayer()`

### `PactIdentitySBT`
File: `src/PactIdentitySBT.sol`

Purpose:
- Soulbound identity NFT for participants.
- Admin minting and role-based level upgrades.

Inheritance:
- `ERC721`
- `AccessControl`

State:
- `bytes32 public constant UPGRADER_ROLE`

Struct:
- `Identity { uint256 participantId; string role; uint8 level; uint64 registeredAt; }`

Constructor:
- `constructor() ERC721("PACT Identity", "PACTID")`

External/Public Functions:
- `mint(address to, uint256 participantId, string calldata role, uint8 level) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 tokenId)`
- `upgradeLevel(uint256 tokenId, uint8 newLevel) external onlyRole(UPGRADER_ROLE)`
- `getIdentity(uint256 tokenId) external view returns (string memory role, uint8 level, uint256 registeredAt)`
- `supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool)`

Override Behavior:
- `_update(address to, uint256 tokenId, address auth)` prevents transfers between non-zero addresses (soulbound).

Events:
- `IdentityMinted(uint256 indexed tokenId, address indexed to, uint256 indexed participantId, string role, uint8 level)`
- `LevelUpgraded(uint256 indexed tokenId, uint8 oldLevel, uint8 newLevel)`

Custom Errors:
- `Soulbound()`
- `InvalidReceiver()`
- `TokenDoesNotExist()`
- `InvalidLevel()`

### `PactStaking`
File: `src/PactStaking.sol`

Purpose:
- Holds USDC stakes for disputes/challenges.
- Owner resolves stake and routes penalty/split to jury/protocol treasury.

State:
- `IERC20 public immutable usdc`
- `address public immutable juryTreasury`
- `address public immutable protocolTreasury`
- `uint16 public immutable upheldPenaltyBps`

Struct:
- `Stake { address challenger; uint256 amount; bool resolved; bool upheld; }`

Constructor:
- `constructor(address usdcAddress, address juryTreasuryAddress, address protocolTreasuryAddress, uint16 penaltyBps)`

External Functions:
- `postStake(uint256 challengeId, uint256 amount)`
- `resolveStake(uint256 challengeId, bool upheld)` (`onlyOwner`)
- `getStake(uint256 challengeId) external view returns (Stake memory)`

Events:
- `StakePosted(uint256 indexed challengeId, address indexed challenger, uint256 amount)`
- `StakeResolved(uint256 indexed challengeId, bool upheld, uint256 refundAmount, uint256 juryAmount, uint256 protocolAmount)`

Custom Errors:
- `ZeroAddress()`
- `InvalidAmount()`
- `InvalidPenalty()`
- `StakeAlreadyExists()`
- `StakeNotFound()`
- `StakeAlreadyResolved()`

### `PactPayRouter`
File: `src/PactPayRouter.sol`

Purpose:
- Routes USDC payments between participants.
- Maintains per-participant ledger with payment references.

State:
- `IERC20 public immutable usdc`

Structs:
- `TransferRequest { address from; address to; uint256 amount; bytes32 ref; }`
- `LedgerEntry { address from; address to; uint256 amount; bytes32 ref; uint64 timestamp; }`

Constructor:
- `constructor(address usdcAddress)`

External Functions:
- `transfer(address from, address to, uint256 amount, bytes32 ref)`
- `batchTransfer(TransferRequest[] calldata transfers)`
- `getLedger(address participant) external view returns (LedgerEntry[] memory)`

Events:
- `PaymentRouted(address indexed from, address indexed to, uint256 amount, bytes32 indexed ref)`
- `BatchPaymentRouted(uint256 indexed batchId, uint256 transferCount, uint256 totalAmount)`

Custom Errors:
- `ZeroAddress()`
- `InvalidAmount()`
- `UnauthorizedSender()`

### `PactGovernance`
File: `src/PactGovernance.sol`

Purpose:
- DAO governance with token-weighted voting and timelocked execution.
- Proposals carry arbitrary call target/value/data payloads.

Inheritance:
- `Ownable`
- `ReentrancyGuard`

Enum:
- `ProposalState { Pending, Active, Defeated, Succeeded, Queued, Executed, Canceled }`

Struct:
- `Proposal { address proposer; address target; uint256 value; bytes data; bytes32 descriptionHash; uint64 startTime; uint64 endTime; uint64 eta; uint256 forVotes; uint256 againstVotes; bool executed; bool canceled; }`

State:
- `IERC20 public immutable governanceToken`
- `uint64 public immutable votingDelay`
- `uint64 public immutable votingPeriod`
- `uint64 public immutable timelockDelay`
- `uint256 public immutable proposalThreshold`
- `uint256 public immutable quorum`
- `mapping(uint256 => mapping(address => bool)) public hasVoted`

Constructor:
- `constructor(address governanceTokenAddress, uint64 votingDelaySeconds, uint64 votingPeriodSeconds, uint64 timelockDelaySeconds, uint256 proposalThresholdAmount, uint256 quorumVotes)`

External/Public Functions:
- `createProposal(address target, uint256 value, bytes calldata data, string calldata description) external returns (uint256 proposalId)`
- `vote(uint256 proposalId, bool support) external`
- `execute(uint256 proposalId) external`
- `cancel(uint256 proposalId) external`
- `state(uint256 proposalId) public view returns (ProposalState)`
- `getProposal(uint256 proposalId) external view returns (Proposal memory)`
- `getNextProposalId() external view returns (uint256)`
- `receive() external payable`

Events:
- `ProposalCreated(uint256 indexed proposalId, address indexed proposer, address indexed target, uint256 value, bytes data, string description, uint64 startTime, uint64 endTime, uint64 eta)`
- `VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight)`
- `ProposalExecuted(uint256 indexed proposalId)`
- `ProposalCanceled(uint256 indexed proposalId)`

Custom Errors:
- `ZeroAddress()`
- `InvalidConfig()`
- `ThresholdNotMet()`
- `InvalidProposal()`
- `InvalidState()`
- `AlreadyVoted()`
- `NoVotingPower()`
- `UnauthorizedCancel()`
- `CallFailed()`

### `PactRewards`
File: `src/PactRewards.sol`

Purpose:
- Tracks validator/worker rewards per epoch.
- Allows reward claiming by participants after owner distribution.

Inheritance:
- `Ownable`
- `ReentrancyGuard`

State:
- `IERC20 public immutable rewardToken`
- `mapping(uint256 => bool) public epochDistributed`
- `uint256 public totalPendingRewards`

Constructor:
- `constructor(address rewardTokenAddress)`

External Functions:
- `distributeEpochRewards(uint256 epochId, address[] calldata validators, uint256[] calldata validatorRewards, address[] calldata workers, uint256[] calldata workerRewards) external onlyOwner`
- `claimRewards() external`
- `getRewardBalance(address participant) external view returns (uint256)`

Events:
- `RewardAccrued(uint256 indexed epochId, address indexed participant, uint256 amount, bool isValidator)`
- `EpochRewardsDistributed(uint256 indexed epochId, uint256 validatorCount, uint256 workerCount, uint256 totalAmount)`
- `RewardsClaimed(address indexed participant, uint256 amount)`

Custom Errors:
- `ZeroAddress()`
- `InvalidAmount()`
- `LengthMismatch()`
- `EpochAlreadyDistributed()`
- `NothingToClaim()`
