// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC20 with a transfer hook (ERC777-style). While armed, every transfer calls `target`
///         with `data` and bubbles up the revert. Used to prove the guards hold against a token
///         that tries to re-enter.
contract ReentrantERC20 is ERC20 {
    address public target;
    bytes public data;
    bool private _inHook;

    constructor() ERC20("Reentrant", "REENT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
    }

    function disarm() external {
        target = address(0);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (target != address(0) && !_inHook && from != address(0) && to != address(0)) {
            _inHook = true;
            (bool ok, bytes memory ret) = target.call(data);
            _inHook = false;
            if (!ok) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }
}
