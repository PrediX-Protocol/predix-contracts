// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @notice Verifies that the canonical Uniswap v4 `PoolManager` on the
///         forked chain actually exposes the interface the hook compiles
///         against. Catches ABI drift between the `v4-core` headers pinned
///         in `lib/uniswap-hooks/lib/v4-core` (pragma `0.8.26`, interface
///         only) and whatever version is actually deployed on the target
///         chain.
/// @dev Full pool registration and swap flows require CREATE2 hook-address
///      mining — that path is exercised by the unit suite against
///      `TestHookHarness`. The fork test scope is strictly "does the real
///      PoolManager accept the calls the hook will make with the shapes
///      the interface headers promise".
contract PoolManagerInterfaceForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal poolManager;

    function setUp() public {
        vm.createSelectFork(vm.envString("UNICHAIN_RPC_PRIMARY"));
        poolManager = IPoolManager(vm.envAddress("POOL_MANAGER_ADDRESS"));
    }

    function test_PoolManager_Deployed() public view {
        uint256 size;
        address addr = address(poolManager);
        assembly {
            size := extcodesize(addr)
        }
        assertGt(size, 1_000, "PoolManager too small to be real");
    }

    function test_PoolManager_OwnerReadable() public view {
        (bool ok, bytes memory ret) = address(poolManager).staticcall(abi.encodeWithSignature("owner()"));
        assertTrue(ok, "owner() call reverted");
        address owner = abi.decode(ret, (address));
        assertTrue(owner != address(0), "owner is zero - not a real PoolManager");
    }

    function test_PoolManager_GetSlot0_EmptyPool_ReturnsZero() public view {
        // A fabricated pool key that almost certainly has not been initialised
        // on the forked chain. getSlot0 returns the zero-tuple for unknown
        // pools — the point is to verify the ABI shape matches.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0xDEAD)),
            currency1: Currency.wrap(address(0xBEEF)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PoolId id = key.toId();
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(id);
        assertEq(sqrtPriceX96, 0);
        assertEq(tick, int24(0));
        assertEq(protocolFee, 0);
        assertEq(lpFee, 0);
    }

    function test_PoolManager_Extsload_AnySlot_DoesNotRevert() public view {
        // PoolManager exposes `extsload(bytes32)` for off-chain reads; this
        // call must succeed (even for an empty slot) to prove the ABI matches.
        (bool ok, bytes memory ret) =
            address(poolManager).staticcall(abi.encodeWithSignature("extsload(bytes32)", bytes32(uint256(1))));
        assertTrue(ok, "extsload ABI mismatch");
        assertEq(ret.length, 32);
    }
}
