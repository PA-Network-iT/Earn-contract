// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnTestBase} from "test/shared/EarnTestBase.sol";

/// @notice Invariant tests for protocol-wide properties that must hold across state transitions.
contract EarnInvariantsTest is EarnTestBase {
    function invariant_currentIndexNeverDropsBelowOneRay() public view {
        assertGe(core.currentIndex(), ONE_RAY);
    }
}
