// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MigrationVault} from "@migration/MigrationVault.sol";
import {IMigrationVault} from "@migration/interfaces/IMigrationVault.sol";
import {MerkleVestingDistributor} from "@migration/MerkleVestingDistributor.sol";
import {IMerkleVestingDistributor} from "@migration/interfaces/IMerkleVestingDistributor.sol";

import {MockERC20} from "./helpers/MockERC20.sol";
import {MerkleHelper} from "./helpers/MerkleHelper.sol";

/// @notice The whole plan end to end, on the plan's real dates. Both chains are simulated in one
///         EVM: the "bridge" is the test reading the vault ledger and building the tree, exactly
///         what the team does off-chain.
contract MigrationFlowTest is Test {
    uint64 internal constant DEPLOY = 1_795_000_000; // ~2026-11-18
    uint64 internal constant START = 1_795_564_800; // 2026-11-25 00:00:00
    uint64 internal constant RATE_CUTOFF = 1_796_947_199; // 2026-12-10 23:59:59, last rate correction
    uint64 internal constant DEADLINE = 1_798_243_199; // 2026-12-25 23:59:59
    uint64 internal constant ROOT_DAY = 1_798_416_000; // 2026-12-28 00:00:00
    uint64 internal constant SALE_DAY = 1_798_502_400; // 2026-12-29 00:00:00
    uint64 internal constant CLAIM_START = 1_798_675_200; // 2026-12-31 00:00:00
    uint64 internal constant VESTING_END = 1_803_859_200; // 2027-03-01 00:00:00
    uint64 internal constant CLAIM_DEADLINE = 1_806_451_200; // 2027-03-31 00:00:00, last second to claim

    uint256 internal constant CAP_RATE = 25.5e18;
    uint256 internal constant DACKIE_RATE = 18.5e18;
    uint256 internal constant BUDGET = 5_000_000_000e18;

    address internal safe = makeAddr("safe");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice"); // CAP holder, EOA
    address internal bob = makeAddr("bob"); // DACKIE holder who changes their mind
    address internal multisig = makeAddr("holder multisig"); // contract wallet on Base
    address internal multisigOnRobinhood = makeAddr("holder multisig on robinhood");
    address internal team = makeAddr("team"); // deposits and is sold, never claims
    address internal locker = makeAddr("long locker"); // never deposits
    address internal ghost = makeAddr("ghost"); // deposits, then never claims
    uint256 internal lockedDackie = 1_000_000e18;

    MockERC20 internal cap;
    MockERC20 internal dackie;
    MockERC20 internal agentos;
    MigrationVault internal vault;
    MerkleVestingDistributor internal distributor;

    bytes32[] internal leaves;

    function setUp() public {
        vm.warp(DEPLOY);
        cap = new MockERC20("Capminal", "CAP");
        dackie = new MockERC20("Dackie", "DACKIE");
        agentos = new MockERC20("AgentOS", "AGENTOS");

        vault = new MigrationVault(
            IMigrationVault.InitParams({
                owner: safe,
                guardian: address(0),
                cap: IERC20(address(cap)),
                dackie: IERC20(address(dackie)),
                depositStart: START,
                depositDeadline: DEADLINE,
                maxDepositDeadline: 1_801_439_999,
                minRateNotice: 15 days,
                releaseDelay: 1 days,
                settlementGrace: 14 days,
                maxDepositAllocation: 4_200_000_000e18
            })
        );
        distributor = new MerkleVestingDistributor(safe, IERC20(address(agentos)), BUDGET);
        // "Funded with the full 5B before the window opens."
        agentos.mint(address(distributor), BUDGET);

        cap.mint(alice, 10_000e18);
        dackie.mint(bob, 5_000e18);
        cap.mint(multisig, 40_000e18);
        cap.mint(team, 28_260_000e18);
        cap.mint(ghost, 2_000e18);
        address[5] memory users = [alice, bob, multisig, team, ghost];
        for (uint256 i; i < users.length; ++i) {
            vm.startPrank(users[i]);
            cap.approve(address(vault), type(uint256).max);
            dackie.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    function test_fullMigration() public {
        // ---- 11-25: Post #1, rates set on-chain as the window opens ----
        vm.warp(START);
        vm.prank(safe);
        vault.setRates(CAP_RATE, DACKIE_RATE);

        // ---- 11-25 → 12-25: deposits, knowing the rate ----
        vm.prank(alice);
        vault.deposit(IERC20(address(cap)), 10_000e18, alice);
        vm.prank(bob);
        vault.deposit(IERC20(address(dackie)), 5_000e18, bob);
        vm.prank(multisig);
        vault.deposit(IERC20(address(cap)), 40_000e18, multisigOnRobinhood);
        vm.prank(team);
        vault.deposit(IERC20(address(cap)), 28_260_000e18, team);
        vm.prank(ghost);
        vault.deposit(IERC20(address(cap)), 2_000e18, ghost);
        // A long-locker that is a contract registers where to receive, without depositing.
        vm.prank(locker);
        vault.registerRecipient(locker);

        // ---- 12-10 23:59:59: last second a rate correction is accepted, then the rates are fixed ----
        vm.warp(RATE_CUTOFF + 1);
        vm.prank(safe);
        vm.expectRevert(IMigrationVault.RatesFinal.selector);
        vault.setRates(1e18, 1e18);
        assertEq(vault.capRate(), CAP_RATE);

        // Bob disagrees with the rate and leaves, 15 days of notice were enough.
        vm.warp(DEADLINE - 1 days);
        vm.prank(bob);
        vault.withdraw(IERC20(address(dackie)), 5_000e18);
        assertEq(dackie.balanceOf(bob), 5_000e18);

        // ---- 12-25 23:59:59: window closes, ledger frozen ----
        vm.warp(DEADLINE + 1);
        vm.prank(alice);
        vm.expectRevert(IMigrationVault.WithdrawalsClosed.selector);
        vault.withdraw(IERC20(address(cap)), 1);

        // ---- 12-26 → 12-28: build the tree from the frozen ledger ----
        // deposits × rate, sent to the registered recipient. Team is excluded. The long-lock leaf
        // vests from claim open like every other leaf (decision #2).
        uint256 aliceAlloc = vault.allocationOf(alice);
        uint256 multisigAlloc = vault.allocationOf(multisig);
        uint256 ghostAlloc = vault.allocationOf(ghost);
        uint256 lockerAlloc = (lockedDackie * DACKIE_RATE) / 1e18;
        assertEq(aliceAlloc, 255_000e18);
        assertEq(vault.allocationOf(bob), 0);

        leaves.push(distributor.leafOf(vault.effectiveRecipient(alice), aliceAlloc));
        leaves.push(distributor.leafOf(vault.effectiveRecipient(multisig), multisigAlloc));
        leaves.push(distributor.leafOf(vault.effectiveRecipient(locker), lockerAlloc));
        leaves.push(distributor.leafOf(vault.effectiveRecipient(ghost), ghostAlloc));
        bytes32 root = MerkleHelper.root(leaves);
        uint256 total = aliceAlloc + multisigAlloc + lockerAlloc + ghostAlloc;

        // ---- 12-28: commit + lock the root on Robinhood, attest it on Base ----
        vm.warp(ROOT_DAY);
        vm.startPrank(safe);
        distributor.commitRoot(root, total, CLAIM_START, alice, aliceAlloc, MerkleHelper.proof(leaves, 0));
        vault.attestClaimRoot(root, total, address(distributor));
        // Nothing can leave the vault yet.
        vm.expectRevert(abi.encodeWithSelector(IMigrationVault.ReleaseDelayNotElapsed.selector, ROOT_DAY + 1 days));
        vault.release();
        // Unused budget goes back to treasury right away, the committed part cannot.
        assertEq(distributor.sweepExcess(treasury), BUDGET - total);
        vm.stopPrank();
        // What anyone checks during the release delay.
        assertEq(vault.claimRoot(), distributor.merkleRoot(), "same root on both chains");
        assertEq(vault.attestedTotalAllocation(), distributor.totalAllocation(), "same total on both chains");
        assertEq(vault.attestedDistributor(), address(distributor), "points at the real distributor");
        assertGe(agentos.balanceOf(address(distributor)), distributor.outstanding(), "distributor funded");

        // ---- 12-29: sale day. Tokens leave the vault only now ----
        vm.warp(SALE_DAY);
        vm.prank(safe);
        vault.release();
        assertEq(cap.balanceOf(safe), 10_000e18 + 40_000e18 + 28_260_000e18 + 2_000e18);
        assertEq(dackie.balanceOf(safe), 0);

        // ---- before 12-31: no claim yet ----
        vm.warp(CLAIM_START - 1);
        vm.expectRevert();
        distributor.claim(alice, aliceAlloc, MerkleHelper.proof(leaves, 0));

        // ---- 12-31: claims open, 20% ----
        vm.warp(CLAIM_START);
        distributor.claim(alice, aliceAlloc, MerkleHelper.proof(leaves, 0));
        assertEq(agentos.balanceOf(alice), aliceAlloc / 5);
        // The contract wallet's share lands on the address it registered on Base.
        distributor.claim(multisigOnRobinhood, multisigAlloc, MerkleHelper.proof(leaves, 1));
        assertEq(agentos.balanceOf(multisigOnRobinhood), multisigAlloc / 5);
        assertEq(agentos.balanceOf(multisig), 0);

        // ---- 2027-03-01: vesting ends for everyone ----
        vm.warp(VESTING_END);
        distributor.claim(alice, aliceAlloc, MerkleHelper.proof(leaves, 0));
        distributor.claim(multisigOnRobinhood, multisigAlloc, MerkleHelper.proof(leaves, 1));
        assertEq(agentos.balanceOf(alice), aliceAlloc);
        assertEq(agentos.balanceOf(multisigOnRobinhood), multisigAlloc);

        // ---- long-locker: same round, same schedule. Claims late, on the last second ----
        vm.warp(CLAIM_DEADLINE);
        vm.prank(safe);
        vm.expectRevert(IMerkleVestingDistributor.NothingToSweep.selector);
        distributor.sweepExcess(treasury); // unclaimed AGENTOS is still out of the owner's reach
        distributor.claim(locker, lockerAlloc, MerkleHelper.proof(leaves, 2));
        assertEq(agentos.balanceOf(locker), lockerAlloc);

        // ---- 2027-03-31 00:00:01: claims are closed, what nobody claimed returns to treasury ----
        vm.warp(CLAIM_DEADLINE + 1);
        vm.expectRevert(abi.encodeWithSelector(IMerkleVestingDistributor.ClaimsExpired.selector, CLAIM_DEADLINE));
        distributor.claim(ghost, ghostAlloc, MerkleHelper.proof(leaves, 3));
        vm.prank(safe);
        assertEq(distributor.sweepExcess(treasury), ghostAlloc);

        // ---- final accounting ----
        assertEq(agentos.balanceOf(address(distributor)), 0);
        assertEq(agentos.balanceOf(ghost), 0);
        assertEq(agentos.balanceOf(treasury), BUDGET - total + ghostAlloc);
        assertEq(agentos.balanceOf(team), 0, "team CAP was sold, its AGENTOS never claimed");
    }

    /// @dev The Safe disappears after the window closes: every depositor gets their tokens back.
    function test_safeGoesSilent_everyoneIsRefunded() public {
        vm.warp(START);
        vm.prank(alice);
        vault.deposit(IERC20(address(cap)), 10_000e18, alice);
        vm.prank(bob);
        vault.deposit(IERC20(address(dackie)), 5_000e18, bob);

        vm.warp(DEADLINE + 14 days + 1);
        vault.refund(alice);
        vault.refund(bob);
        assertEq(cap.balanceOf(alice), 10_000e18);
        assertEq(dackie.balanceOf(bob), 5_000e18);
    }
}
