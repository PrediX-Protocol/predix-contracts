// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";

/// @notice Scan diamond for unresolved+ended markets and events.
contract AuditUnresolved is Script {
    function run() external view {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        uint256 mc = IMarketFacet(diamond).marketCount();
        uint256 ec = IEventFacet(diamond).eventCount();
        uint256 now_ = block.timestamp;
        console2.log("now ts:", now_);
        console2.log("marketCount:", mc);
        console2.log("eventCount:", ec);
        console2.log("");
        console2.log("=== UNRESOLVED + ENDED + not refund - BINARY markets (eid=0) ===");
        uint256 binaryCount;
        for (uint256 i = 1; i <= mc; ++i) {
            IMarketFacet.MarketView memory m = IMarketFacet(diamond).getMarket(i);
            if (m.eventId != 0) continue;
            if (m.isResolved || m.refundModeActive) continue;
            if (m.endTime > now_) continue;
            console2.log(
                string.concat(
                    "  id=",
                    vm.toString(i),
                    " end=",
                    vm.toString(m.endTime),
                    " (ago ",
                    vm.toString(now_ - m.endTime),
                    "s)"
                )
            );
            binaryCount++;
        }
        console2.log("  total binary to resolve:", binaryCount);
        console2.log("");
        console2.log("=== UNRESOLVED + ENDED - EVENTS ===");
        uint256 eventCount;
        for (uint256 eid = 1; eid <= ec; ++eid) {
            IEventFacet.EventView memory e = IEventFacet(diamond).getEvent(eid);
            if (e.isResolved || e.refundModeActive) continue;
            string memory status = e.endTime > now_ ? "future" : "ENDED";
            string memory line = string.concat(
                "  eid=",
                vm.toString(eid),
                " end=",
                vm.toString(e.endTime),
                " status=",
                status,
                " children=",
                vm.toString(e.marketIds.length),
                " name=\"",
                e.name,
                "\""
            );
            console2.log(line);
            if (e.endTime <= now_) eventCount++;
        }
        console2.log("  total events to resolve:", eventCount);
    }
}
