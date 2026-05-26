// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test, console2} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {OutcomeToken} from "@predix/shared/tokens/OutcomeToken.sol";
import {OutcomeTokenClone} from "@predix/shared/tokens/OutcomeTokenClone.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

/// @notice Gas benchmark — current `new OutcomeToken(...)` vs EIP-1167 clone path.
contract OutcomeTokenBench is Test {
    address constant FACTORY = address(0xC8F12AF2a396c9C906ac36Bc0AC2279BBb69Ef96);

    OutcomeTokenClone master;

    function setUp() external {
        // Deploy master impl once (one-time cost, measured separately).
        uint256 g0 = gasleft();
        master = new OutcomeTokenClone(FACTORY);
        uint256 masterDeployGas = g0 - gasleft();
        console2.log("=== ONE-TIME COSTS ===");
        console2.log("Master OutcomeTokenClone deploy gas:", masterDeployGas);
        console2.log("");
    }

    /// @notice Measure gas per market creation under current path (2x new OutcomeToken).
    function testGasCurrentPath() external {
        console2.log("=== CURRENT PATH (new OutcomeToken x2) ===");
        uint256 totalGas;
        uint256 N = 5;
        for (uint256 i = 1; i <= N; ++i) {
            string memory id = Strings.toString(i);
            uint256 g0 = gasleft();
            OutcomeToken yes =
                new OutcomeToken(FACTORY, i, true, string.concat("PrediX YES #", id), string.concat("pxY-", id));
            OutcomeToken no =
                new OutcomeToken(FACTORY, i, false, string.concat("PrediX NO #", id), string.concat("pxN-", id));
            uint256 gas = g0 - gasleft();
            totalGas += gas;
            console2.log(string.concat("  market #", id, " gas: "), gas);
            yes;
            no; // silence warnings
        }
        uint256 avg = totalGas / N;
        console2.log("AVG gas/market (current):", avg);
        console2.log("");
    }

    /// @notice Measure gas per market creation under clone path.
    function testGasClonePath() external {
        console2.log("=== CLONE PATH (Clones.clone + initialize) x2 ===");
        uint256 totalGas;
        uint256 N = 5;
        for (uint256 i = 1; i <= N; ++i) {
            string memory id = Strings.toString(i);
            uint256 g0 = gasleft();
            address yes = Clones.clone(address(master));
            OutcomeTokenClone(yes).initialize(i, true, string.concat("PrediX YES #", id), string.concat("pxY-", id));
            address no = Clones.clone(address(master));
            OutcomeTokenClone(no).initialize(i, false, string.concat("PrediX NO #", id), string.concat("pxN-", id));
            uint256 gas = g0 - gasleft();
            totalGas += gas;
            console2.log(string.concat("  market #", id, " gas: "), gas);
        }
        uint256 avg = totalGas / N;
        console2.log("AVG gas/market (clone):", avg);
        console2.log("");
    }

    /// @notice Verify clone is functional after init (mint, balance).
    function testCloneFunctional() external {
        address clone1 = Clones.clone(address(master));
        OutcomeTokenClone t = OutcomeTokenClone(clone1);
        t.initialize(42, true, "Test YES #42", "txY-42");
        assertEq(t.name(), "Test YES #42");
        assertEq(t.symbol(), "txY-42");
        assertEq(t.decimals(), 6);
        assertEq(t.factory(), FACTORY);
        assertEq(t.marketId(), 42);
        assertTrue(t.isYes());

        // Mint from factory works
        vm.prank(FACTORY);
        t.mint(address(this), 100);
        assertEq(t.balanceOf(address(this)), 100);

        // Mint from non-factory fails with IOutcomeToken's typed error
        vm.expectRevert(IOutcomeToken.OutcomeToken_NotFactory.selector);
        t.mint(address(this), 1);

        // Cannot re-initialize (Initializable revert)
        vm.expectRevert();
        t.initialize(43, false, "hax", "h");
    }
}
