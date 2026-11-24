// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MigrationVault} from "@migration/MigrationVault.sol";
import {IMigrationVault} from "@migration/interfaces/IMigrationVault.sol";

import {MockERC20} from "./MockERC20.sol";

abstract contract VaultFixture is Test {
    // Mirrors the plan: 1 month window, rates final 15 days before close, 24h release delay.
    uint64 internal constant T0 = 1_795_000_000; // 2026-11-18, before the window
    uint64 internal constant START = 1_795_564_800; // 2026-11-25 00:00:00 UTC
    uint64 internal constant DEADLINE = 1_798_243_199; // 2026-12-25 23:59:59 UTC
    uint64 internal constant MAX_DEADLINE = 1_801_439_999; // 2027-01-31 23:59:59 UTC
    uint64 internal constant RATE_NOTICE = 15 days;
    uint64 internal constant RATE_CUTOFF = DEADLINE - RATE_NOTICE; // 2026-12-10 23:59:59 UTC
    uint256 internal constant DEPOSIT_CAP = 4_200_000_000e18; // AGENTOS the deposit path may reach
    uint64 internal constant RELEASE_DELAY = 1 days;
    uint64 internal constant GRACE = 14 days;

    uint256 internal constant CAP_RATE = 25.5e18;
    uint256 internal constant DACKIE_RATE = 18.5e18;
    bytes32 internal constant ROOT = keccak256("claim root");
    uint256 internal constant ATTESTED_TOTAL = 4_000_000_000e18;
    address internal constant ATTESTED_DISTRIBUTOR = address(0xD157);

    address internal safe = makeAddr("safe");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal leaked = makeAddr("leaked");
    address internal stranger = makeAddr("stranger");

    MockERC20 internal cap;
    MockERC20 internal dackie;
    MigrationVault internal vault;

    function _params() internal view returns (IMigrationVault.InitParams memory) {
        return IMigrationVault.InitParams({
            owner: safe,
            guardian: guardian,
            cap: IERC20(address(cap)),
            dackie: IERC20(address(dackie)),
            depositStart: START,
            depositDeadline: DEADLINE,
            maxDepositDeadline: MAX_DEADLINE,
            minRateNotice: RATE_NOTICE,
            releaseDelay: RELEASE_DELAY,
            settlementGrace: GRACE,
            maxDepositAllocation: _depositCap()
        });
    }

    function _depositCap() internal view virtual returns (uint256) {
        return DEPOSIT_CAP;
    }

    function _deployVault() internal {
        vm.warp(T0);
        cap = new MockERC20("Capminal", "CAP");
        dackie = new MockERC20("Dackie", "DACKIE");
        vault = new MigrationVault(_params());
    }

    function _fund(address user, uint256 capAmount, uint256 dackieAmount) internal {
        cap.mint(user, capAmount);
        dackie.mint(user, dackieAmount);
        vm.startPrank(user);
        cap.approve(address(vault), type(uint256).max);
        dackie.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _deposit(address user, MockERC20 token, uint256 amount) internal {
        vm.prank(user);
        vault.deposit(IERC20(address(token)), amount, user);
    }

    function _setRates() internal {
        vm.prank(safe);
        vault.setRates(CAP_RATE, DACKIE_RATE);
    }

    /// @dev Rates set in time, window closed, root attested, delay elapsed.
    function _toReleasable() internal {
        if (!vault.ratesSet()) _setRates();
        vm.warp(vault.depositDeadline() + 1);
        vm.prank(safe);
        vault.attestClaimRoot(ROOT, ATTESTED_TOTAL, ATTESTED_DISTRIBUTOR);
        vm.warp(block.timestamp + RELEASE_DELAY);
    }
}
