// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnTestBase} from "test/shared/EarnTestBase.sol";

contract EarnInvariantsTest is EarnTestBase {
    function invariant_currentIndexNeverDropsBelowOneRay() public view {
        assertGe(core.currentIndex(), ONE_RAY);
    }
}
