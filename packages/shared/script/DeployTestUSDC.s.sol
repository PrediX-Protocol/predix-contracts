// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Walled-garden USDC for testnet. Only owner can mint. Transfers
///         restricted: at least one side (sender or receiver) must be a
///         whitelisted protocol contract. User-to-user transfers are blocked.
/// @dev Metadata matches mainnet USDC. Do NOT deploy on mainnet.
contract TestUSDC is ERC20, ERC20Permit, Ownable {
    mapping(address => bool) public whitelisted;

    error TransferRestricted();

    event WhitelistUpdated(address indexed account, bool status);

    constructor(address initialRecipient, uint256 initialSupply)
        ERC20("USD Coin", "USDC")
        ERC20Permit("USD Coin")
        Ownable(initialRecipient)
    {
        if (initialRecipient != address(0) && initialSupply > 0) {
            _mint(initialRecipient, initialSupply);
        }
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Only owner can mint.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Add or remove a protocol contract from the whitelist.
    function setWhitelist(address account, bool status) external onlyOwner {
        whitelisted[account] = status;
        emit WhitelistUpdated(account, status);
    }

    /// @notice Batch whitelist multiple addresses.
    function setWhitelistBatch(address[] calldata accounts, bool status) external onlyOwner {
        for (uint256 i; i < accounts.length; ++i) {
            whitelisted[accounts[i]] = status;
            emit WhitelistUpdated(accounts[i], status);
        }
    }

    /// @dev Override OZ v5 _update hook. Enforces: for non-mint/burn transfers,
    ///      at least one of (from, to) must be whitelisted. Owner is always allowed.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            if (!whitelisted[from] && !whitelisted[to] && from != owner() && to != owner()) {
                revert TransferRestricted();
            }
        }
        super._update(from, to, value);
    }
}

/// @title DeployTestUSDC
/// @notice Standalone script. Run once per testnet before `DeployAll`, then
///         paste the emitted address into `.env` as `USDC_ADDRESS`.
///
/// Usage:
///   forge script packages/shared/script/DeployTestUSDC.s.sol:DeployTestUSDC \
///       --rpc-url $UNICHAIN_RPC_PRIMARY --broadcast
/// @title DeployTestUSDC
/// @notice Deploy walled-garden TestUSDC + whitelist protocol contracts.
///
/// Usage:
///   forge script packages/shared/script/DeployTestUSDC.s.sol:DeployTestUSDC \
///       --rpc-url $UNICHAIN_RPC_PRIMARY --broadcast
///
/// After deploy, call setWhitelistBatch with protocol addresses:
///   Diamond, Exchange, Router, Hook, Faucet, MarketFactory, PoolModifyLiquidityTest
contract DeployTestUSDC is Script {
    uint256 internal constant DEFAULT_INITIAL_SUPPLY = 1_000_000_000 * 1e6;

    function run() external returns (TestUSDC usdc) {
        uint256 deployerKey;
        string memory mnemonic = vm.envOr("MNEMONIC", string(""));
        if (bytes(mnemonic).length > 0) {
            deployerKey = vm.deriveKey(mnemonic, 0);
        } else {
            deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        }
        address deployer = vm.addr(deployerKey);

        uint256 initialSupply = vm.envOr("TEST_USDC_INITIAL_SUPPLY", DEFAULT_INITIAL_SUPPLY);

        vm.startBroadcast(deployerKey);
        usdc = new TestUSDC(deployer, initialSupply);
        vm.stopBroadcast();
    }
}
