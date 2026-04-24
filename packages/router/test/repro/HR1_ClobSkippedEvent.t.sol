// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {IPrediXExchangeView} from "@predix/router/interfaces/IPrediXExchangeView.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";
import {PrediXRouter} from "@predix/router/PrediXRouter.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {RouterFixture} from "../utils/RouterFixture.sol";

/// @dev Minimal exchange stub that always reverts with the requested selector (or no
///      data). Kept local because the shared `MockExchange` only reverts with a string,
///      which is Error(string) selector 0x08c379a0 and does not exercise the zero-length
///      / typed-error branches of the H-R1 selector extraction.
contract HR1RevertingExchange {
    bytes4 public revertSelector;
    bool public revertEmpty;

    function setRevertSelector(bytes4 sel) external {
        revertSelector = sel;
        revertEmpty = false;
    }

    function setRevertEmpty() external {
        revertEmpty = true;
        revertSelector = bytes4(0);
    }

    function fillMarketOrder(
        uint256, /* marketId */
        IPrediXExchangeView.Side, /* takerSide */
        uint256, /* limitPrice */
        uint256, /* amountIn */
        address, /* taker */
        address, /* recipient */
        uint256, /* maxFills */
        uint256 /* deadline */
    )
        external
        view
        returns (uint256, uint256)
    {
        if (revertEmpty) {
            assembly {
                revert(0, 0)
            }
        }
        bytes4 sel = revertSelector;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, sel)
            revert(ptr, 0x04)
        }
    }

    function previewFillMarketOrder(
        uint256, /* marketId */
        IPrediXExchangeView.Side, /* takerSide */
        uint256, /* limitPrice */
        uint256, /* amountIn */
        uint256 /* maxFills */
    )
        external
        pure
        returns (uint256, uint256)
    {
        return (0, 0);
    }
}

/// @notice Repro for H-R1 / FINAL-M13: router's CLOB try/catch emits
///         `ClobSkipped(marketId, recipient, reason)` on fallback and extracts
///         the 4-byte selector of the revert error. Preserves AMM-only
///         resilience (no re-throw) but makes silent CLOB reverts observable.
contract HR1_ClobSkippedEvent is RouterFixture {
    /// @dev The shared MockExchange reverts with a string `"MockExchange: revertOnFill"`.
    ///      Solidity encodes that as `Error(string)` whose selector is 0x08c379a0.
    bytes4 internal constant ERROR_STRING_SELECTOR = 0x08c379a0;

    function _approveUsdcAsAlice(uint256 amount) internal {
        vm.prank(alice);
        usdc.approve(address(router), amount);
    }

    function _approveYesAsAlice(uint256 amount) internal {
        vm.prank(alice);
        yes1.approve(address(router), amount);
    }

    /// @dev Replace the fixture's canonical exchange with a router pointed at
    ///      `newExchange`. Needed because the router's `exchange` is immutable.
    function _rewireRouterTo(address newExchange) internal {
        router = new PrediXRouter(
            IPoolManager(address(poolManager)),
            address(diamond),
            address(usdc),
            address(hook),
            newExchange,
            IV4Quoter(address(quoter)),
            IAllowanceTransfer(address(permit2)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60
        );
    }

    function test_HR1_ExchangePaused_EmitsClobSkipped() public {
        // Trigger the fixture mock's revert path (string revert).
        exchange.setRevertOnFill(true);

        // AMM must supply the full trade so the fallback succeeds.
        if (address(usdc) < address(yes1)) {
            poolManager.queueSwapResult(-int128(int256(uint256(100e6))), int128(180e6));
        } else {
            poolManager.queueSwapResult(int128(180e6), -int128(int256(uint256(100e6))));
        }

        _approveUsdcAsAlice(100e6);

        vm.expectEmit(true, true, false, true, address(router));
        emit IPrediXRouter.ClobSkipped(MARKET_ID, alice, ERROR_STRING_SELECTOR);

        vm.prank(alice);
        router.buyYes(MARKET_ID, 100e6, 0, alice, 5, _deadline());
    }

    function test_HR1_EmptyCLOB_NoEmit_FullAmmRoute() public {
        // No canned CLOB result + no revert → fillMarketOrder returns (0, 0).
        // No event should fire because the CLOB did not revert.
        if (address(usdc) < address(yes1)) {
            poolManager.queueSwapResult(-int128(int256(uint256(100e6))), int128(180e6));
        } else {
            poolManager.queueSwapResult(int128(180e6), -int128(int256(uint256(100e6))));
        }

        _approveUsdcAsAlice(100e6);

        vm.recordLogs();
        vm.prank(alice);
        router.buyYes(MARKET_ID, 100e6, 0, alice, 5, _deadline());

        bytes32 topic = keccak256("ClobSkipped(uint256,address,bytes4)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic) {
                fail("ClobSkipped should not fire when fillMarketOrder returns cleanly");
            }
        }
    }

    function test_HR1_RevertNoData_ZeroSelector() public {
        HR1RevertingExchange stub = new HR1RevertingExchange();
        stub.setRevertEmpty();
        _rewireRouterTo(address(stub));

        if (address(usdc) < address(yes1)) {
            poolManager.queueSwapResult(-int128(int256(uint256(100e6))), int128(180e6));
        } else {
            poolManager.queueSwapResult(int128(180e6), -int128(int256(uint256(100e6))));
        }

        _approveUsdcAsAlice(100e6);

        vm.expectEmit(true, true, false, true, address(router));
        emit IPrediXRouter.ClobSkipped(MARKET_ID, alice, bytes4(0));

        vm.prank(alice);
        router.buyYes(MARKET_ID, 100e6, 0, alice, 5, _deadline());
    }

    function test_HR1_SellPathAlsoEmits() public {
        // Sell flow: give alice YES, approve to router, wire AMM sell.
        exchange.setRevertOnFill(true);

        // SELL_YES: YES in → USDC out. AMM swap: YES -> USDC.
        if (address(yes1) < address(usdc)) {
            poolManager.queueSwapResult(-int128(int256(uint256(100e6))), int128(40e6));
        } else {
            poolManager.queueSwapResult(int128(40e6), -int128(int256(uint256(100e6))));
        }

        _approveYesAsAlice(100e6);

        vm.expectEmit(true, true, false, true, address(router));
        emit IPrediXRouter.ClobSkipped(MARKET_ID, alice, ERROR_STRING_SELECTOR);

        vm.prank(alice);
        router.sellYes(MARKET_ID, 100e6, 0, alice, 5, _deadline());
    }

    function test_HR1_RecipientInEvent_IsEndUser_NotRouter() public {
        // Event's second indexed field is `msg.sender` at router entry — this
        // test locks it to the tx.origin-equivalent (alice), never the router.
        exchange.setRevertOnFill(true);

        if (address(usdc) < address(yes1)) {
            poolManager.queueSwapResult(-int128(int256(uint256(100e6))), int128(180e6));
        } else {
            poolManager.queueSwapResult(int128(180e6), -int128(int256(uint256(100e6))));
        }

        _approveUsdcAsAlice(100e6);

        vm.recordLogs();
        vm.prank(alice);
        router.buyYes(MARKET_ID, 100e6, 0, alice, 5, _deadline());

        bytes32 topic = keccak256("ClobSkipped(uint256,address,bytes4)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address recipient;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(router) && logs[i].topics.length == 3 && logs[i].topics[0] == topic) {
                recipient = address(uint160(uint256(logs[i].topics[2])));
                break;
            }
        }
        assertEq(recipient, alice, "ClobSkipped recipient must be end user, not router");
    }
}
