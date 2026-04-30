// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

/// @notice Tries buyYes then sellYes in a single tx to trigger anti-sandwich.
///         Expects the second call to revert with SandwichDetected.
contract SandwichAttacker {
    IPrediXRouter public immutable router;
    address public immutable usdc;
    address public immutable yesToken;
    uint256 public immutable marketId;

    bool public firstSwapOk;
    bool public secondSwapReverted;
    bytes public secondRevertReason;

    constructor(address _router, address _usdc, address _yesToken, uint256 _marketId) {
        router = IPrediXRouter(_router);
        usdc = _usdc;
        yesToken = _yesToken;
        marketId = _marketId;
    }

    function attack(uint256 amount) external {
        IERC20(usdc).approve(address(router), type(uint256).max);
        IERC20(yesToken).approve(address(router), type(uint256).max);

        // First swap: buyYes
        router.buyYes(marketId, amount, 1, address(this), 10, block.timestamp + 300);
        firstSwapOk = true;

        // Second swap: sellYes (opposite direction, same block, same identity)
        uint256 yesBal = IERC20(yesToken).balanceOf(address(this));
        try router.sellYes(marketId, yesBal, 1, address(this), 10, block.timestamp + 300) {
            secondSwapReverted = false;
        } catch (bytes memory reason) {
            secondSwapReverted = true;
            secondRevertReason = reason;
        }
    }
}

contract E2ESandwichTest is Script {
    function run() external {
        uint256 marketId = vm.envUint("E2E_MARKET_ID");
        address router = vm.envAddress("PREDIX_ROUTER_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address diamond = vm.envAddress("DIAMOND_ADDRESS");

        IMarketFacet.MarketView memory m = IMarketFacet(diamond).getMarket(marketId);
        address yesToken = m.yesToken;

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        // Deploy attacker
        SandwichAttacker attacker = new SandwichAttacker(router, usdc, yesToken, marketId);

        // Fund attacker
        IERC20(usdc).transfer(address(attacker), 100e6);

        // Execute attack
        attacker.attack(10e6);

        console2.log("firstSwapOk:", attacker.firstSwapOk());
        console2.log("secondSwapReverted:", attacker.secondSwapReverted());

        vm.stopBroadcast();

        require(attacker.firstSwapOk(), "first swap should succeed");
        require(attacker.secondSwapReverted(), "second swap should revert (sandwich detected)");
        console2.log("ANTI-SANDWICH TEST PASSED");
    }
}
