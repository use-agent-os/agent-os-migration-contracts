// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {MerkleVestingDistributor} from "@migration/MerkleVestingDistributor.sol";

import {DistributorFixture} from "../helpers/DistributorFixture.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

interface IClaimDriver {
    function entryCount() external view returns (uint256);
    function claimEntry(uint256 index, address caller) external returns (uint256);
}

/// @notice Random claimers, random time jumps, and an owner that sweeps whenever it can.
contract DistributorHandler is Test {
    MerkleVestingDistributor internal immutable distributor;
    MockERC20 internal immutable token;
    IClaimDriver internal immutable driver;
    address internal immutable safe;
    address internal immutable treasury;

    uint256 public swept;
    uint256 public donated;
    uint256 public paid;

    constructor(MerkleVestingDistributor d, MockERC20 t, IClaimDriver driver_, address safe_, address treasury_) {
        distributor = d;
        token = t;
        driver = driver_;
        safe = safe_;
        treasury = treasury_;
    }

    function claim(uint256 index, address caller) external {
        index = index % driver.entryCount();
        paid += driver.claimEntry(index, caller);
    }

    function warp(uint256 delta) external {
        // Mix short and long jumps so both the pre-open phase and late vesting get explored.
        vm.warp(block.timestamp + _bound(delta, 1, delta % 2 == 0 ? 6 hours : 30 days));
    }

    /// @dev Jumps past the claim deadline, so the "unclaimed goes back to treasury" phase is explored.
    function warpPastAllVesting(uint256 seed) external {
        if (seed % 8 != 0) return;
        vm.warp(block.timestamp + 400 days);
    }

    function claimAll(address caller) external {
        uint256 n = driver.entryCount();
        for (uint256 i; i < n; ++i) {
            try driver.claimEntry(i, caller) returns (uint256 amount) {
                paid += amount;
            } catch {}
        }
    }

    function ownerSweep() external {
        vm.prank(safe);
        swept += distributor.sweepExcess(treasury);
    }

    function ownerPostpone(uint256 delta) external {
        uint64 newStart = distributor.claimStart() + uint64(_bound(delta, 1, 10 days));
        vm.prank(safe); // after reading state: a prank only covers the very next call
        distributor.postponeClaimStart(newStart);
    }

    function ownerRescueDistributedToken(uint256 amount) external {
        vm.prank(safe);
        distributor.rescue(address(token), safe, _bound(amount, 1, type(uint128).max));
    }

    function donate(uint256 amount) external {
        amount = _bound(amount, 0, 1_000e18);
        token.mint(address(distributor), amount);
        donated += amount;
    }
}

contract DistributorInvariantTest is DistributorFixture, IClaimDriver {
    DistributorHandler internal handler;
    uint256 internal constant FUNDED = 5_000_000e18;

    function setUp() public {
        _deployDistributor();
        // 12 leaves, one per account (the tree builder merges everything an account is owed).
        for (uint256 i; i < 12; ++i) {
            address account = makeAddr(string.concat("claimer", vm.toString(i)));
            uint256 allocation = (i + 1) * 12_345e18 + i; // odd wei amounts to exercise rounding
            _addEntry(account, allocation);
        }
        agentos.mint(address(distributor), FUNDED);
        _commit();

        handler = new DistributorHandler(distributor, agentos, IClaimDriver(address(this)), safe, treasury);
        targetContract(address(handler));
    }

    function entryCount() external view returns (uint256) {
        return entries.length;
    }

    function claimEntry(uint256 index, address caller) external returns (uint256) {
        vm.prank(caller);
        return _claim(index);
    }

    /// @dev The contract can always pay everything it still owes.
    function invariant_solvent() public view {
        assertGe(agentos.balanceOf(address(distributor)), distributor.outstanding(), "solvency");
    }

    /// @dev Until the claim deadline the owner cannot reach one committed token: the contract holds
    ///      everything that is committed and not yet paid. After it, nothing is owed any more.
    function invariant_committedIsUntouchableUntilTheDeadline() public view {
        uint256 unpaid = distributor.totalAllocation() - distributor.totalClaimed();
        if (block.timestamp <= distributor.claimDeadline()) {
            assertEq(distributor.outstanding(), unpaid, "owed until the deadline");
            assertGe(agentos.balanceOf(address(distributor)), unpaid, "held until the deadline");
        } else {
            assertEq(distributor.outstanding(), 0, "nothing owed after the deadline");
        }
    }

    /// @dev Every token is accounted for: funded + donated == held + claimed + swept.
    function invariant_conservation() public view {
        assertEq(
            FUNDED + handler.donated(),
            agentos.balanceOf(address(distributor)) + distributor.totalClaimed() + handler.swept(),
            "conservation"
        );
        assertEq(agentos.balanceOf(safe), 0, "owner never receives the distributed token directly");
        assertEq(agentos.balanceOf(treasury), handler.swept(), "treasury only gets swept excess");
    }

    /// @dev Per leaf: never more than vested, never more than its allocation. Sum == totalClaimed.
    function invariant_perLeafBounds() public view {
        uint256 sum;
        uint256 n = entries.length;
        for (uint256 i; i < n; ++i) {
            Entry memory e = entries[i];
            uint256 claimed = distributor.claimedOf(leaves[i]);
            assertLe(claimed, e.allocation, "leaf <= allocation");
            assertLe(claimed, distributor.vestedAmount(e.allocation, block.timestamp), "leaf <= vested");
            assertEq(agentos.balanceOf(e.account), claimed, "account received exactly what its leaf paid");
            sum += claimed;
        }
        assertEq(sum, distributor.totalClaimed(), "sum of leaves");
        assertEq(sum, handler.paid(), "paid");
        assertLe(distributor.totalClaimed(), distributor.totalAllocation(), "never above committed total");
    }

    /// @dev The root and the committed total never change. Claims never open earlier.
    function invariant_commitmentIsFrozen() public view {
        assertEq(distributor.merkleRoot(), _root());
        assertEq(distributor.totalAllocation(), treeTotal);
        assertGe(distributor.claimStart(), CLAIM_START);
        assertLe(distributor.claimStart(), distributor.latestClaimStart());
        assertEq(distributor.latestClaimStart(), T0 + 30 days);
        // The deadline is derived, never set: always 60 days of vesting + 30 days after claims open.
        assertEq(distributor.claimDeadline(), distributor.claimStart() + VESTING + GRACE);
    }
}
