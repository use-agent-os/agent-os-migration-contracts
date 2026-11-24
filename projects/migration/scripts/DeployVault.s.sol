// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {MigrationVault} from "@migration/MigrationVault.sol";
import {IMigrationVault} from "@migration/interfaces/IMigrationVault.sol";

import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys MigrationVault on Base. The team Safe is the owner from the first block: the
///         deployer key never has any power over the vault.
///
/// @dev Env vars (see env.example):
///   OWNER                 required, team Safe on Base
///   GUARDIAN              optional, independent veto address (default: none)
///   CAP_TOKEN             required
///   DACKIE_TOKEN          required
///   DEPOSIT_START         required, unix
///   DEPOSIT_DEADLINE      required, unix (inclusive)
///   MAX_DEPOSIT_DEADLINE  required, unix
///   MIN_RATE_NOTICE       optional, seconds (default 15 days)
///   RELEASE_DELAY         optional, seconds (default 24 hours)
///   SETTLEMENT_GRACE      optional, seconds (default 14 days)
///   MAX_DEPOSIT_ALLOCATION required, wei of AGENTOS the deposits may convert to (must be at most 4.20B,
///                         which leaves approximately 0.80B of the 5B budget for long-lock allocations)
///
/// The leaked-wallet blocklist is set by the Safe afterwards: see BlocklistBatches.s.sol.
contract DeployVault is DeployBase {
    uint256 internal constant MAX_RELEASE_DEPOSIT_CAP = 4_200_000_000e18;

    function _validateMaxDepositAllocation(uint256 allocation) internal pure {
        require(allocation >= 1_000_000e18, "MAX_DEPOSIT_ALLOCATION looks too small (wei?)");
        require(allocation <= MAX_RELEASE_DEPOSIT_CAP, "MAX_DEPOSIT_ALLOCATION is above the 4.20B deposit cap");
    }

    function run() external returns (MigrationVault vault) {
        _requireChain(BASE_CHAIN_ID);

        address owner = vm.envAddress("OWNER");
        _requireSafeOwner(owner);

        IMigrationVault.InitParams memory p = IMigrationVault.InitParams({
            owner: owner,
            guardian: vm.envOr("GUARDIAN", address(0)),
            cap: IERC20(vm.envAddress("CAP_TOKEN")),
            dackie: IERC20(vm.envAddress("DACKIE_TOKEN")),
            depositStart: uint64(vm.envUint("DEPOSIT_START")),
            depositDeadline: uint64(vm.envUint("DEPOSIT_DEADLINE")),
            maxDepositDeadline: uint64(vm.envUint("MAX_DEPOSIT_DEADLINE")),
            minRateNotice: uint64(vm.envOr("MIN_RATE_NOTICE", uint256(15 days))),
            releaseDelay: uint64(vm.envOr("RELEASE_DELAY", uint256(24 hours))),
            settlementGrace: uint64(vm.envOr("SETTLEMENT_GRACE", uint256(14 days))),
            maxDepositAllocation: vm.envUint("MAX_DEPOSIT_ALLOCATION")
        });
        // Unit mistake guard: the cap is in wei of AGENTOS, between 1M and the configured 4.20B cap.
        _validateMaxDepositAllocation(p.maxDepositAllocation);

        // Both tokens must be 18 decimals: the rate math assumes it.
        require(IERC20Metadata(address(p.cap)).decimals() == 18, "CAP is not 18 decimals");
        require(IERC20Metadata(address(p.dackie)).decimals() == 18, "DACKIE is not 18 decimals");

        vm.startBroadcast();
        vault = new MigrationVault(p);
        vm.stopBroadcast();

        // Record what the chain says, not what was asked for.
        require(vault.owner() == owner, "owner mismatch after deploy");
        require(vault.pendingOwner() == address(0), "unexpected pending owner");

        console2.log("MigrationVault:      ", address(vault));
        console2.log("Owner:               ", vault.owner());
        console2.log("Guardian:            ", vault.GUARDIAN());
        console2.log("Deposit start:       ", vault.DEPOSIT_START());
        console2.log("Deposit deadline:    ", vault.depositDeadline());
        console2.log("Rate correction until", vault.RATE_CORRECTION_CUTOFF());
        console2.log("Max deposit alloc:   ", vault.MAX_DEPOSIT_ALLOCATION());
        console2.log("Settlement deadline: ", vault.settlementDeadline());

        _writeDeployment(vault);
    }

    function _writeDeployment(MigrationVault vault) internal {
        string memory key = "vault";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "MigrationVault", address(vault));
        vm.serializeAddress(key, "owner", vault.owner());
        vm.serializeAddress(key, "guardian", vault.GUARDIAN());
        vm.serializeAddress(key, "capToken", address(vault.CAP()));
        vm.serializeAddress(key, "dackieToken", address(vault.DACKIE()));
        vm.serializeUint(key, "depositStart", vault.DEPOSIT_START());
        vm.serializeUint(key, "depositDeadline", vault.depositDeadline());
        vm.serializeUint(key, "maxDepositDeadline", vault.MAX_DEPOSIT_DEADLINE());
        vm.serializeUint(key, "minRateNotice", vault.MIN_RATE_NOTICE());
        vm.serializeUint(key, "rateCorrectionCutoff", vault.RATE_CORRECTION_CUTOFF());
        vm.serializeUint(key, "maxDepositAllocation", vault.MAX_DEPOSIT_ALLOCATION());
        vm.serializeUint(key, "releaseDelay", vault.RELEASE_DELAY());
        string memory json = vm.serializeUint(key, "settlementGrace", vault.SETTLEMENT_GRACE());
        _write(string.concat(_chainName(), "-vault"), json);
    }
}
