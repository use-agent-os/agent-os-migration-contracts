// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fee-on-transfer ERC20. Models CAP (Virtuals AgentToken) if its owner ever flags the
///         vault as a taxed pool: a share of every transfer is skimmed, the recipient gets less.
contract MockTaxERC20 is ERC20 {
    uint256 public taxBps;
    address public constant SINK = address(0xdead);

    constructor(string memory name_, string memory symbol_, uint256 taxBps_) ERC20(name_, symbol_) {
        taxBps = taxBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTax(uint256 bps) external {
        require(bps <= 10_000, "bps");
        taxBps = bps;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && taxBps > 0) {
            uint256 tax = (value * taxBps) / 10_000;
            if (tax > 0) {
                super._update(from, SINK, tax);
                super._update(from, to, value - tax);
                return;
            }
        }
        super._update(from, to, value);
    }
}
