// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IPackagePassNFT} from "./IPackagePassNFT.sol";

error SoulboundTransferDisabled();
error UnauthorizedManager(address caller);
error TokenNotMinted(address owner);
error TokenAlreadyMinted(address owner);
error InvalidManager(address manager);
error NoSeatsAvailable(address owner);
error ZeroAddress();
error UnauthorizedUpgrade(address caller);
error InvalidAdmin(address admin);

/// @notice Soulbound ERC-721 representing a PAiT package pass.
/// @dev Stores `tierId` and cumulative `seats` per owner in addition to the ERC-721 token.
///      Tier / seats are updatable in-place via `setTier` without re-minting the NFT.
contract PackagePassNFT is Initializable, ERC721Upgradeable, AccessControlUpgradeable, UUPSUpgradeable, IPackagePassNFT {
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    address internal _manager;

    mapping(address owner => uint16 tierId) internal _tierOf;
    mapping(address owner => uint32 seats) internal _seatsOf;

    uint256[47] private __gap;

    event ManagerUpdated(address indexed newManager);
    event TierAssigned(address indexed owner, uint16 indexed tierId, uint32 seats);
    event SeatsDecremented(address indexed owner, uint32 newSeats);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        if (admin == address(0)) {
            revert InvalidAdmin(admin);
        }

        __ERC721_init("PAiT Package Pass", "PAIT-PASS");
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

    function tokenIdOf(address owner) public pure returns (uint256) {
        return uint256(uint160(owner));
    }

    function tierOf(address owner) external view returns (uint16) {
        return _tierOf[owner];
    }

    function seatsOf(address owner) external view returns (uint32) {
        return _seatsOf[owner];
    }

    function mint(address owner, uint16 tierId, uint32 seats) external onlyManager {
        if (owner == address(0)) {
            revert ZeroAddress();
        }
        uint256 tokenId = tokenIdOf(owner);
        if (_ownerOf(tokenId) != address(0)) {
            revert TokenAlreadyMinted(owner);
        }
        _tierOf[owner] = tierId;
        _seatsOf[owner] = seats;
        _safeMint(owner, tokenId);
        emit TierAssigned(owner, tierId, seats);
    }

    function setTier(address owner, uint16 newTierId, uint32 newSeats) external onlyManager {
        if (_ownerOf(tokenIdOf(owner)) == address(0)) {
            revert TokenNotMinted(owner);
        }
        _tierOf[owner] = newTierId;
        _seatsOf[owner] = newSeats;
        emit TierAssigned(owner, newTierId, newSeats);
    }

    function decrementSeats(address owner) external onlyManager returns (uint32 remainingSeats) {
        uint32 current = _seatsOf[owner];
        if (current == 0) {
            revert NoSeatsAvailable(owner);
        }
        unchecked {
            remainingSeats = current - 1;
        }
        _seatsOf[owner] = remainingSeats;
        emit SeatsDecremented(owner, remainingSeats);
    }

    function burn(address owner) external onlyManager {
        uint256 tokenId = tokenIdOf(owner);
        if (_ownerOf(tokenId) == address(0)) {
            revert TokenNotMinted(owner);
        }
        delete _tierOf[owner];
        delete _seatsOf[owner];
        _burn(tokenId);
    }

    // ===== Soulbound enforcement =====

    function approve(address, uint256) public pure override {
        revert SoulboundTransferDisabled();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert SoulboundTransferDisabled();
    }

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
