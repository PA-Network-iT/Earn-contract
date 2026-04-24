// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ISubscriptionNFT} from "./ISubscriptionNFT.sol";

error SoulboundTransferDisabled();
error UnauthorizedManager(address caller);
error TokenNotMinted(address owner);
error TokenAlreadyMinted(address owner);
error InvalidManager(address manager);
error ZeroAddress();
error UnauthorizedUpgrade(address caller);
error InvalidAdmin(address admin);

/// @notice Soulbound ERC-721 representing an active PAiT subscription.
/// @dev `tokenId = uint256(uint160(owner))` for cheap deterministic lookup.
///      Only the configured `_manager` (SubscriptionManager) may mint / burn.
contract SubscriptionNFT is Initializable, ERC721Upgradeable, AccessControlUpgradeable, UUPSUpgradeable, ISubscriptionNFT {
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    address internal _manager;

    uint256[49] private __gap;

    event ManagerUpdated(address indexed newManager);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        if (admin == address(0)) {
            revert InvalidAdmin(admin);
        }

        __ERC721_init("PAiT Subscription", "PAIT-SUB");
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    modifier onlyManager() {
        if (msg.sender != _manager) {
            revert UnauthorizedManager(msg.sender);
        }
        _;
    }

    /// @notice Sets the manager allowed to mint / burn tokens.
    function setManager(address newManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newManager == address(0)) {
            revert InvalidManager(newManager);
        }
        _manager = newManager;
        emit ManagerUpdated(newManager);
    }

    function manager() external view returns (address) {
        return _manager;
    }

    /// @inheritdoc ISubscriptionNFT
    function tokenIdOf(address owner) public pure returns (uint256) {
        return uint256(uint160(owner));
    }

    /// @inheritdoc ISubscriptionNFT
    function mint(address owner) external onlyManager {
        if (owner == address(0)) {
            revert ZeroAddress();
        }
        uint256 tokenId = tokenIdOf(owner);
        if (_ownerOf(tokenId) != address(0)) {
            revert TokenAlreadyMinted(owner);
        }
        _safeMint(owner, tokenId);
    }

    /// @inheritdoc ISubscriptionNFT
    function burn(address owner) external onlyManager {
        uint256 tokenId = tokenIdOf(owner);
        if (_ownerOf(tokenId) == address(0)) {
            revert TokenNotMinted(owner);
        }
        _burn(tokenId);
    }

    // ===== Soulbound enforcement =====

    function approve(address, uint256) public pure override {
        revert SoulboundTransferDisabled();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert SoulboundTransferDisabled();
    }

    /// @dev Blocks transfers between non-zero addresses; allows mint (from=0) and burn (to=0).
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            revert SoulboundTransferDisabled();
        }
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _authorizeUpgrade(address) internal view override {
        if (!hasRole(UPGRADER_ROLE, msg.sender)) {
            revert UnauthorizedUpgrade(msg.sender);
        }
    }
}
