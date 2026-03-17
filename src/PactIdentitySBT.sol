// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";

contract PactIdentitySBT is ERC721, AccessControl {
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @dev Whitepaper identity levels (§5.3)
    uint8 public constant LEVEL_BASIC = 1;
    uint8 public constant LEVEL_VERIFIED = 2;
    uint8 public constant LEVEL_TRUSTED = 3;
    uint8 public constant LEVEL_ELITE = 4;

    struct Identity {
        uint256 participantId;
        string role;
        uint8 level;
        uint64 registeredAt;
        uint16 feeDiscountBps;
        uint8 maxConcurrentTasks;
        bool canAccessPremium;
    }

    uint256 private nextTokenId = 1;
    mapping(uint256 tokenId => Identity) private identities;

    event IdentityMinted(
        uint256 indexed tokenId, address indexed to, uint256 indexed participantId, string role, uint8 level
    );
    event LevelUpgraded(uint256 indexed tokenId, uint8 oldLevel, uint8 newLevel);

    error Soulbound();
    error InvalidReceiver();
    error TokenDoesNotExist();
    error InvalidLevel();

    constructor() ERC721("PACT Identity", "PACTID") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
    }

    /// @notice Get the benefits for a given identity level
    function getLevelBenefits(uint8 level)
        public
        pure
        returns (uint16 feeDiscountBps, uint8 maxConcurrentTasks, bool canAccessPremium)
    {
        if (level == LEVEL_BASIC) return (0, 1, false);
        if (level == LEVEL_VERIFIED) return (250, 3, false);
        if (level == LEVEL_TRUSTED) return (500, 5, true);
        if (level == LEVEL_ELITE) return (1000, 10, true);
        revert InvalidLevel();
    }

    function mint(address to, uint256 participantId, string calldata role, uint8 level)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 tokenId)
    {
        if (to == address(0)) revert InvalidReceiver();

        (uint16 feeDiscount, uint8 maxTasks, bool premium) = getLevelBenefits(level);

        tokenId = nextTokenId;
        nextTokenId++;

        _safeMint(to, tokenId);

        identities[tokenId] = Identity({
            participantId: participantId,
            role: role,
            level: level,
            registeredAt: uint64(block.timestamp),
            feeDiscountBps: feeDiscount,
            maxConcurrentTasks: maxTasks,
            canAccessPremium: premium
        });

        emit IdentityMinted(tokenId, to, participantId, role, level);
    }

    function upgradeLevel(uint256 tokenId, uint8 newLevel) external onlyRole(UPGRADER_ROLE) {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist();

        Identity storage identity = identities[tokenId];
        if (newLevel <= identity.level) revert InvalidLevel();

        (uint16 feeDiscount, uint8 maxTasks, bool premium) = getLevelBenefits(newLevel);

        uint8 oldLevel = identity.level;
        identity.level = newLevel;
        identity.feeDiscountBps = feeDiscount;
        identity.maxConcurrentTasks = maxTasks;
        identity.canAccessPremium = premium;

        emit LevelUpgraded(tokenId, oldLevel, newLevel);
    }

    /// @notice Get identity (backward compatible — returns original 3 fields)
    function getIdentity(uint256 tokenId)
        external
        view
        returns (string memory role, uint8 level, uint256 registeredAt)
    {
        if (_ownerOf(tokenId) == address(0)) {
            revert TokenDoesNotExist();
        }
        Identity storage identity = identities[tokenId];
        return (identity.role, identity.level, identity.registeredAt);
    }

    /// @notice Get full participant level with benefits
    function getParticipantLevel(uint256 tokenId)
        external
        view
        returns (uint8 level, uint16 feeDiscountBps, uint8 maxConcurrentTasks, bool canAccessPremium)
    {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist();
        Identity storage identity = identities[tokenId];
        return (identity.level, identity.feeDiscountBps, identity.maxConcurrentTasks, identity.canAccessPremium);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert Soulbound();
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
