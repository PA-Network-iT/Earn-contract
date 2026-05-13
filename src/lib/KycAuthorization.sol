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

library KycAuthorization {
    bytes32 internal constant TYPEHASH =
        keccak256("KycAuthorization(address user,uint8 scope,uint64 expiresAt,uint256 nonce)");

    uint8 internal constant SCOPE_DEPOSIT = 1;
    uint8 internal constant SCOPE_PACKAGE_PASS = 2;
    uint256 internal constant MAX_TTL = 1 days;

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
