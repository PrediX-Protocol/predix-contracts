// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {PrediXMarketFactory} from "@predix/router/PrediXMarketFactory.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockLpTest} from "../mocks/MockLpTest.sol";

/// @dev Slim diamond that gives the factory just enough surface to run
///      `addLiquidity` — `hasRole`, `getMarket`, and `splitPosition`.
contract FactoryAllowanceDiamond {
    bytes32 internal constant CREATOR_ROLE = keccak256("predix.role.creator");

    address public usdc;
    address public yesToken;
    address public noToken;
    uint256 public totalCollateral;
    mapping(address => bool) public creators;

    constructor(address _usdc, address _yes, address _no) {
        usdc = _usdc;
        yesToken = _yes;
        noToken = _no;
    }

    function setCreator(address who, bool ok) external {
        creators[who] = ok;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        if (role != CREATOR_ROLE) return false;
        return creators[account];
    }

    function getMarket(uint256) external view returns (IMarketFacet.MarketView memory v) {
        v.yesToken = yesToken;
        v.noToken = noToken;
        v.endTime = block.timestamp + 30 days;
        v.totalCollateral = totalCollateral;
    }

    function splitPosition(uint256, uint256 amount) external {
        totalCollateral += amount;
        IERC20(usdc).transferFrom(msg.sender, address(this), amount);
        MockERC20(yesToken).mint(msg.sender, amount);
        MockERC20(noToken).mint(msg.sender, amount);
    }
}

/// @title PrediXMarketFactoryAllowanceTest
/// @notice M-06 — `_splitAndAddLiquidity` must scope its `forceApprove(lpTest, ...)`
///         to the per-call budget and zero it on exit. The legacy
///         `forceApprove(lpTest, max)` left a standing allowance that survived
///         the call, exposing the factory to any future compromise of the
///         liquidity router contract.
contract PrediXMarketFactoryAllowanceTest is Test {
    PrediXMarketFactory internal factory;
    FactoryAllowanceDiamond internal diamond;
    MockERC20 internal usdc;
    MockERC20 internal yes;
    MockERC20 internal no_;
    MockLpTest internal lpTest;

    address internal hook = makeAddr("hook");
    address internal poolManager = makeAddr("poolManager");
    address internal creator = makeAddr("creator");

    uint256 internal constant MARKET_ID = 1;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        yes = new MockERC20("YES", "YES", 6);
        no_ = new MockERC20("NO", "NO", 6);
        diamond = new FactoryAllowanceDiamond(address(usdc), address(yes), address(no_));
        diamond.setCreator(creator, true);

        lpTest = new MockLpTest();
        lpTest.setObservedTokens(address(yes), address(usdc));

        factory = new PrediXMarketFactory(
            IPoolManager(poolManager),
            address(diamond),
            address(usdc),
            hook,
            address(lpTest),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60
        );

        // Fund creator + approve factory.
        usdc.mint(creator, 10_000e6);
        vm.prank(creator);
        usdc.approve(address(factory), type(uint256).max);
    }

    function test_AddLiquidity_AllowanceScopedDuringCall() public {
        uint256 budget = 1_000e6;
        uint256 expectedSplit = (budget * 3) / 4;
        uint256 expectedUsdcForLp = budget - expectedSplit;

        vm.prank(creator);
        factory.addLiquidity(MARKET_ID, 1_000_000, budget);

        // `lpTest.modifyLiquidity` records the allowance at the moment it ran.
        // The fix guarantees this is the BOUNDED amount, not `type(uint256).max`.
        assertEq(lpTest.observedYesAllowance(), expectedSplit);
        assertEq(lpTest.observedUsdcAllowance(), expectedUsdcForLp);
        assertLt(lpTest.observedYesAllowance(), type(uint256).max);
        assertLt(lpTest.observedUsdcAllowance(), type(uint256).max);
    }

    function test_AddLiquidity_AllowanceZeroAfterCall() public {
        uint256 budget = 1_000e6;
        vm.prank(creator);
        factory.addLiquidity(MARKET_ID, 1_000_000, budget);

        // Standing allowance to lpTest after the call must be 0. A future
        // compromise of the liquidity router cannot pull from the factory.
        assertEq(yes.allowance(address(factory), address(lpTest)), 0);
        assertEq(usdc.allowance(address(factory), address(lpTest)), 0);
    }
}
