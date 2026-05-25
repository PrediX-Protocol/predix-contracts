// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";

/// @title Shared helpers for indexer-audit scenario scripts (2026-05-23).
/// @notice Reads addresses + derives mnemonic-indexed signing keys for the
///         indexer audit run on Unichain mainnet (chainId 130).
///         HD index 8 is the paymaster signer — DO NOT reuse for tests.
///         Test wallets start at HD index 9.
abstract contract AuditBase is Script {
    struct Ctx {
        address diamond;
        address exchange;
        address router;
        address oracleManual;
        address usdc;
        uint256 deployerKey;
        uint256 creatorKey;
        uint256 reporterKey;
        uint256 lpKey;
        uint256 aKey;
        uint256 bKey;
        uint256 xKey;
        uint256 yKey;
        uint256 zKey;
    }

    function _load() internal returns (Ctx memory c) {
        c.diamond = vm.envAddress("DIAMOND_ADDRESS");
        c.exchange = vm.envAddress("EXCHANGE_ADDRESS");
        c.router = vm.envAddress("ROUTER_ADDRESS");
        c.oracleManual = vm.envAddress("ORACLE_MANUAL_ADDRESS");
        c.usdc = vm.envAddress("USDC_ADDRESS");

        string memory mnemonic = vm.envString("MNEMONIC");
        c.deployerKey = vm.deriveKey(mnemonic, 0);
        c.creatorKey = vm.deriveKey(mnemonic, 6);
        c.reporterKey = vm.deriveKey(mnemonic, 7);
        c.lpKey = vm.deriveKey(mnemonic, 9);
        c.aKey = vm.deriveKey(mnemonic, 10);
        c.bKey = vm.deriveKey(mnemonic, 11);
        c.xKey = vm.deriveKey(mnemonic, 12);
        c.yKey = vm.deriveKey(mnemonic, 13);
        c.zKey = vm.deriveKey(mnemonic, 14);
    }
}

/// @notice TestUSDC.mint (owner-only). Deployer is owner on Unichain mainnet.
interface ITestUSDCMint {
    function mint(address to, uint256 amount) external;
    function owner() external view returns (address);
}
