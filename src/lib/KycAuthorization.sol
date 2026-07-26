// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @dev Reverts when an action needs KYC but no authorization blob was provided.
error KycAuthorizationRequired(address user);
/// @dev Reverts when the authorization payload, nonce, scope, or signer is invalid.
error InvalidKycAuthorization(address user);
/// @dev Reverts when the backend-signed authorization has expired.
error KycAuthorizationExpired(address user);
/// @dev Reverts when an admin attempts to configure an unusable KYC signer.
error InvalidKycSigner(address signer);
/// @dev Reverts when a third party tries to spend a user's KYC authorization.
error KycCallerMismatch(address caller, address user);

/// @notice EIP-712 payload shared by every KYC-gated entry point.
/// @dev The backend (Veriff integration) signs `KycAuthorization(user, scope, expiresAt, nonce)`.
///      Each consumer contract validates the signature against its own EIP-712 domain and burns a
///      per-user nonce, so an authorization is single-use and cannot be replayed across contracts,
///      scopes, or users.
library KycAuthorization {
    /// @dev EIP-712 struct hash type for the authorization payload.
    bytes32 internal constant TYPEHASH =
        keccak256("KycAuthorization(address user,uint8 scope,uint64 expiresAt,uint256 nonce)");

    /// @dev Scope for `EarnCore.deposit` above the cumulative deposit threshold.
    uint8 internal constant SCOPE_DEPOSIT = 1;
    /// @dev Scope for `SubscriptionManager.buyPackagePass`.
    uint8 internal constant SCOPE_PACKAGE_PASS = 2;
    /// @dev Longest accepted lifetime of a signed authorization.
    uint256 internal constant MAX_TTL = 1 days;

    /// @notice Decodes an ABI-encoded authorization blob.
    /// @param user Account the authorization is expected to cover; used for error reporting.
    /// @param authorization ABI-encoded `(uint64 expiresAt, uint256 nonce, bytes signature)`.
    /// @return expiresAt Authorization expiry.
    /// @return nonce Per-user nonce that must match the consumer's stored nonce.
    /// @return signature Backend signature over the EIP-712 digest.
    function decode(address user, bytes memory authorization)
        internal
        pure
        returns (uint64 expiresAt, uint256 nonce, bytes memory signature)
    {
        if (authorization.length == 0) {
            revert KycAuthorizationRequired(user);
        }

        (expiresAt, nonce, signature) = abi.decode(authorization, (uint64, uint256, bytes));
    }
}
