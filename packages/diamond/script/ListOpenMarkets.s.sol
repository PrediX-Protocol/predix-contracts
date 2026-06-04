// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

interface IMulticall3 {
    struct Call3 {
        address target;
        bool allowFailure;
        bytes callData;
    }

    struct Result {
        bool success;
        bytes returnData;
    }

    function aggregate3(Call3[] calldata calls) external view returns (Result[] memory);
}

/// @notice READ-ONLY: enumerate OPEN markets (endTime in the future, not resolved, not refund-mode) using a
///         single Multicall3 batch of `getMarketStatus` calls — one RPC round-trip instead of N (the serial
///         path is too slow on the public RPC). Prints each open market's id / YES token / USDC-orientation /
///         and the open count + orientation split.
/// @dev    Required env: DIAMOND_ADDRESS, USDC_ADDRESS.
contract ListOpenMarkets is Script {
    IMulticall3 internal constant MULTICALL = IMulticall3(0xcA11bde05977b3631167028862bE2a173976CA11);

    function run() external view {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        uint256 mc = IMarketFacet(diamond).marketCount();

        IMulticall3.Call3[] memory calls = new IMulticall3.Call3[](mc);
        for (uint256 i; i < mc; ++i) {
            calls[i] = IMulticall3.Call3({
                target: diamond, allowFailure: true, callData: abi.encodeCall(IMarketFacet.getMarketStatus, (i + 1))
            });
        }
        IMulticall3.Result[] memory res = MULTICALL.aggregate3(calls);

        uint256 open;
        uint256 c0;
        uint256 c1;
        for (uint256 i; i < mc; ++i) {
            if (!res[i].success) continue;
            (address yes,, uint256 endTime, bool isResolved, bool refund) =
                abi.decode(res[i].returnData, (address, address, uint256, bool, bool));
            if (yes == address(0)) continue;
            if (!(block.timestamp < endTime && !isResolved && !refund)) continue;
            ++open;
            bool yesC0 = yes < usdc;
            if (yesC0) ++c0;
            else ++c1;
            console2.log("OPEN id=", i + 1, yes);
        }
        console2.log("=== marketCount:", mc);
        console2.log("=== OPEN MARKETS:", open);
        console2.log("=== YES-currency0:", c0);
        console2.log("=== YES-currency1:", c1);
    }
}
