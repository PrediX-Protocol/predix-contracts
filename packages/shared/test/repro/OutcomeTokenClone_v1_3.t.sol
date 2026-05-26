// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {OutcomeTokenClone} from "@predix/shared/tokens/OutcomeTokenClone.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

/// @title OutcomeTokenClone_v1_3_Repro
/// @notice Repro / regression lock for the v1.3 upgrade — switching outcome tokens
///         from `new OutcomeToken(...)` to EIP-1167 `Clones.clone(impl) + initialize`.
///
/// @dev Pins behaviour that is structurally different from the pre-v1.3 contract and
///      therefore must not silently regress on a future cut:
///
///        T1. Multi-clone storage isolation. Each minimal-proxy clone holds its own
///            balances / marketId / isYes / permit nonces. A defect in master shared
///            storage (e.g. accidentally moving a balance into immutable / constant)
///            would surface here as a cross-clone read.
///        T2. Master `_disableInitializers()` blocks calling `initialize` directly
///            on the master impl — guards against a deployer being tricked into
///            initialising the master to attacker-controlled values, which would
///            poison every future clone via the inherited factory immutable.
///        T3. EIP-2612 permit `DOMAIN_SEPARATOR` is computed per-clone, not cached
///            in master bytecode. A permit signed for clone A must NOT be replayable
///            on clone B even if both share the same master + the same owner key.
///        T4. `factory()` returns the diamond via DELEGATECALL — the immutable lives
///            in master code, but clones inherit it correctly.
///        T5. Re-initialize is blocked on a clone that has already been initialised
///            (`Initializable._initialized` flag handles this; we lock it in).
contract OutcomeTokenClone_v1_3_Repro is Test {
    /// @dev Mainnet diamond address used as a stable factory fixture — the master's
    ///      `factory` is `immutable` so we set it once here and reuse it across tests.
    address constant FACTORY = address(0xC8F12AF2a396c9C906ac36Bc0AC2279BBb69Ef96);

    OutcomeTokenClone internal master;

    // Two clones standing in for the YES/NO pair of a single market (T1, T3, T4).
    OutcomeTokenClone internal yesA;
    OutcomeTokenClone internal noA;
    // A second pair, standing in for a different market, to assert per-clone state.
    OutcomeTokenClone internal yesB;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() external {
        master = new OutcomeTokenClone(FACTORY);

        yesA = OutcomeTokenClone(Clones.clone(address(master)));
        yesA.initialize(1, true, "PrediX YES #1", "pxY-1");

        noA = OutcomeTokenClone(Clones.clone(address(master)));
        noA.initialize(1, false, "PrediX NO #1", "pxN-1");

        yesB = OutcomeTokenClone(Clones.clone(address(master)));
        yesB.initialize(2, true, "PrediX YES #2", "pxY-2");
    }

    // ───────────────────────────── T1 ─────────────────────────────

    /// @notice Mints to one clone must not touch another clone's balances or
    ///         totalSupply.
    function test_T1_MultiClone_StorageIsolation() external {
        vm.prank(FACTORY);
        yesA.mint(alice, 1_000_000);

        // yesA — touched
        assertEq(yesA.balanceOf(alice), 1_000_000, "yesA balance");
        assertEq(yesA.totalSupply(), 1_000_000, "yesA supply");

        // noA, yesB — untouched
        assertEq(noA.balanceOf(alice), 0, "noA balance must be untouched");
        assertEq(noA.totalSupply(), 0, "noA supply must be untouched");
        assertEq(yesB.balanceOf(alice), 0, "yesB balance must be untouched");
        assertEq(yesB.totalSupply(), 0, "yesB supply must be untouched");

        // marketId / isYes — per-clone storage
        assertEq(yesA.marketId(), 1);
        assertEq(noA.marketId(), 1);
        assertEq(yesB.marketId(), 2);
        assertTrue(yesA.isYes());
        assertFalse(noA.isYes());
        assertTrue(yesB.isYes());

        // factory — shared via master immutable, same for ALL clones.
        assertEq(yesA.factory(), FACTORY);
        assertEq(noA.factory(), FACTORY);
        assertEq(yesB.factory(), FACTORY);
        // ... and equal to the master's own factory.
        assertEq(master.factory(), FACTORY);
    }

    // ───────────────────────────── T2 ─────────────────────────────

    /// @notice The master itself must never be initialisable (constructor calls
    ///         `_disableInitializers()`). Any attempt to call `initialize` on the
    ///         master reverts.
    function test_T2_Master_InitializeReverts() external {
        // OZ v5 Initializable revert is `InvalidInitialization()`.
        // We use a generic revert match because OZ's selector may move between minor
        // versions; the assertion that matters is "this MUST revert", not the bytes.
        vm.expectRevert();
        master.initialize(99, true, "hax", "h");
    }

    // ───────────────────────────── T3 ─────────────────────────────

    /// @notice A permit signed for clone A's DOMAIN_SEPARATOR must NOT validate
    ///         against clone B — i.e. each clone computes its DOMAIN_SEPARATOR
    ///         from its own address, not the master's. This is the property that
    ///         lets EIP-1167 share permit code without cross-clone replay risk.
    function test_T3_Permit_ClaimScopedToCloneAddress() external {
        uint256 ownerPk = 0xBEEF;
        address owner = vm.addr(ownerPk);

        vm.prank(FACTORY);
        yesA.mint(owner, 1_000);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 typehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

        // Sign for yesA.
        bytes32 structHash = keccak256(abi.encode(typehash, owner, bob, 500, yesA.nonces(owner), deadline));
        bytes32 digestA = keccak256(abi.encodePacked("\x19\x01", yesA.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digestA);

        // Replay on yesB MUST fail — yesB's DOMAIN_SEPARATOR differs (different address).
        vm.expectRevert();
        yesB.permit(owner, bob, 500, deadline, v, r, s);
        assertEq(yesB.allowance(owner, bob), 0, "yesB allowance must remain 0 after replay attempt");

        // The original signature DOES land on yesA.
        yesA.permit(owner, bob, 500, deadline, v, r, s);
        assertEq(yesA.allowance(owner, bob), 500, "yesA allowance set by permit");

        // Defence in depth: DOMAIN_SEPARATORs must differ across clones.
        assertTrue(yesA.DOMAIN_SEPARATOR() != yesB.DOMAIN_SEPARATOR(), "domain separators must differ per clone");
    }

    // ───────────────────────────── T4 ─────────────────────────────

    /// @notice `factory()` reads master's immutable through DELEGATECALL — the
    ///         clone bytecode itself does not store the factory address.
    function test_T4_Factory_InheritedViaDelegatecall() external view {
        // Clones inherit the SAME factory from master.
        assertEq(yesA.factory(), master.factory());
        assertEq(noA.factory(), master.factory());
        assertEq(yesB.factory(), master.factory());

        // Only this factory may mint / burn.
        assertEq(yesA.factory(), FACTORY);
    }

    /// @notice Mint / burn must revert for any caller other than factory.
    function test_T4_OnlyFactory_MintBurn() external {
        vm.prank(FACTORY);
        yesA.mint(alice, 100);

        // Non-factory mint fails with the typed interface error.
        vm.expectRevert(IOutcomeToken.OutcomeToken_NotFactory.selector);
        yesA.mint(bob, 1);

        // Non-factory burn also fails.
        vm.expectRevert(IOutcomeToken.OutcomeToken_NotFactory.selector);
        yesA.burn(alice, 1);
    }

    // ───────────────────────────── T5 ─────────────────────────────

    /// @notice `initialize` can only be called once per clone. Subsequent calls
    ///         revert via OZ Initializable. Without this guard, an attacker could
    ///         re-initialise a freshly-minted clone before `LibMarket` writes the
    ///         next outcome's args.
    function test_T5_ReInitialize_Blocked() external {
        // yesA was initialised in setUp.
        vm.expectRevert();
        yesA.initialize(99, false, "hijack YES", "hjY");

        // The original state must be intact.
        assertEq(yesA.marketId(), 1);
        assertTrue(yesA.isYes());
        assertEq(yesA.name(), "PrediX YES #1");
    }

    // ───────────────────────────── T6 (sanity) ─────────────────────

    /// @notice Sanity: clones must be exactly the canonical 45-byte EIP-1167 proxy
    ///         pointing at master. If the bytecode grows, either OZ's Clones lib
    ///         changed or someone deployed a non-minimal proxy.
    function test_T6_CloneBytecode_Is45ByteEIP1167() external view {
        bytes memory yesACode = address(yesA).code;
        bytes memory noACode = address(noA).code;
        bytes memory yesBCode = address(yesB).code;

        assertEq(yesACode.length, 45, "EIP-1167 minimal proxy is 45 bytes");
        assertEq(noACode.length, 45);
        assertEq(yesBCode.length, 45);

        // Bytecode is identical across clones of the same master.
        assertEq(keccak256(yesACode), keccak256(noACode));
        assertEq(keccak256(noACode), keccak256(yesBCode));
    }
}
