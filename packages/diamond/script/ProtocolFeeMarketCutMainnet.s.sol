// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {ProtocolFeeMarketCut} from "./ProtocolFeeMarketCut.s.sol";

/// @title ProtocolFeeMarketCutMainnet
/// @notice Sub-plan 05 Task 1/5 — PRINT (never broadcast) the exact calldata the TEAM_SAFE submits to the OZ
///         TimelockController to schedule + execute the protocol-fee MarketFacet cut. Reads the LIVE diamond
///         routing (read-only) to build the Replace set, so the printed calldata self-corrects against the
///         on-chain facet. Run WITHOUT `--broadcast`:
///           forge script script/ProtocolFeeMarketCutMainnet.s.sol:ProtocolFeeMarketCutMainnet \
///             --rpc-url "$UNICHAIN_RPC_PRIMARY" --sender "$DEPLOYER_ADDRESS"
/// @dev Env: DIAMOND_ADDRESS, TIMELOCK_ADDRESS, SALT(bytes32), DELAY(uint256, the live getMinDelay()=3600=1h),
///      and optionally NEW_MARKET_FACET (else a fresh MarketFacet is deployed in simulation only to read its
///      address). The operator then submits `scheduleCalldata` to the Timelock, waits `DELAY`, submits
///      `executeCalldata`. Nothing here changes chain state.
contract ProtocolFeeMarketCutMainnet is Script {
    // OZ TimelockController signatures (the live Timelock 0xC5c64967…).
    bytes4 internal constant SCHEDULE_SEL =
        bytes4(keccak256("schedule(address,uint256,bytes,bytes32,bytes32,uint256)"));
    bytes4 internal constant EXECUTE_SEL = bytes4(keccak256("execute(address,uint256,bytes,bytes32,bytes32)"));

    function run() external {
        address diamond = vm.envOr("DIAMOND_ADDRESS", 0xC8F12AF2a396c9C906ac36Bc0AC2279BBb69Ef96);
        address timelock = vm.envOr("TIMELOCK_ADDRESS", 0xC5c64967CAA46e588cCe3eA97F761B5282e98882);
        bytes32 salt = vm.envOr("SALT", bytes32(0));
        uint256 delay = vm.envOr("DELAY", uint256(3600)); // live getMinDelay() = 1h (operator decision)

        ProtocolFeeMarketCut builder = new ProtocolFeeMarketCut();
        address newMarketFacet = vm.envOr("NEW_MARKET_FACET", address(0));
        if (newMarketFacet == address(0)) {
            newMarketFacet = builder.deployMarketFacet(); // simulation-only address; deploy for real in Phase A
            console2.log("NEW_MARKET_FACET (SIM only - deploy for real in Phase A):", newMarketFacet);
        }

        IDiamondCut.FacetCut[] memory cuts = builder.buildCuts(diamond, newMarketFacet); // reads live loupe
        bytes memory diamondCutData = abi.encodeWithSelector(IDiamondCut.diamondCut.selector, cuts, address(0), "");

        bytes memory scheduleCalldata =
            abi.encodeWithSelector(SCHEDULE_SEL, diamond, uint256(0), diamondCutData, bytes32(0), salt, delay);
        bytes memory executeCalldata =
            abi.encodeWithSelector(EXECUTE_SEL, diamond, uint256(0), diamondCutData, bytes32(0), salt);

        console2.log("=== Phase B: diamond MarketFacet cut via Timelock (PRINT ONLY) ===");
        console2.log("diamond     :", diamond);
        console2.log("timelock    :", timelock);
        console2.log("delay (sec) :", delay);
        console2.log("Replace selectors:", cuts[0].functionSelectors.length);
        console2.log("Add selectors    :", cuts[1].functionSelectors.length);
        console2.log("--- raw diamondCut calldata (target = diamond) ---");
        console2.logBytes(diamondCutData);
        console2.log("--- Timelock.schedule(...) calldata (target = timelock) ---");
        console2.logBytes(scheduleCalldata);
        console2.log("--- Timelock.execute(...) calldata (target = timelock, after >= delay) ---");
        console2.logBytes(executeCalldata);
    }
}
