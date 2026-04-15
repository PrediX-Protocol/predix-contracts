// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice Testnet-only collateral token with an open mint so developers can
///         fund an unlimited number of test accounts.
/// @dev Metadata matches mainnet USDC so downstream tooling (wallets, block
///      explorers, the PrediX frontend) renders the token identically to its
///      production counterpart. Do NOT deploy on mainnet.
contract TestUSDC is ERC20, ERC20Permit {
    constructor(address initialRecipient, uint256 initialSupply) ERC20("USD Coin", "USDC") ERC20Permit("USD Coin") {
        if (initialRecipient != address(0) && initialSupply > 0) {
            _mint(initialRecipient, initialSupply);
        }
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Open faucet — anyone can mint any amount to any address.
    ///         Testnet convenience only; the contract must never be deployed
    ///         on mainnet because of this.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title DeployTestUSDC
/// @notice Standalone script. Run once per testnet before `DeployAll`, then
///         paste the emitted address into `.env` as `USDC_ADDRESS`.
///
/// Usage:
///   forge script packages/shared/script/DeployTestUSDC.s.sol:DeployTestUSDC \
///       --rpc-url $UNICHAIN_RPC_PRIMARY --broadcast
contract DeployTestUSDC is Script {
    /// @notice Default initial mint: 1,000,000,000 USDC (raw value with 6
    ///         decimals) → 10^15 base units. Covers every realistic testnet
    ///         scenario without rolling over.
    uint256 internal constant DEFAULT_INITIAL_SUPPLY = 1_000_000_000 * 1e6;

    function run() external returns (TestUSDC usdc) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        uint256 initialSupply = vm.envOr("TEST_USDC_INITIAL_SUPPLY", DEFAULT_INITIAL_SUPPLY);

        vm.startBroadcast(deployerKey);
        usdc = new TestUSDC(deployer, initialSupply);
        vm.stopBroadcast();

        console2log(address(usdc), deployer, initialSupply);
    }

    function console2log(address usdc, address deployer, uint256 initialSupply) private pure {
        // `console2` omitted to keep the script dependency surface minimal.
        // Forge prints the returned `TestUSDC` so the user can grab it from
        // the `forge script` output (`Contract Deployed: 0x...`).
        usdc;
        deployer;
        initialSupply;
    }
}
