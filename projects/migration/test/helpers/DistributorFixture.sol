// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MerkleVestingDistributor} from "@migration/MerkleVestingDistributor.sol";

import {MockERC20} from "./MockERC20.sol";
import {MerkleHelper} from "./MerkleHelper.sol";

abstract contract DistributorFixture is Test {
    struct Entry {
        address account;
        uint256 allocation;
    }

    uint64 internal constant T0 = 1_798_416_000; // 2026-12-28 00:00:00 UTC, root commit day
    uint64 internal constant CLAIM_START = 1_798_675_200; // 2026-12-31 00:00:00 UTC
    uint64 internal constant VESTING = 60 days;
    uint64 internal constant GRACE = 30 days;
    /// @dev Last second a claim is accepted: 2027-03-31 00:00:00 UTC with the plan dates.
    uint64 internal constant CLAIM_DEADLINE = CLAIM_START + VESTING + GRACE;
    uint256 internal constant BUDGET = 5_000_000_000e18; // 5B AGENTOS

    address internal safe = makeAddr("safe");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal locker = makeAddr("long locker");
    address internal stranger = makeAddr("stranger");

    MockERC20 internal agentos;
    MerkleVestingDistributor internal distributor;

    Entry[] internal entries;
    bytes32[] internal leaves;
    uint256 internal treeTotal;

    function _deployDistributor() internal {
        vm.warp(T0);
        agentos = new MockERC20("AgentOS", "AGENTOS");
        distributor = new MerkleVestingDistributor(safe, IERC20(address(agentos)), BUDGET);
    }

    function _addEntry(address account, uint256 allocation) internal {
        entries.push(Entry(account, allocation));
        leaves.push(distributor.leafOf(account, allocation));
        treeTotal += allocation;
    }

    function _root() internal view returns (bytes32) {
        return MerkleHelper.root(leaves);
    }

    function _proof(uint256 index) internal view returns (bytes32[] memory) {
        return MerkleHelper.proof(leaves, index);
    }

    function _commit() internal {
        _commitWith(distributor, _root(), treeTotal, CLAIM_START);
    }

    /// @dev Commits with entry 0 as the sample leaf.
    function _commitWith(MerkleVestingDistributor d, bytes32 root, uint256 total, uint64 claimStart_) internal {
        Entry memory e = entries[0];
        bytes32[] memory proof = _proof(0);
        vm.prank(safe);
        d.commitRoot(root, total, claimStart_, e.account, e.allocation, proof);
    }

    function _claim(uint256 index) internal returns (uint256) {
        Entry memory e = entries[index];
        return distributor.claim(e.account, e.allocation, _proof(index));
    }
}
