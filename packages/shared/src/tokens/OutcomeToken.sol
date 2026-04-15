// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

/// @title OutcomeToken
/// @notice ERC20 + EIP-2612 outcome leg (YES or NO) for a single PrediX market.
/// @dev Decimals are fixed at 6 to mirror USDC so the 1:1 split/merge accounting holds
///      without any scaling. Only the factory (the diamond proxy) may mint or burn.
contract OutcomeToken is ERC20, ERC20Permit, IOutcomeToken {
    address public immutable override factory;
    uint256 public immutable override marketId;
    bool public immutable override isYes;

    modifier onlyFactory() {
        if (msg.sender != factory) revert OutcomeToken_NotFactory();
        _;
    }

    constructor(address factory_, uint256 marketId_, bool isYes_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        factory = factory_;
        marketId = marketId_;
        isYes = isYes_;
    }

    function mint(address to, uint256 amount) external override onlyFactory {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external override onlyFactory {
        _burn(from, amount);
    }

    function nonces(address owner) public view override(ERC20Permit, IERC20Permit) returns (uint256) {
        return super.nonces(owner);
    }

    function decimals() public pure override(ERC20, IERC20Metadata) returns (uint8) {
        return 6;
    }
}
