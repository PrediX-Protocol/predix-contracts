// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @dev Minimal Permit2 stub. Records every permit + transferFrom call. Allows tests to
///      simulate invalid signature / token mismatch / expired permit by flipping flags.
contract MockPermit2 {
    struct PermitCall {
        address owner;
        address token;
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    PermitCall[] public permits;
    bool public revertOnPermit;
    bool public revertOnTransfer;

    function setRevertOnPermit(bool v) external {
        revertOnPermit = v;
    }

    function setRevertOnTransfer(bool v) external {
        revertOnTransfer = v;
    }

    function permitCount() external view returns (uint256) {
        return permits.length;
    }

    function permit(address owner, IAllowanceTransfer.PermitSingle memory p, bytes calldata) external {
        require(!revertOnPermit, "MockPermit2: invalid signature");
        require(block.timestamp <= p.sigDeadline, "MockPermit2: permit expired");
        permits.push(
            PermitCall({
                owner: owner,
                token: p.details.token,
                amount: p.details.amount,
                expiration: p.details.expiration,
                nonce: p.details.nonce
            })
        );
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        require(!revertOnTransfer, "MockPermit2: transferFrom denied");
        IERC20(token).transferFrom(from, to, amount);
    }
}
