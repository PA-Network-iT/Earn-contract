// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Soulbound ERC-721 controlled by `SubscriptionManager`.
interface ISubscriptionNFT {
    /// @notice Mints the subscription token for `owner` (`tokenId = uint256(uint160(owner))`).
    /// @dev Reverts when the token already exists or the caller is not the manager.
    function mint(address owner) external;

    /// @notice Burns the subscription token for `owner`.
    /// @dev Reverts when the token does not exist or the caller is not the manager.
    function burn(address owner) external;

    /// @notice Returns the deterministic tokenId for `owner`.
    function tokenIdOf(address owner) external pure returns (uint256);
}
