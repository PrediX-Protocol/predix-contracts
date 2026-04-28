// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";
import {PrediXExchange} from "../../src/PrediXExchange.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockDiamond} from "../mocks/MockDiamond.sol";
import {ExchangeHandler} from "../invariant/ExchangeHandler.sol";

/// @title DustReproducer
/// @notice Replays the 16-call shrunk sequence Foundry captured when the strict
///         `invariant_solvency_yes == ` version of the invariant suite failed
///         (3-wei over-collateralization on YES).
///
///         Runs the exact same handler sequence step-by-step, logging
///         `exchangeYesBalance` and `Σ active SELL_YES depositLocked` after
///         every call, and identifies the call that introduces the drift.
///
///         Hypothesis under test (from §10.4 E5 report): synthetic MINT inside
///         `MakerPath._executeMintFill` uses `splitAmt = min(fillAmt,
///         usdcAvailable)` but increments `maker.filled += fillAmt` — mismatch
///         between shares booked and shares minted. If true, the drift appears
///         on a placeBuy call that phase-B MINT-matches against a BUY_NO maker.
contract DustReproducerTest is Test {
    MockERC20 internal usdc;
    MockDiamond internal diamond;
    PrediXExchange internal exchange;
    ExchangeHandler internal handler;

    address internal feeRecipient = makeAddr("feeRecipient");
    uint256 internal constant MARKET_ID = 1;
    address internal yesToken;
    address internal noToken;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        diamond = new MockDiamond(address(usdc));
        exchange = new PrediXExchange();
        exchange.initialize(address(diamond), address(usdc), feeRecipient);
        (yesToken, noToken) = diamond.createMarket(MARKET_ID, block.timestamp + 365 days, address(this));

        handler = new ExchangeHandler(exchange, usdc, diamond, MARKET_ID, yesToken, noToken);
    }

    function _sumActiveSellYesLocks() internal view returns (uint256 sum) {
        uint256 n = handler.orderCount();
        for (uint256 i; i < n; ++i) {
            IPrediXExchange.Order memory ord = exchange.getOrder(handler.orderAt(i));
            if (ord.cancelled || ord.filled >= ord.amount) continue;
            if (ord.side == IPrediXExchange.Side.SELL_YES) sum += ord.depositLocked;
        }
    }

    function _snapshot(string memory label) internal view {
        uint256 bal = IERC20(yesToken).balanceOf(address(exchange));
        uint256 sum = _sumActiveSellYesLocks();
        int256 drift = int256(bal) - int256(sum);
        console2.log(label);
        console2.log("  exchangeYes =", bal);
        console2.log("  sumLocked   =", sum);
        console2.log("  drift       =", drift);
    }

    function _dumpAllOrders(string memory label) internal view {
        console2.log(label);
        uint256 n = handler.orderCount();
        for (uint256 i; i < n; ++i) {
            bytes32 id = handler.orderAt(i);
            IPrediXExchange.Order memory o = exchange.getOrder(id);
            if (o.cancelled || o.filled >= o.amount) continue;
            console2.log("  order i=", i);
            console2.log("    side=", uint256(o.side));
            console2.log("    price=", o.price);
            console2.log("    amount=", o.amount);
            console2.log("    filled=", uint256(o.filled));
            console2.log("    locked=", uint256(o.depositLocked));
        }
    }

    function _sumActiveBuyUsdcLocks() internal view returns (uint256 sum) {
        uint256 n = handler.orderCount();
        for (uint256 i; i < n; ++i) {
            IPrediXExchange.Order memory ord = exchange.getOrder(handler.orderAt(i));
            if (ord.cancelled || ord.filled >= ord.amount) continue;
            if (ord.side == IPrediXExchange.Side.BUY_YES || ord.side == IPrediXExchange.Side.BUY_NO) {
                sum += ord.depositLocked;
            }
        }
    }

    function _snapshotUsdc(string memory label) internal view {
        uint256 bal = usdc.balanceOf(address(exchange));
        uint256 sum = _sumActiveBuyUsdcLocks();
        int256 drift = int256(bal) - int256(sum);
        console2.log(label);
        console2.log("  exchangeUsdc =", bal);
        console2.log("  sumBuyLocked =", sum);
        console2.log("  drift        =", drift);
    }

    /// @notice Targeted replay of the latest invariant shrunk trace:
    ///         USDC drift after placeBuy + placeSell + placeBuy sequence.
    function test_DustReproducer_UsdcDrift_ThreeCall_V2() public {
        _snapshotUsdc("0. initial");

        handler.placeBuy(2627, 4721, 164158391, false);
        _snapshotUsdc("1. placeBuy(BUY_NO)");
        _dumpAllOrders("=== orders after 1 ===");

        handler.placeSell(
            2676311729344103316363463277127636439,
            43839375449697553768005168,
            205417949622859056677692589019054745496222563816558265875,
            true
        );
        _snapshotUsdc("2. placeSell(SELL_YES)");
        _dumpAllOrders("=== orders after 2 ===");

        handler.placeBuy(
            3076183786298343621347774513509709408, 74175359188307, 1383286870804059084210309820610711062041493, true
        );
        _snapshotUsdc("3. placeBuy(BUY_YES)");
        _dumpAllOrders("=== orders after 3 ===");
    }

    /// @notice Targeted replay of the second invariant shrunk trace:
    ///         USDC over-collateralization 5 wei after a placeSell + placeBuy + fill.
    function test_DustReproducer_UsdcDrift_ThreeCall() public {
        _snapshotUsdc("0. initial");
        handler.placeSell(10000, 1_000_000, 2, false);
        _snapshotUsdc("1. placeSell(SELL_NO)");

        handler.placeBuy(1291, 11851, 17682, false);
        _snapshotUsdc("2. placeBuy(BUY_NO)");
        _dumpAllOrders("=== orders before call 3 ===");

        handler.fill(
            27120618587544372786449887905963976817434961139827835829,
            7750517143500065964515379704533830779176,
            115792089237316195423570985008687907853269984665640564039457584007913129639935,
            115792089237316195423570985008687907853269984665640564039457584007913129639932
        );
        _snapshotUsdc("3. fill(...)");
        _dumpAllOrders("=== orders after call 3 ===");
    }

    /// @notice Exact replay of the 16-call shrunk Foundry sequence.
    function test_DustReproducer_ShrunkSequence() public {
        _snapshot("0. initial");

        handler.placeSell(
            149111538122167220262926199438549451710178319929142,
            959473125264075059586873995144795019979935740701888735494445315795,
            7611778647,
            false
        );
        _snapshot("1. placeSell(NO)");

        handler.placeBuy(
            2358054259269925072990752226001132761572366154540702946300892003890006788187,
            880032528783550275865851273,
            6161671958789565935567524108225169476200275352928,
            false
        );
        _snapshot("2. placeBuy(NO)");

        handler.placeBuy(
            935109846689492755714948848293652887237220366757919491,
            44052663465948265014804185480246606075365396878117197793290752223195400,
            1273313020347,
            false
        );
        _snapshot("3. placeBuy(NO)");

        handler.placeBuy(
            309973972508416742118698364206572675392232199614181214186362569566309,
            317156134395869176929854025979387756,
            924917569859028605891559286080715243122474783237577509780,
            false
        );
        _snapshot("4. placeBuy(NO)");

        handler.placeBuy(
            19,
            25816418332523903795616,
            104183792020379637410000564453536989343415112357978741373712604775708401212,
            true
        );
        _snapshot("5. placeBuy(YES)");

        handler.placeBuy(
            6656440715058679893306364006204382759813629380,
            2597518173994509441271,
            296641137400097311181570164845480070322731,
            true
        );
        _snapshot("6. placeBuy(YES)");

        handler.placeBuy(1352095086195940, 3859160253, 131177779668006985862, true);
        _snapshot("7. placeBuy(YES)");

        handler.placeSell(
            21187284776995233470660045412659774773458,
            4802769737627005350310639373046729286219285171438574678576487,
            136898168075389330740951759888509280822474427386875579,
            false
        );
        _snapshot("8. placeSell(NO)");

        handler.placeSell(
            41213235921493008593779167453424361357717601633295534527422609,
            356293322614034424915946815334457627150476836929686827155841692068,
            73352294380195135307255875617335479424383511262487183,
            true
        );
        _snapshot("9. placeSell(YES)");

        handler.placeSell(
            127891698572108893984055987833309077530600,
            1774807304314911835339,
            878338033787908472221071981536630154567854276269961,
            true
        );
        _snapshot("10. placeSell(YES)");

        handler.placeSell(
            399784201869871049960897094895534526781408686302656219,
            58675279,
            115792089237316195423570985008687907853269984665640564039457584007913129639935,
            true
        );
        _snapshot("11. placeSell(YES)");

        handler.placeSell(128324, 439832113672887117927687374369292439, 946778800607145421522, false);
        _snapshot("12. placeSell(NO)");

        handler.placeBuy(
            1212706118910245060277636992242732500966778932725591356975703369,
            1097598050206295084,
            8719441120155218224182681175286,
            true
        );
        _snapshot("13. placeBuy(YES)");

        handler.fill(0, 5016188820817, 83172818, 4);
        _snapshot("14. fill(...)");

        handler.placeBuy(
            211856024376796508839062810817902370947478305116861720733432809,
            2268844504769680102500733360249499530513,
            0,
            true
        );
        _snapshot("15. placeBuy(YES)");
        _dumpAllOrders("=== orders before call 16 ===");
        console2.log("exchange YES=", IERC20(yesToken).balanceOf(address(exchange)));
        console2.log("exchange NO=", IERC20(noToken).balanceOf(address(exchange)));
        console2.log("exchange USDC=", usdc.balanceOf(address(exchange)));

        handler.fill(650988696772411798735255245332617539564818090654255685091379602, 4345, 3, 2);
        _snapshot("16. fill(...)");
        _dumpAllOrders("=== orders after call 16 ===");
        console2.log("exchange YES=", IERC20(yesToken).balanceOf(address(exchange)));
        console2.log("exchange NO=", IERC20(noToken).balanceOf(address(exchange)));
        console2.log("exchange USDC=", usdc.balanceOf(address(exchange)));

        uint256 finalBal = IERC20(yesToken).balanceOf(address(exchange));
        uint256 finalSum = _sumActiveSellYesLocks();
        console2.log("=== FINAL ===");
        console2.log("exchangeYes =", finalBal);
        console2.log("sumLocked   =", finalSum);
        console2.log("drift       =", int256(finalBal) - int256(finalSum));
        // Do NOT assert — reproducer only observes.
    }
}
