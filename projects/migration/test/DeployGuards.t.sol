// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {DeployBase} from "../scripts/DeployBase.s.sol";
import {DeployDistributor} from "../scripts/DeployDistributor.s.sol";
import {DeployVault} from "../scripts/DeployVault.s.sol";

contract MockSafe {
    uint256 internal threshold;
    address[] internal owners;

    constructor(uint256 threshold_, uint256 ownerCount) {
        threshold = threshold_;
        for (uint256 i; i < ownerCount; ++i) {
            owners.push(address(uint160(0x1000 + i)));
        }
    }

    function getThreshold() external view returns (uint256) {
        return threshold;
    }

    function getOwners() external view returns (address[] memory) {
        return owners;
    }
}

contract NotASafe {}

contract GuardHarness is DeployBase {
    function requireSafeOwner(address owner) external view {
        _requireSafeOwner(owner);
    }

    function requireChain(uint256 expected) external view {
        _requireChain(expected);
    }

    function checkSafeOwner(address owner, bool allowEoaOwner) external view {
        _checkSafeOwner(owner, allowEoaOwner);
    }

    function checkChain(uint256 expected, bool allowAnyChain) external view {
        _checkChain(expected, allowAnyChain);
    }
}

contract DistributorBudgetHarness is DeployDistributor {
    function defaultBudget() external pure returns (uint256) {
        return defaultMaxTotalAllocation();
    }

    function validateBudget(uint256 budget) external pure {
        _validateMaxTotalAllocation(budget);
    }
}

contract VaultBudgetHarness is DeployVault {
    function validateCap(uint256 cap) external pure {
        _validateMaxDepositAllocation(cap);
    }
}

/// @notice The deploy scripts must refuse an owner that is not a real multisig on that chain.
contract DeployGuardsTest is Test {
    GuardHarness internal harness;
    DistributorBudgetHarness internal distributorBudget;
    VaultBudgetHarness internal vaultBudget;

    function setUp() public {
        harness = new GuardHarness();
        distributorBudget = new DistributorBudgetHarness();
        vaultBudget = new VaultBudgetHarness();
        vm.chainId(8453); // the guards are skipped on a local chain
    }

    function test_budgetConfigurationUses5B() public {
        assertEq(distributorBudget.defaultBudget(), 5_000_000_000e18);
        distributorBudget.validateBudget(5_000_000_000e18);
        vm.expectRevert(bytes("MAX_TOTAL_ALLOCATION must be 5B AGENTOS"));
        distributorBudget.validateBudget(10_000_000_000e18);
    }

    function test_deploymentVaultCapPreservesLongLockHeadroom() public {
        vaultBudget.validateCap(4_200_000_000e18);
        vm.expectRevert(bytes("MAX_DEPOSIT_ALLOCATION is above the 4.20B deposit cap"));
        vaultBudget.validateCap(4_200_000_000e18 + 1);
    }

    function test_acceptsA2of3Safe() public {
        harness.requireSafeOwner(address(new MockSafe(2, 3)));
    }

    function test_rejectsZeroEoaPlainContractAndWeakSafe() public {
        vm.expectRevert(bytes("OWNER is zero"));
        harness.requireSafeOwner(address(0));

        vm.expectRevert(bytes("OWNER has no code on this chain: expected the team Safe"));
        harness.requireSafeOwner(makeAddr("eoa"));

        address notASafe = address(new NotASafe());
        vm.expectRevert(bytes("OWNER is not a Safe: getThreshold() failed"));
        harness.requireSafeOwner(notASafe);

        address oneOfOne = address(new MockSafe(1, 1));
        vm.expectRevert(bytes("OWNER Safe threshold is below 2"));
        harness.requireSafeOwner(oneOfOne);

        address broken = address(new MockSafe(3, 2));
        vm.expectRevert(bytes("OWNER Safe has fewer owners than its threshold"));
        harness.requireSafeOwner(broken);
    }

    function test_rejectsWrongChain() public {
        harness.requireChain(8453);
        vm.expectRevert(bytes("wrong chain for this script"));
        harness.requireChain(4663);
    }

    /// @dev ALLOW_EOA_OWNER is for testnet dry runs. On Base or Robinhood it is refused outright, so
    ///      a flag left in .env cannot produce a production vault owned by an EOA.
    function test_eoaOwnerBypassIsRefusedOnProductionChains() public {
        address eoa = makeAddr("eoa");

        vm.chainId(8453);
        vm.expectRevert(bytes("ALLOW_EOA_OWNER is not allowed on a production chain"));
        harness.checkSafeOwner(eoa, true);
        vm.chainId(4663);
        vm.expectRevert(bytes("ALLOW_EOA_OWNER is not allowed on a production chain"));
        harness.checkSafeOwner(eoa, true);

        // Still usable where it is meant to be used.
        vm.chainId(84532);
        harness.checkSafeOwner(eoa, true);
        vm.expectRevert(bytes("OWNER has no code on this chain: expected the team Safe"));
        harness.checkSafeOwner(eoa, false);
    }

    /// @dev ALLOW_ANY_CHAIN lets a script run on a testnet. It never lets the vault script run on
    ///      Robinhood or the distributor script on Base.
    function test_anyChainBypassNeverCrossesProductionChains() public {
        vm.chainId(4663);
        vm.expectRevert(bytes("ALLOW_ANY_CHAIN is not allowed on a production chain"));
        harness.checkChain(8453, true);
        vm.chainId(8453);
        vm.expectRevert(bytes("ALLOW_ANY_CHAIN is not allowed on a production chain"));
        harness.checkChain(4663, true);

        // The right production chain is fine with or without the flag.
        harness.checkChain(8453, true);
        harness.checkChain(8453, false);

        vm.chainId(84532);
        harness.checkChain(8453, true);
        vm.expectRevert(bytes("wrong chain for this script"));
        harness.checkChain(8453, false);
    }
}
