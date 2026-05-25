// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IStakeManager} from "@account-abstraction/contracts/interfaces/IStakeManager.sol";

/// @notice Read-only view surface of the live PrediXPaymaster.
interface IPaymasterView {
    function isTargetAllowed(address target) external view returns (bool);
    function signer() external view returns (address);
    function paused() external view returns (bool);
    function owner() external view returns (address);
    function entryPoint() external view returns (address);
}

/// @title PaymasterVerify
/// @notice Standalone health check for the ERC-4337 PrediXPaymaster's *on-chain*
///         config — the layer `PostDeployVerify` does NOT cover (it audits the
///         Diamond/Hook/Exchange/Router stack but not the paymaster package).
///         The gap that motivated this script: the on-chain target allowlist
///         silently dropped `Exchange`, so gasless CLOB limit/cancel UserOps were
///         rejected at validation while market trades (via Router) kept working —
///         invisible to every automated check until a user hit a failed trade.
///
///         Reverts on the first discrepancy. Zero state changes — safe to run any
///         time as a periodic integrity monitor (CI / cron) right alongside
///         `PostDeployVerify`.
///
///         Required env: PAYMASTER_ADDRESS, ENTRY_POINT_V07, PAYMASTER_OWNER,
///         PAYMASTER_INITIAL_SIGNER, ROUTER_ADDRESS, DIAMOND_ADDRESS,
///         EXCHANGE_ADDRESS.
///         Optional: PAYMASTER_MIN_STAKE_WEI (default 1e15 = Pimlico floor),
///         PAYMASTER_MIN_DEPOSIT_WEI (default 1e15).
///
///         Usage:
///             forge script PaymasterVerify --rpc-url $UNICHAIN_RPC_PRIMARY
contract PaymasterVerify is Script {
    error PaymasterVerify_Failed(string what);

    function run() external view {
        address pm = vm.envAddress("PAYMASTER_ADDRESS");
        address ep = vm.envAddress("ENTRY_POINT_V07");
        address ownerAddr = vm.envAddress("PAYMASTER_OWNER");
        address signerAddr = vm.envAddress("PAYMASTER_INITIAL_SIGNER");
        address router = vm.envAddress("ROUTER_ADDRESS");
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address exchange = vm.envAddress("EXCHANGE_ADDRESS");
        // Pimlico (and most ERC-7562 bundlers) reject paymasters staked below
        // 1e15 wei; deposit must stay funded or every sponsored UserOp fails.
        uint256 minStake = vm.envOr("PAYMASTER_MIN_STAKE_WEI", uint256(1e15));
        uint256 minDeposit = vm.envOr("PAYMASTER_MIN_DEPOSIT_WEI", uint256(1e15));

        console2.log("PaymasterVerify: chainId   =", block.chainid);
        console2.log("PaymasterVerify: paymaster =", pm);

        IPaymasterView p = IPaymasterView(pm);

        // 1. EntryPoint binding matches the canonical v0.7 EntryPoint in env.
        if (p.entryPoint() != ep) revert PaymasterVerify_Failed("paymaster.entryPoint != ENTRY_POINT_V07");

        // 2. Owner + signer match intended (owner must be the multisig; signer
        //    is the address the BE sponsorship service signs UserOps with).
        if (p.owner() != ownerAddr) revert PaymasterVerify_Failed("paymaster.owner != PAYMASTER_OWNER");
        if (p.signer() != signerAddr) revert PaymasterVerify_Failed("paymaster.signer != PAYMASTER_INITIAL_SIGNER");

        // 3. Live (not paused) — a paused paymaster rejects every UserOp.
        if (p.paused()) revert PaymasterVerify_Failed("paymaster is PAUSED");

        // 4. Trade-path targets MUST all be sponsorable:
        //    Router = AMM market trades, Diamond = split/merge/redeem,
        //    Exchange = CLOB limit orders + cancels (the historically-missing one).
        if (!p.isTargetAllowed(router)) revert PaymasterVerify_Failed("Router not allowlisted");
        if (!p.isTargetAllowed(diamond)) revert PaymasterVerify_Failed("Diamond not allowlisted");
        if (!p.isTargetAllowed(exchange)) {
            revert PaymasterVerify_Failed("Exchange not allowlisted -> gasless CLOB limit/cancel broken");
        }

        // 5. Drain guard: critical infra must NEVER be allowlisted, else a
        //    compromised signer could sponsor UserOps that drain the deposit.
        if (p.isTargetAllowed(pm)) revert PaymasterVerify_Failed("paymaster self allowlisted (drain risk)");
        if (p.isTargetAllowed(ep)) revert PaymasterVerify_Failed("EntryPoint allowlisted (drain risk)");

        // 6. Staked (ERC-7562) above the bundler floor + deposit funded.
        IStakeManager.DepositInfo memory info = IEntryPoint(ep).getDepositInfo(pm);
        if (!info.staked) revert PaymasterVerify_Failed("paymaster NOT staked (bundlers reject every UserOp)");
        if (uint256(info.stake) < minStake) revert PaymasterVerify_Failed("paymaster stake below floor");
        if (info.deposit < minDeposit) revert PaymasterVerify_Failed("paymaster deposit below floor (gasless runs dry)");

        console2.log("PaymasterVerify: signer    =", signerAddr);
        console2.log("PaymasterVerify: deposit   =", info.deposit);
        console2.log("PaymasterVerify: stake     =", uint256(info.stake));
        console2.log("PaymasterVerify: allowlist = Router + Diamond + Exchange OK");
        console2.log("PaymasterVerify: OK");
    }
}
