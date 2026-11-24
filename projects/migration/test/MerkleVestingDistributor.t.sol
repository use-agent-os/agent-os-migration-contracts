// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {MerkleVestingDistributor} from "@migration/MerkleVestingDistributor.sol";
import {IMerkleVestingDistributor} from "@migration/interfaces/IMerkleVestingDistributor.sol";

import {DistributorFixture} from "./helpers/DistributorFixture.sol";
import {MerkleHelper} from "./helpers/MerkleHelper.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {ReentrantERC20} from "./helpers/ReentrantERC20.sol";

contract MerkleVestingDistributorTest is DistributorFixture {
    uint256 internal constant ALICE_ALLOC = 25_500e18;
    uint256 internal constant BOB_ALLOC = 1_000_000e18;
    uint256 internal constant LOCKER_ALLOC = 18_500e18;
    uint256 internal constant DAVE_ALLOC = 7e18;

    uint256 internal constant ALICE = 0;
    uint256 internal constant BOB = 1;
    uint256 internal constant LOCKER = 2;
    uint256 internal constant DAVE = 3;

    function setUp() public {
        _deployDistributor();
        // Every leaf vests from claim open, long-lockers included (plan decision #2).
        _addEntry(alice, ALICE_ALLOC);
        _addEntry(bob, BOB_ALLOC);
        _addEntry(locker, LOCKER_ALLOC);
        _addEntry(makeAddr("dave"), DAVE_ALLOC);
        agentos.mint(address(distributor), BUDGET);
    }

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    function test_constructor() public {
        assertEq(distributor.owner(), safe);
        assertEq(address(distributor.TOKEN()), address(agentos));
        assertEq(distributor.MAX_TOTAL_ALLOCATION(), BUDGET);
        assertEq(distributor.INITIAL_UNLOCK_BPS(), 2_000);
        assertEq(distributor.VESTING_DURATION(), 60 days);
        assertEq(distributor.CLAIM_GRACE(), 30 days);
        assertEq(distributor.claimDeadline(), 0); // no root yet

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new MerkleVestingDistributor(address(0), IERC20(address(agentos)), BUDGET);
        vm.expectRevert(IMerkleVestingDistributor.ZeroAddress.selector);
        new MerkleVestingDistributor(safe, IERC20(address(0)), BUDGET);
        vm.expectRevert(IMerkleVestingDistributor.InvalidConfig.selector);
        new MerkleVestingDistributor(safe, IERC20(makeAddr("eoa")), BUDGET);
        vm.expectRevert(IMerkleVestingDistributor.InvalidConfig.selector);
        new MerkleVestingDistributor(safe, IERC20(address(agentos)), 0);
    }

    // ------------------------------------------------------------------
    // commitRoot
    // ------------------------------------------------------------------

    function test_commitRoot_setsStateOnce() public {
        bytes32 root = _root();
        vm.expectEmit(true, true, true, true);
        emit IMerkleVestingDistributor.RootCommitted(root, treeTotal, CLAIM_START, T0 + 30 days);
        _commit();

        assertEq(distributor.merkleRoot(), root);
        assertEq(distributor.totalAllocation(), treeTotal);
        assertEq(distributor.claimStart(), CLAIM_START);
        assertEq(distributor.latestClaimStart(), T0 + 30 days);
        assertEq(distributor.claimDeadline(), CLAIM_DEADLINE);
        assertEq(distributor.outstanding(), treeTotal);

        // Locked: nobody can change it, the owner included.
        vm.expectRevert(IMerkleVestingDistributor.RootAlreadyCommitted.selector);
        _commitWith(distributor, keccak256("another root"), ALICE_ALLOC, CLAIM_START);
    }

    function test_commitRoot_onlyOwner() public {
        bytes32 root = _root();
        bytes32[] memory proof = _proof(ALICE);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        distributor.commitRoot(root, treeTotal, CLAIM_START, alice, ALICE_ALLOC, proof);
    }

    function test_commitRoot_revertsOnBadInput() public {
        bytes32 root = _root();

        vm.expectRevert(IMerkleVestingDistributor.InvalidRoot.selector);
        _commitWith(distributor, bytes32(0), treeTotal, CLAIM_START);

        vm.expectRevert(IMerkleVestingDistributor.InvalidAllocation.selector);
        _commitWith(distributor, root, 0, CLAIM_START);

        // Budget ceiling: never more than 5B.
        vm.expectRevert(IMerkleVestingDistributor.InvalidAllocation.selector);
        _commitWith(distributor, root, BUDGET + 1, CLAIM_START);

        vm.expectRevert(IMerkleVestingDistributor.InvalidClaimStart.selector);
        _commitWith(distributor, root, treeTotal, T0); // not in the future

        vm.expectRevert(IMerkleVestingDistributor.InvalidClaimStart.selector);
        _commitWith(distributor, root, treeTotal, T0 + 30 days + 1); // too far (unit mistake guard)
    }

    /// @dev The sample leaf proves the tree can actually be claimed from here.
    function test_commitRoot_revertsOnBadSampleLeaf() public {
        bytes32 root = _root();
        bytes32[] memory proof = _proof(ALICE);
        vm.startPrank(safe);

        // A root nobody can prove a leaf of (wrong tree, garbage, typo).
        vm.expectRevert(IMerkleVestingDistributor.InvalidSampleLeaf.selector);
        distributor.commitRoot(keccak256("garbage"), treeTotal, CLAIM_START, alice, ALICE_ALLOC, proof);
        // Sample that is not in the tree.
        vm.expectRevert(IMerkleVestingDistributor.InvalidSampleLeaf.selector);
        distributor.commitRoot(root, treeTotal, CLAIM_START, alice, ALICE_ALLOC + 1, proof);
        vm.expectRevert(IMerkleVestingDistributor.InvalidSampleLeaf.selector);
        distributor.commitRoot(root, treeTotal, CLAIM_START, address(0), ALICE_ALLOC, proof);
        vm.expectRevert(IMerkleVestingDistributor.InvalidSampleLeaf.selector);
        distributor.commitRoot(root, treeTotal, CLAIM_START, alice, 0, proof);
        // A stated total smaller than a single leaf cannot be right.
        vm.expectRevert(IMerkleVestingDistributor.InvalidSampleLeaf.selector);
        distributor.commitRoot(root, ALICE_ALLOC - 1, CLAIM_START, alice, ALICE_ALLOC, proof);

        vm.stopPrank();
        assertEq(distributor.merkleRoot(), bytes32(0));
    }

    /// @dev A tree built for another chain id is rejected at commit instead of locking 5B.
    function test_commitRoot_rejectsTreeBuiltForAnotherChain() public {
        bytes32 root = _root(); // leaves were hashed with chain id 31337
        bytes32[] memory proof = _proof(ALICE);
        vm.chainId(4663);
        vm.prank(safe);
        vm.expectRevert(IMerkleVestingDistributor.InvalidSampleLeaf.selector);
        distributor.commitRoot(root, treeTotal, CLAIM_START, alice, ALICE_ALLOC, proof);
    }

    function test_commitRoot_revertsWhenUnderfunded() public {
        MerkleVestingDistributor d = new MerkleVestingDistributor(safe, IERC20(address(agentos)), BUDGET);
        agentos.mint(address(d), 1_000e18 - 1);
        vm.expectRevert(abi.encodeWithSelector(IMerkleVestingDistributor.Underfunded.selector, 1_000e18, 1_000e18 - 1));
        _commitWith(d, keccak256("root"), 1_000e18, CLAIM_START);
    }

    // ------------------------------------------------------------------
    // claim
    // ------------------------------------------------------------------

    function test_claim_revertsBeforeRootAndBeforeStart() public {
        vm.expectRevert(IMerkleVestingDistributor.RootNotCommitted.selector);
        _claim(ALICE);

        _commit();
        vm.warp(CLAIM_START - 1);
        vm.expectRevert(abi.encodeWithSelector(IMerkleVestingDistributor.ClaimsNotOpen.selector, CLAIM_START));
        _claim(ALICE);
    }

    function test_claim_twentyPercentAtOpen() public {
        _commit();
        vm.warp(CLAIM_START);

        bytes32 leaf = distributor.leafOf(alice, ALICE_ALLOC);
        vm.expectEmit(true, true, true, true);
        emit IMerkleVestingDistributor.Claimed(leaf, alice, ALICE_ALLOC / 5, ALICE_ALLOC / 5, alice);
        vm.prank(alice);
        uint256 paid = _claim(ALICE);

        assertEq(paid, ALICE_ALLOC / 5);
        assertEq(agentos.balanceOf(alice), ALICE_ALLOC / 5);
        assertEq(distributor.claimedOf(leaf), ALICE_ALLOC / 5);
        assertEq(distributor.totalClaimed(), ALICE_ALLOC / 5);

        // Nothing more in the same second.
        vm.expectRevert(IMerkleVestingDistributor.NothingToClaim.selector);
        _claim(ALICE);
    }

    function test_claim_linearThenFull() public {
        _commit();

        vm.warp(CLAIM_START + 15 days); // 20% + 80% * 1/4 = 40%
        assertEq(_claim(BOB), (BOB_ALLOC * 40) / 100);

        vm.warp(CLAIM_START + 30 days); // 60% total
        assertEq(_claim(BOB), (BOB_ALLOC * 20) / 100);

        vm.warp(CLAIM_START + 60 days); // 100%
        assertEq(_claim(BOB), (BOB_ALLOC * 40) / 100);
        assertEq(agentos.balanceOf(bob), BOB_ALLOC);

        vm.warp(CLAIM_DEADLINE);
        vm.expectRevert(IMerkleVestingDistributor.NothingToClaim.selector);
        _claim(BOB);
        assertEq(agentos.balanceOf(bob), BOB_ALLOC);
    }

    function test_claim_singleClaimAfterVestingPaysEverything() public {
        _commit();
        vm.warp(CLAIM_START + VESTING + 1);
        assertEq(_claim(ALICE), ALICE_ALLOC);
        assertEq(agentos.balanceOf(alice), ALICE_ALLOC);
    }

    function test_claim_anyoneCanClaimForAccount_tokensGoToAccount() public {
        _commit();
        vm.warp(CLAIM_START);
        vm.prank(stranger);
        _claim(BOB);
        assertEq(agentos.balanceOf(bob), BOB_ALLOC / 5);
        assertEq(agentos.balanceOf(stranger), 0);
    }

    /// @dev The deadline is the last second a claim is accepted.
    function test_claim_worksAtTheLastSecondOfTheDeadline() public {
        _commit();
        vm.warp(CLAIM_DEADLINE);
        assertEq(_claim(ALICE), ALICE_ALLOC);
        assertEq(agentos.balanceOf(alice), ALICE_ALLOC);
    }

    function test_claim_revertsAfterTheDeadline() public {
        _commit();
        vm.warp(CLAIM_DEADLINE + 1);
        vm.expectRevert(abi.encodeWithSelector(IMerkleVestingDistributor.ClaimsExpired.selector, CLAIM_DEADLINE));
        _claim(ALICE);
        assertEq(distributor.claimableAmount(alice, ALICE_ALLOC), 0);

        // Still closed years later, and while the tokens are still in the contract.
        vm.warp(CLAIM_DEADLINE + 3650 days);
        vm.expectRevert(abi.encodeWithSelector(IMerkleVestingDistributor.ClaimsExpired.selector, CLAIM_DEADLINE));
        _claim(ALICE);
        assertEq(agentos.balanceOf(alice), 0);
    }

    /// @dev A claimant who took the first 20% and never came back loses the rest at the deadline.
    function test_claim_partialClaimantCannotFinishAfterTheDeadline() public {
        _commit();
        vm.warp(CLAIM_START);
        _claim(BOB);
        vm.warp(CLAIM_DEADLINE + 1);
        vm.expectRevert(abi.encodeWithSelector(IMerkleVestingDistributor.ClaimsExpired.selector, CLAIM_DEADLINE));
        _claim(BOB);
        assertEq(agentos.balanceOf(bob), BOB_ALLOC / 5);
    }

    function test_claim_rejectsForgedLeaves() public {
        _commit();
        vm.warp(CLAIM_START + VESTING);
        bytes32[] memory proof = _proof(ALICE);

        // Bigger amount.
        vm.expectRevert(IMerkleVestingDistributor.InvalidProof.selector);
        distributor.claim(alice, ALICE_ALLOC + 1, proof);
        // Different account.
        vm.expectRevert(IMerkleVestingDistributor.InvalidProof.selector);
        distributor.claim(stranger, ALICE_ALLOC, proof);
        // Someone else's allocation.
        vm.expectRevert(IMerkleVestingDistributor.InvalidProof.selector);
        distributor.claim(alice, BOB_ALLOC, proof);
        // Someone else's proof.
        vm.expectRevert(IMerkleVestingDistributor.InvalidProof.selector);
        distributor.claim(alice, ALICE_ALLOC, _proof(BOB));
        // Empty proof.
        vm.expectRevert(IMerkleVestingDistributor.InvalidProof.selector);
        distributor.claim(alice, ALICE_ALLOC, new bytes32[](0));
    }

    /// @dev A 64-byte inner node must not be accepted as a leaf (second preimage).
    function test_claim_innerNodeCannotBeUsedAsLeaf() public {
        _commit();
        vm.warp(CLAIM_START + VESTING);
        // Try to pass (leaf0, leaf1) as if abi.encode(...) preimage of a leaf: the double hash and
        // the fixed 128-byte preimage make any node hash unreachable. Sanity-check with a proof
        // that starts one level up.
        bytes32[] memory proof = _proof(ALICE);
        bytes32[] memory shorter = new bytes32[](proof.length - 1);
        for (uint256 i; i < shorter.length; ++i) {
            shorter[i] = proof[i + 1];
        }
        vm.expectRevert(IMerkleVestingDistributor.InvalidProof.selector);
        distributor.claim(alice, ALICE_ALLOC, shorter);
    }

    /// @dev A tree is bound to one deployment: the same root cannot even be committed elsewhere,
    ///      and a leaf hashes differently there.
    function test_claim_treeIsBoundToOneDistributor() public {
        _commit();

        MerkleVestingDistributor other = new MerkleVestingDistributor(safe, IERC20(address(agentos)), BUDGET);
        agentos.mint(address(other), BUDGET);
        vm.expectRevert(IMerkleVestingDistributor.InvalidSampleLeaf.selector);
        _commitWith(other, _root(), treeTotal, CLAIM_START);
        assertTrue(other.leafOf(alice, ALICE_ALLOC) != distributor.leafOf(alice, ALICE_ALLOC));
    }

    function test_claim_proofIsBoundToChainId() public {
        _commit();
        bytes32 leafHere = distributor.leafOf(alice, ALICE_ALLOC);
        vm.chainId(4663);
        assertTrue(distributor.leafOf(alice, ALICE_ALLOC) != leafHere);
        vm.warp(CLAIM_START);
        vm.expectRevert(IMerkleVestingDistributor.InvalidProof.selector);
        _claim(ALICE);
    }

    /// @dev If the owner states a total smaller than the tree, payouts stop at the stated total
    ///      instead of eating into tokens that are not committed.
    function test_claim_cannotExceedCommittedTotal() public {
        _commitWith(distributor, _root(), ALICE_ALLOC + 10e18, CLAIM_START);
        vm.warp(CLAIM_START + VESTING);

        _claim(ALICE);
        vm.expectRevert(IMerkleVestingDistributor.AllocationExceeded.selector);
        _claim(BOB);
        assertEq(distributor.totalClaimed(), ALICE_ALLOC);
    }

    /// @dev A stated total above the real sum is not stealable. The difference stays reserved until
    ///      the claim deadline, then goes back to treasury with everything else that is unclaimed.
    function test_commit_overstatedTotalIsReservedUntilTheDeadline() public {
        _commitWith(distributor, _root(), treeTotal + 500e18, CLAIM_START);
        vm.prank(safe);
        distributor.sweepExcess(treasury);
        vm.warp(CLAIM_DEADLINE);
        for (uint256 i; i < entries.length; ++i) {
            _claim(i);
        }
        assertEq(agentos.balanceOf(address(distributor)), 500e18);
        assertEq(distributor.excess(), 0);

        vm.warp(CLAIM_DEADLINE + 1);
        vm.prank(safe);
        assertEq(distributor.sweepExcess(treasury), 500e18);
        assertEq(agentos.balanceOf(address(distributor)), 0);
    }

    function test_claim_viewsMatch() public {
        assertEq(distributor.vestedAmount(ALICE_ALLOC, CLAIM_START + 30 days), 0); // no root yet
        assertEq(distributor.claimableAmount(alice, ALICE_ALLOC), 0);
        _commit();

        assertEq(distributor.vestedAmount(ALICE_ALLOC, CLAIM_START - 1), 0);
        assertEq(distributor.vestedAmount(ALICE_ALLOC, CLAIM_START), ALICE_ALLOC / 5);
        assertEq(distributor.vestedAmount(ALICE_ALLOC, CLAIM_START + 30 days), (ALICE_ALLOC * 60) / 100);
        assertEq(distributor.vestedAmount(ALICE_ALLOC, CLAIM_START + 60 days), ALICE_ALLOC);

        vm.warp(CLAIM_START + 30 days);
        uint256 expected = distributor.claimableAmount(alice, ALICE_ALLOC);
        assertEq(_claim(ALICE), expected);
        assertEq(distributor.claimableAmount(alice, ALICE_ALLOC), 0);
    }

    function test_claim_tokenCannotReenter() public {
        ReentrantERC20 evil = new ReentrantERC20();
        MerkleVestingDistributor d = new MerkleVestingDistributor(safe, IERC20(address(evil)), BUDGET);
        evil.mint(address(d), 1_000e18);

        bytes32[] memory l = new bytes32[](2);
        l[0] = d.leafOf(alice, 600e18);
        l[1] = d.leafOf(bob, 400e18);
        bytes32[] memory aliceProof = MerkleHelper.proof(l, 0);
        vm.prank(safe);
        d.commitRoot(MerkleHelper.root(l), 1_000e18, CLAIM_START, alice, 600e18, aliceProof);
        vm.warp(CLAIM_START + VESTING);

        bytes32[] memory bobProof = MerkleHelper.proof(l, 1);
        evil.arm(address(d), abi.encodeCall(d.claim, (bob, 400e18, bobProof)));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        d.claim(alice, 600e18, MerkleHelper.proof(l, 0));

        evil.disarm();
        d.claim(alice, 600e18, MerkleHelper.proof(l, 0));
        d.claim(bob, 400e18, bobProof);
        assertEq(evil.balanceOf(address(d)), 0);
    }

    // ------------------------------------------------------------------
    // postponeClaimStart
    // ------------------------------------------------------------------

    function test_postpone_shiftsOpenAndVesting() public {
        _commit();
        uint64 newStart = CLAIM_START + 3 days;
        vm.expectEmit(true, true, true, true);
        emit IMerkleVestingDistributor.ClaimStartPostponed(CLAIM_START, newStart);
        vm.prank(safe);
        distributor.postponeClaimStart(newStart);

        vm.warp(CLAIM_START);
        vm.expectRevert(abi.encodeWithSelector(IMerkleVestingDistributor.ClaimsNotOpen.selector, newStart));
        _claim(ALICE);

        // Opening, vesting and the claim deadline all follow the new open time.
        assertEq(distributor.claimDeadline(), newStart + VESTING + GRACE);
        vm.warp(newStart);
        assertEq(_claim(ALICE), ALICE_ALLOC / 5);
        assertEq(_claim(BOB), BOB_ALLOC / 5);
        vm.warp(newStart + VESTING);
        _claim(BOB);
        assertEq(agentos.balanceOf(bob), BOB_ALLOC);
    }

    /// @dev Postponing never shortens the time a claimant has: the deadline moves by the same amount.
    function test_postpone_movesTheClaimDeadline() public {
        _commit();
        vm.prank(safe);
        distributor.postponeClaimStart(CLAIM_START + 5 days);

        vm.warp(CLAIM_DEADLINE + 5 days);
        assertEq(_claim(ALICE), ALICE_ALLOC);
        vm.warp(CLAIM_DEADLINE + 5 days + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IMerkleVestingDistributor.ClaimsExpired.selector, CLAIM_DEADLINE + 5 days)
        );
        _claim(BOB);
    }

    function test_postpone_bounds() public {
        vm.prank(safe);
        vm.expectRevert(IMerkleVestingDistributor.RootNotCommitted.selector);
        distributor.postponeClaimStart(CLAIM_START + 1);

        _commit();
        vm.startPrank(safe);
        vm.expectRevert(IMerkleVestingDistributor.InvalidClaimStart.selector);
        distributor.postponeClaimStart(CLAIM_START); // not later
        vm.expectRevert(IMerkleVestingDistributor.InvalidClaimStart.selector);
        distributor.postponeClaimStart(CLAIM_START - 1); // never earlier
        vm.expectRevert(IMerkleVestingDistributor.InvalidClaimStart.selector);
        distributor.postponeClaimStart(T0 + 30 days + 1); // hard ceiling

        distributor.postponeClaimStart(T0 + 30 days); // exactly the ceiling
        vm.expectRevert(IMerkleVestingDistributor.InvalidClaimStart.selector);
        distributor.postponeClaimStart(T0 + 30 days + 1); // the ceiling does not move
        vm.stopPrank();
    }

    function test_postpone_notOnceClaimsAreOpen() public {
        _commit();
        vm.warp(CLAIM_START);
        vm.prank(safe);
        vm.expectRevert(IMerkleVestingDistributor.ClaimsAlreadyOpen.selector);
        distributor.postponeClaimStart(CLAIM_START + 1 days);
    }

    function test_postpone_onlyOwner() public {
        _commit();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        distributor.postponeClaimStart(CLAIM_START + 1 days);
    }

    // ------------------------------------------------------------------
    // sweepExcess / rescue
    // ------------------------------------------------------------------

    function test_sweep_beforeCommitTakesEverything() public {
        assertEq(distributor.excess(), BUDGET);
        vm.prank(safe);
        assertEq(distributor.sweepExcess(treasury), BUDGET);
        assertEq(agentos.balanceOf(treasury), BUDGET);
    }

    function test_sweep_afterCommitOnlyUnusedBudget() public {
        _commit();
        assertEq(distributor.excess(), BUDGET - treeTotal);

        vm.expectEmit(true, true, true, true);
        emit IMerkleVestingDistributor.ExcessSwept(treasury, BUDGET - treeTotal);
        vm.prank(safe);
        distributor.sweepExcess(treasury);
        assertEq(agentos.balanceOf(treasury), BUDGET - treeTotal);
        assertEq(agentos.balanceOf(address(distributor)), treeTotal);

        vm.prank(safe);
        vm.expectRevert(IMerkleVestingDistributor.NothingToSweep.selector);
        distributor.sweepExcess(treasury);

        // Every leaf can still be paid in full.
        vm.warp(CLAIM_START + VESTING);
        for (uint256 i; i < entries.length; ++i) {
            _claim(i);
        }
        assertEq(agentos.balanceOf(address(distributor)), 0);
        assertEq(distributor.outstanding(), 0);
    }

    /// @dev Until the deadline (inclusive) the owner cannot reach a single committed token.
    function test_sweep_cannotTouchUnclaimedUntilTheDeadline() public {
        _commit();
        vm.prank(safe);
        distributor.sweepExcess(treasury);

        vm.warp(CLAIM_DEADLINE);
        assertEq(distributor.outstanding(), treeTotal);
        assertEq(distributor.excess(), 0);
        vm.prank(safe);
        vm.expectRevert(IMerkleVestingDistributor.NothingToSweep.selector);
        distributor.sweepExcess(treasury);
        assertEq(_claim(ALICE), ALICE_ALLOC);
    }

    /// @dev One month after vesting ends, whatever was not claimed goes back to treasury.
    function test_sweep_afterTheDeadlineReturnsUnclaimedToTreasury() public {
        _commit();
        vm.prank(safe);
        distributor.sweepExcess(treasury);

        vm.warp(CLAIM_START);
        _claim(BOB); // 20%, never comes back
        vm.warp(CLAIM_START + VESTING);
        _claim(ALICE); // everything
        // locker and dave never show up.
        uint256 unclaimed = treeTotal - ALICE_ALLOC - BOB_ALLOC / 5;

        vm.warp(CLAIM_DEADLINE + 1);
        assertEq(distributor.outstanding(), 0);
        assertEq(distributor.excess(), unclaimed);

        vm.expectEmit(true, true, true, true);
        emit IMerkleVestingDistributor.ExcessSwept(treasury, unclaimed);
        vm.prank(safe);
        assertEq(distributor.sweepExcess(treasury), unclaimed);

        assertEq(agentos.balanceOf(address(distributor)), 0);
        assertEq(agentos.balanceOf(treasury), BUDGET - ALICE_ALLOC - BOB_ALLOC / 5);
        // The record of what was paid is untouched.
        assertEq(distributor.totalAllocation(), treeTotal);
        assertEq(distributor.totalClaimed(), ALICE_ALLOC + BOB_ALLOC / 5);

        vm.prank(safe);
        vm.expectRevert(IMerkleVestingDistributor.NothingToSweep.selector);
        distributor.sweepExcess(treasury);
    }

    function test_sweep_afterTheDeadlineIsStillOwnerOnly() public {
        _commit();
        vm.warp(CLAIM_DEADLINE + 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        distributor.sweepExcess(stranger);
    }

    function test_sweep_guards() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        distributor.sweepExcess(stranger);

        vm.prank(safe);
        vm.expectRevert(IMerkleVestingDistributor.ZeroAddress.selector);
        distributor.sweepExcess(address(0));
    }

    function test_rescue_otherTokensOnly() public {
        MockERC20 other = new MockERC20("Other", "OTH");
        other.mint(address(distributor), 5e18);

        vm.startPrank(safe);
        vm.expectRevert(IMerkleVestingDistributor.CannotRescueDistributedToken.selector);
        distributor.rescue(address(agentos), safe, 1);
        vm.expectRevert(IMerkleVestingDistributor.ZeroAddress.selector);
        distributor.rescue(address(other), address(0), 1);
        vm.expectRevert(IMerkleVestingDistributor.ZeroAmount.selector);
        distributor.rescue(address(other), safe, 0);
        distributor.rescue(address(other), safe, 5e18);
        vm.stopPrank();
        assertEq(other.balanceOf(safe), 5e18);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        distributor.rescue(address(other), stranger, 1);
    }

    function test_ownership_twoStepAndNoRenounce() public {
        address newSafe = makeAddr("new safe");
        vm.prank(safe);
        distributor.transferOwnership(newSafe);
        assertEq(distributor.owner(), safe);
        vm.prank(newSafe);
        distributor.acceptOwnership();
        assertEq(distributor.owner(), newSafe);

        vm.prank(newSafe);
        vm.expectRevert(IMerkleVestingDistributor.RenounceDisabled.selector);
        distributor.renounceOwnership();
    }

    // ------------------------------------------------------------------
    // Fuzz: vesting curve
    // ------------------------------------------------------------------

    function testFuzz_vested_boundedAndMonotonic(uint256 allocation, uint256 t1, uint256 t2) public {
        _commit();
        allocation = bound(allocation, 0, 100_000_000_000e18); // up to total supply
        t1 = bound(t1, 0, CLAIM_DEADLINE + 365 days);
        t2 = bound(t2, t1, CLAIM_DEADLINE + 365 days);

        uint256 v1 = distributor.vestedAmount(allocation, t1);
        uint256 v2 = distributor.vestedAmount(allocation, t2);

        assertLe(v1, v2, "monotonic");
        assertLe(v2, allocation, "bounded");
        if (t1 < CLAIM_START) assertEq(v1, 0, "nothing before start");
        if (t2 >= CLAIM_START) assertGe(v2, (allocation * 2_000) / 10_000, "at least 20% from start");
        if (t2 >= CLAIM_START + VESTING) assertEq(v2, allocation, "all at the end");
        // Every leaf is fully vested a whole grace period before the claim deadline.
        assertEq(distributor.vestedAmount(allocation, CLAIM_DEADLINE - GRACE), allocation, "vested before deadline");
    }

    function testFuzz_claim_neverPaysMoreThanAllocation(uint256[8] memory steps) public {
        _commit();
        uint256 t = CLAIM_START;
        uint256 paid;
        for (uint256 i; i < steps.length; ++i) {
            t += bound(steps[i], 0, 20 days);
            vm.warp(t);
            try this.externalClaim(BOB) returns (uint256 amount) {
                paid += amount;
            } catch {}
            assertEq(paid, distributor.vestedAmount(BOB_ALLOC, t));
        }
        assertLe(paid, BOB_ALLOC);
        assertEq(agentos.balanceOf(bob), paid);
    }

    function externalClaim(uint256 index) external returns (uint256) {
        return _claim(index);
    }
}
