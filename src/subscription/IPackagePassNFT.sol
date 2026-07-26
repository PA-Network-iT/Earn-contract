// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Soulbound ERC-721 controlled by `SubscriptionManager`.
/// @dev Holds `tierId` and remaining `seats` per owner; the tier may be updated in place on
///      upgrades so the token itself is minted only once per owner.
interface IPackagePassNFT {
    /// @notice Mints a new pass for `owner`.
    function mint(address owner, uint16 tierId, uint32 seats) external;

    /// @notice Updates the tier/seats on an existing pass without re-minting the token.
    function setTier(address owner, uint16 newTierId, uint32 newSeats) external;

    /// @notice Consumes one seat from `owner`'s partner inventory.
    /// @dev Reverts `NoSeatsAvailable(owner)` when seats == 0.
    /// @return remainingSeats Seats left after the decrement.
    function decrementSeats(address owner) external returns (uint32 remainingSeats);

    /// @notice Returns the tier currently attached to `owner`'s pass (0 if no pass).
    function tierOf(address owner) external view returns (uint16);

    /// @notice Returns the seats currently attached to `owner`'s pass.
    function seatsOf(address owner) external view returns (uint32);

    /// @notice Returns the deterministic tokenId for `owner`.
    function tokenIdOf(address owner) external pure returns (uint256);
}
