// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";
import {PrediXExchange} from "../../src/PrediXExchange.sol";
import {PrediXExchangeProxy} from "../../src/PrediXExchangeProxy.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockDiamond} from "../mocks/MockDiamond.sol";
import {MockBuilderRegistry} from "../mocks/MockBuilderRegistry.sol";

import {FeeExchangeHandler} from "./FeeExchangeHandler.sol";

/// @title FeeConservationInvariantTest — REVIEW_FIXES F3-6 / Task 10
/// @notice The hand-written fee tests assert exact per-fill ledgers; this proves the SAME conservation holds
///         across fuzzed multi-fill, multi-maker, mixed-price sequences with fees ON. The matching core never
///         creates, destroys, or strands a wei of USDC, and the exchange stays solvent for everything it owes.
contract FeeConservationInvariantTest is Test {
    MockERC20 internal usdc;
    MockDiamond internal diamond;
    PrediXExchange internal exchange;
    MockBuilderRegistry internal registry;
    FeeExchangeHandler internal handler;

    address internal feeRecipient = makeAddr("fc_feeRecipient");
    address internal treasury = makeAddr("fc_treasury");
    address internal builderRcpt = makeAddr("fc_builderRcpt");
    bytes32 internal constant CODE = keccak256("fc-builder");
    uint256 internal constant MARKET_ID = 1;

    address internal yesToken;
    address internal noToken;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        diamond = new MockDiamond(address(usdc));
        PrediXExchange impl = new PrediXExchange();
        PrediXExchangeProxy proxy =
            new PrediXExchangeProxy(address(impl), address(this), address(diamond), address(usdc), feeRecipient);
        exchange = PrediXExchange(address(proxy));
        (yesToken, noToken) = diamond.createMarket(MARKET_ID, block.timestamp + 365 days, address(this));

        // Fee system ON: builder code (taker 100 / maker 50 bps) + protocol coef 700 + rebate 25%.
        diamond.grantRole(Roles.ADMIN_ROLE, address(this));
        registry = new MockBuilderRegistry();
        registry.set(CODE, 100, 50, builderRcpt);
        exchange.setBuilderRegistry(address(registry));
        exchange.setProtocolFeeRecipient(treasury);
        diamond.setProtocolFee(MARKET_ID, 700, 2500);

        handler = new FeeExchangeHandler(exchange, usdc, diamond, MARKET_ID, yesToken, noToken, CODE);
        targetContract(address(handler));
    }

    /// @notice GLOBAL USDC conservation (I3): no wei of USDC is created, destroyed, or stranded by the fee
    ///         paths. Every minted wei lives in the exchange, the diamond's collateral, an actor, or a fee
    ///         recipient — nowhere else.
    function invariant_globalUsdcConservation() public view {
        uint256 sum = usdc.balanceOf(address(exchange)) + usdc.balanceOf(address(diamond))
            + usdc.balanceOf(feeRecipient) + usdc.balanceOf(treasury) + usdc.balanceOf(builderRcpt);
        for (uint256 i; i < 5; ++i) {
            sum += usdc.balanceOf(handler.actorAt(i));
        }
        assertEq(sum, handler.totalMinted(), "USDC conserved across all fee paths");
    }

    /// @notice CLAIMABLE solvency: the exchange always holds at least every USDC obligation it could be asked
    ///         to honor — active BUY deposits + accrued protocol cut + accrued builder fee. (It also holds the
    ///         un-gettable prefunded budgets, so this is `>=`.) A fee path that paid out more than it took, or
    ///         accrued without backing, would break this.
    function invariant_claimableSolvency() public view {
        uint256 owed = exchange.accruedProtocolFee() + exchange.accruedBuilderFee(CODE);
        uint256 n = handler.orderCount();
        for (uint256 i; i < n; ++i) {
            IPrediXExchange.Order memory ord = exchange.getOrder(handler.orderAt(i));
            if (ord.cancelled || ord.filled >= ord.amount) continue;
            if (ord.side == IPrediXExchange.Side.BUY_YES || ord.side == IPrediXExchange.Side.BUY_NO) {
                owed += ord.depositLocked;
            }
        }
        assertGe(usdc.balanceOf(address(exchange)), owed, "exchange solvent for all USDC obligations");
    }

    /// @notice I6 collateral conservation holds with fees on (fees never touch the YES/NO supply).
    function invariant_collateralPreserved() public view {
        assertEq(IERC20(yesToken).totalSupply(), IERC20(noToken).totalSupply(), "YES.supply == NO.supply");
    }
}
