// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {EventFacet} from "@predix/diamond/facets/event/EventFacet.sol";
import {ManualOracle} from "@predix/oracle/adapters/ManualOracle.sol";
import {PrediXMarketFactory} from "@predix/router/PrediXMarketFactory.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice Minimal interface for TestUSDC whitelist operations.
interface ITestUSDC {
    function setWhitelist(address account, bool status) external;
}

/// @title UpgradeEventOracle
/// @notice Upgrades the diamond's EventFacet to oracle-driven resolution, deploys a new
///         ManualOracle with event support, and redeploys MarketFactory with the updated
///         createEventWithPools signature. Single broadcast.
///
///         Steps:
///         1. Deploy new EventFacet
///         2. DiamondCut: remove old selectors + add new selectors
///         3. Deploy new ManualOracle (IOracle + IEventOracle)
///         4. Grant REPORTER_ROLE on new oracle to operator
///         5. Approve new oracle on Diamond
///         6. Deploy new MarketFactory
///         7. Grant CREATOR_ROLE to new factory
///         8. Whitelist new factory + new oracle on TestUSDC
contract UpgradeEventOracle is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address operator = vm.envAddress("OPERATOR_ADDRESS");
        address hook = vm.envAddress("HOOK_PROXY_ADDRESS");
        address lpTest = vm.envAddress("LP_TEST_ADDRESS");
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER_ADDRESS"));
        uint24 lpFeeFlag = uint24(vm.envUint("LP_FEE_FLAG"));
        int24 tickSpacing = int24(vm.envInt("TICK_SPACING"));

        vm.startBroadcast(deployerKey);

        // ── Step 1: Deploy new EventFacet ──
        EventFacet newEventFacet = new EventFacet();
        console2.log("new EventFacet:", address(newEventFacet));

        // ── Step 2: DiamondCut — swap EventFacet ──
        _upgradeDiamond(diamond, address(newEventFacet));
        console2.log("diamondCut: EventFacet upgraded");

        // ── Step 3: Deploy new ManualOracle ──
        ManualOracle newOracle = new ManualOracle(deployer, diamond);
        console2.log("new ManualOracle:", address(newOracle));

        // ── Step 4: Grant REPORTER_ROLE to operator ──
        newOracle.grantRole(newOracle.REPORTER_ROLE(), operator);
        console2.log("granted REPORTER_ROLE to operator");

        // ── Step 5: Approve new oracle on Diamond ──
        IMarketFacet(diamond).approveOracle(address(newOracle));
        console2.log("approved new oracle on Diamond");

        // ── Step 6: Deploy new MarketFactory ──
        PrediXMarketFactory newFactory =
            new PrediXMarketFactory(poolManager, diamond, usdc, hook, lpTest, lpFeeFlag, tickSpacing);
        console2.log("new MarketFactory:", address(newFactory));

        // ── Step 7: Grant CREATOR_ROLE to new factory ──
        IAccessControlFacet(diamond).grantRole(Roles.CREATOR_ROLE, address(newFactory));
        console2.log("granted CREATOR_ROLE to new factory");

        // ── Step 8: Whitelist new contracts on TestUSDC ──
        ITestUSDC(usdc).setWhitelist(address(newFactory), true);
        console2.log("whitelisted new factory on TestUSDC");

        vm.stopBroadcast();

        console2.log("============================================================");
        console2.log("UpgradeEventOracle complete");
        console2.log("============================================================");
        console2.log("EventFacet:    ", address(newEventFacet));
        console2.log("ManualOracle:  ", address(newOracle));
        console2.log("MarketFactory: ", address(newFactory));
    }

    function _upgradeDiamond(address diamond, address newEventFacet) internal {
        // Old selectors to remove (createEvent 3-arg, resolveEvent 2-arg)
        bytes4[] memory removeSels = new bytes4[](2);
        removeSels[0] = bytes4(0xf36ccc5c); // createEvent(string,string[],uint256)
        removeSels[1] = bytes4(0x64f66467); // resolveEvent(uint256,uint256)

        // Unchanged selectors to replace (point to new facet)
        bytes4[] memory replaceSels = new bytes4[](4);
        replaceSels[0] = IEventFacet.enableEventRefundMode.selector;
        replaceSels[1] = IEventFacet.getEvent.selector;
        replaceSels[2] = IEventFacet.eventOfMarket.selector;
        replaceSels[3] = IEventFacet.eventCount.selector;

        // New selectors to add
        bytes4[] memory addSels = new bytes4[](5);
        addSels[0] = IEventFacet.createEvent.selector;
        addSels[1] = IEventFacet.resolveEvent.selector;
        addSels[2] = IEventFacet.emergencyResolveEvent.selector;
        addSels[3] = IEventFacet.getEventStatus.selector;
        addSels[4] = IEventFacet.sweepUnclaimedEvent.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](3);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(0),
            action: IDiamondCut.FacetCutAction.Remove,
            functionSelectors: removeSels
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: newEventFacet,
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: replaceSels
        });
        cuts[2] = IDiamondCut.FacetCut({
            facetAddress: newEventFacet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: addSels
        });

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
    }
}
