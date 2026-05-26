// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LibConfigStorage} from "@predix/diamond/libraries/LibConfigStorage.sol";

/// @title OutcomeTokenImplInit
/// @notice Sets `LibConfigStorage.outcomeTokenImpl` during a diamondCut.
/// @dev    DelegateCalled by the diamond as the cut's `_init` step → executes in
///         diamond's storage context, bypassing the ADMIN_ROLE gate on
///         `MarketFacet.setOutcomeTokenImpl`. This keeps the cut atomic: by the
///         time the cut returns, the new MarketFacet's `createMarket` path
///         already has a valid impl pointer, eliminating the window in which
///         `createMarket` would revert `Market_OutcomeTokenImplNotSet`.
contract OutcomeTokenImplInit {
    function init(address impl) external {
        require(impl != address(0), "OutcomeTokenImplInit: zero impl");
        LibConfigStorage.layout().outcomeTokenImpl = impl;
    }
}
