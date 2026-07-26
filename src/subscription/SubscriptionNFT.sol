// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {DelayedUUPSUpgradeable} from "src/upgrade/DelayedUUPSUpgradeable.sol";
import {ISubscriptionNFT} from "./ISubscriptionNFT.sol";

/// @dev Reverts on any transfer or approval attempt.
error SoulboundTransferDisabled();
/// @dev Reverts when a caller other than the configured manager mints or burns.
error UnauthorizedManager(address caller);
/// @dev Reverts when burning a token that was never minted.
error TokenNotMinted(address owner);
/// @dev Reverts when minting a token that already exists.
error TokenAlreadyMinted(address owner);
/// @dev Reverts when configuring a zero manager.
error InvalidManager(address manager);
/// @dev Reverts on a zero address argument.
error ZeroAddress();
/// @dev Reverts when an account without `UPGRADER_ROLE` touches the upgrade flow.
error UnauthorizedUpgrade(address caller);
/// @dev Reverts when initializing with a zero admin.
error InvalidAdmin(address admin);

/// @title SubscriptionNFT
/// @notice Soulbound ERC-721 representing an active PAiT subscription.
/// @dev `tokenId = uint256(uint160(owner))` for cheap deterministic lookup. Only the configured
///      `_manager` (SubscriptionManager) may mint or burn. Upgrades run through the 24h timelock in
///      `DelayedUUPSUpgradeable`.
contract SubscriptionNFT is
    Initializable,
    ERC721Upgradeable,
    AccessControlUpgradeable,
    DelayedUUPSUpgradeable,
    ISubscriptionNFT
{
    /// @notice Schedules and executes UUPS upgrades (always behind the 24h upgrade timelock).
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @dev SubscriptionManager allowed to mint and burn.
    address internal _manager;

    uint256[49] private __gap;

    event ManagerUpdated(address indexed newManager);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the NFT proxy.
    /// @param admin Address receiving `DEFAULT_ADMIN_ROLE` and `UPGRADER_ROLE`.
    function initialize(address admin) external initializer {
        if (admin == address(0)) {
            revert InvalidAdmin(admin);
        }

        __ERC721_init("PAiT Subscription", "PAIT-SUB");
        __AccessControl_init();
        __DelayedUUPS_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    /// @dev Restricts an operation to the configured manager.
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

    /// @notice Returns the configured manager.
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

    /// @notice Disabled: the token is soulbound.
    function approve(address, uint256) public pure override {
        revert SoulboundTransferDisabled();
    }

    /// @notice Disabled: the token is soulbound.
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

    /// @notice ERC-165 support, combining ERC-721 and AccessControl interface ids.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /// @dev Only `UPGRADER_ROLE` may schedule, cancel, or execute an implementation change.
    function _checkUpgradeAuthority(address account) internal view override {
        if (!hasRole(UPGRADER_ROLE, account)) {
            revert UnauthorizedUpgrade(account);
        }
    }
}
