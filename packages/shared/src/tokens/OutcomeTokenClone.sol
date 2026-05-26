// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

/// @title OutcomeTokenClone
/// @notice EIP-1167 clone-compatible OutcomeToken. Master impl deploys once;
///         every market spawns two minimal-proxy clones (~45 bytes each) instead
///         of full bytecode (~3.7KB), cutting per-market deploy gas by ~80%.
/// @dev    `factory` is set in the master constructor as `immutable`. Because EIP-1167
///         clones execute master code via `DELEGATECALL`, every clone reads the SAME
///         `factory` value from master bytecode — no per-clone storage needed.
///
///         `marketId` and `isYes` are written to storage on `initialize` (cannot be
///         immutable in a clone). Cost is ~2 SSTOREs (~40k gas) — still leaves
///         a net ~75-80% saving vs the old `new OutcomeToken(...)` path.
///
///         Storage layout & initializer semantics follow OpenZeppelin v5
///         Upgradeable conventions (`Initializable._initialized` flag) — same
///         pattern used in our exchange + hook proxies, so no novel surface.
contract OutcomeTokenClone is Initializable, ERC20Upgradeable, ERC20PermitUpgradeable, IOutcomeToken {
    /// @notice Address allowed to mint and burn (the diamond proxy).
    /// @dev    Lives in master bytecode → all clones inherit the same factory via
    ///         DELEGATECALL. No SLOAD per check.
    address public immutable override factory;

    /// @notice Market this token belongs to.
    /// @dev    Storage (clones cannot have per-instance immutables).
    uint256 public override marketId;

    /// @notice YES leg if true, NO leg if false.
    bool public override isYes;

    modifier onlyFactory() {
        if (msg.sender != factory) revert OutcomeToken_NotFactory();
        _;
    }

    /// @param factory_ Diamond proxy address. Master only; clones DELEGATECALL into master.
    constructor(address factory_) {
        factory = factory_;
        // Disable initialize() on the master itself; only clones may init.
        _disableInitializers();
    }

    /// @notice One-shot bootstrap for a clone. Called by the diamond immediately
    ///         after `Clones.clone(master)` in `LibMarket.create`.
    function initialize(uint256 marketId_, bool isYes_, string memory name_, string memory symbol_)
        external
        initializer
    {
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        marketId = marketId_;
        isYes = isYes_;
    }

    function mint(address to, uint256 amount) external override onlyFactory {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external override onlyFactory {
        _burn(from, amount);
    }

    function nonces(address owner)
        public
        view
        override(ERC20PermitUpgradeable, IERC20Permit)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    function decimals() public pure override(ERC20Upgradeable, IERC20Metadata) returns (uint8) {
        return 6;
    }
}
