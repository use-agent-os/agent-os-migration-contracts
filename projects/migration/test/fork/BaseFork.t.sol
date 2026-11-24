// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MigrationVault} from "@migration/MigrationVault.sol";
import {IMigrationVault} from "@migration/interfaces/IMigrationVault.sol";

interface ICapAgentToken {
    function owner() external view returns (address);
    function addLiquidityPool(address pool) external;
    function isLiquidityPool(address account) external view returns (bool);
}

/// @notice Rehearsal against the real CAP (Virtuals AgentToken) and DACKIE on Base.
/// @dev    Skipped unless BASE_RPC_URL is set:
///         BASE_RPC_URL=https://mainnet.base.org forge test --match-path 'test/fork/*' -vv
contract BaseForkTest is Test {
    IERC20 internal constant CAP = IERC20(0xbfa733702305280F066D470afDFA784fA70e2649);
    IERC20 internal constant DACKIE = IERC20(0x73326b4d0225c429bed050c11C4422d91470AaF4);

    address internal safe = makeAddr("safe");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    MigrationVault internal vault;
    uint64 internal start;
    uint64 internal deadline;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("BASE_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);

        start = uint64(block.timestamp) + 1 days;
        deadline = start + 31 days;
        vault = new MigrationVault(
            IMigrationVault.InitParams({
                owner: safe,
                guardian: address(0),
                cap: CAP,
                dackie: DACKIE,
                depositStart: start,
                depositDeadline: deadline,
                maxDepositDeadline: deadline + 30 days,
                minRateNotice: 15 days,
                releaseDelay: 1 days,
                settlementGrace: 14 days,
                maxDepositAllocation: 4_200_000_000e18
            })
        );

        deal(address(CAP), alice, 1_000_000e18);
        deal(address(DACKIE), alice, 500_000e18);
        deal(address(CAP), bob, 250_000e18);
        vm.startPrank(alice);
        CAP.approve(address(vault), type(uint256).max);
        DACKIE.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.prank(bob);
        CAP.approve(address(vault), type(uint256).max);
    }

    /// @dev A deposit / withdrawal of real CAP and DACKIE is not taxed: the vault is not a pool.
    function test_fork_depositAndWithdrawAreExact() public {
        vm.warp(start);
        vm.startPrank(alice);
        assertEq(vault.deposit(CAP, 1_000_000e18, alice), 1_000_000e18, "CAP credited in full");
        assertEq(vault.deposit(DACKIE, 500_000e18, alice), 500_000e18, "DACKIE credited in full");
        assertEq(CAP.balanceOf(address(vault)), 1_000_000e18);
        assertEq(DACKIE.balanceOf(address(vault)), 500_000e18);

        vault.withdraw(CAP, 1_000_000e18);
        vault.withdraw(DACKIE, 500_000e18);
        vm.stopPrank();
        assertEq(CAP.balanceOf(alice), 1_000_000e18, "CAP returned in full");
        assertEq(DACKIE.balanceOf(alice), 500_000e18, "DACKIE returned in full");
        assertEq(CAP.balanceOf(address(vault)), 0);
    }

    function test_fork_releaseSendsExactTotalsToSafe() public {
        vm.warp(start);
        vm.startPrank(alice);
        vault.deposit(CAP, 1_000_000e18, alice);
        vault.deposit(DACKIE, 500_000e18, alice);
        vm.stopPrank();
        vm.prank(bob);
        vault.deposit(CAP, 250_000e18, bob);

        uint256 safeCapBefore = CAP.balanceOf(safe);
        vm.startPrank(safe);
        vault.setRates(25.5e18, 18.5e18);
        vm.warp(deadline + 1);
        vault.attestClaimRoot(keccak256("root"), 1e18, address(0xD157));
        vm.warp(block.timestamp + 1 days);
        vault.release();
        vm.stopPrank();

        assertEq(CAP.balanceOf(safe) - safeCapBefore, 1_250_000e18, "CAP to the Safe, untaxed");
        assertEq(DACKIE.balanceOf(safe), 500_000e18, "DACKIE to the Safe");
        assertEq(CAP.balanceOf(address(vault)), 0);
        assertEq(DACKIE.balanceOf(address(vault)), 0);
    }

    /// @dev CAP's owner (a third party) can flag any address as a taxed pool. If it flags the
    ///      vault, deposits and exits are taxed 1%, but the ledger still matches the balance and
    ///      every exit path keeps working.
    function test_fork_capOwnerFlagsVaultAsPool_vaultStaysSolvent() public {
        vm.warp(start);
        vm.prank(alice);
        vault.deposit(CAP, 500_000e18, alice); // untaxed, before the flag

        address capOwner = ICapAgentToken(address(CAP)).owner();
        vm.prank(capOwner);
        ICapAgentToken(address(CAP)).addLiquidityPool(address(vault));
        assertTrue(ICapAgentToken(address(CAP)).isLiquidityPool(address(vault)), "vault flagged");

        // Taxed deposit: credited with what arrived.
        vm.prank(bob);
        uint256 received = vault.deposit(CAP, 250_000e18, bob);
        assertLt(received, 250_000e18, "deposit taxed");
        assertEq(vault.depositOf(CAP, bob), received);
        assertGe(CAP.balanceOf(address(vault)), vault.totalDeposited(CAP), "solvent");

        // Exits still work for everyone (the user pays the tax on the way out).
        vm.prank(bob);
        vault.withdraw(CAP, received);
        vm.prank(safe);
        vault.cancel();
        vault.refund(alice);
        assertEq(vault.totalDeposited(CAP), 0);
        assertGe(CAP.balanceOf(alice), 995_000e18 - 1e18, "alice lost at most the 1% exit tax");
    }

    function test_fork_timeoutRefund() public {
        vm.warp(start);
        vm.prank(alice);
        vault.deposit(CAP, 1_000_000e18, alice);
        vm.prank(bob);
        vault.deposit(CAP, 250_000e18, bob);

        vm.warp(deadline + 14 days + 1);
        vault.refund(alice);
        vault.refund(bob);
        assertEq(CAP.balanceOf(alice), 1_000_000e18);
        assertEq(CAP.balanceOf(bob), 250_000e18);
    }
}
