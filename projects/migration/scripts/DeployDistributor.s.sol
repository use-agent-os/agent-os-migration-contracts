// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {MerkleVestingDistributor} from "@migration/MerkleVestingDistributor.sol";

import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys MerkleVestingDistributor on Robinhood (4663).
///
/// @dev Env vars (see env.example):
///   OWNER                 required, team Safe on Robinhood
///   AGENTOS_TOKEN         required
///   MAX_TOTAL_ALLOCATION  optional, wei (must match the 5B AGENTOS release budget)
///
/// Funding is a plain AGENTOS transfer to the deployed address, done by the treasury afterwards.
contract DeployDistributor is DeployBase {
    function defaultMaxTotalAllocation() internal pure returns (uint256) {
        return 5_000_000_000e18;
    }

    function _validateMaxTotalAllocation(uint256 allocation) internal pure {
        require(allocation == defaultMaxTotalAllocation(), "MAX_TOTAL_ALLOCATION must be 5B AGENTOS");
    }

    function run() external returns (MerkleVestingDistributor distributor) {
        _requireChain(ROBINHOOD_CHAIN_ID);

        address owner = vm.envAddress("OWNER");
        _requireSafeOwner(owner);
        IERC20 token = IERC20(vm.envAddress("AGENTOS_TOKEN"));
        uint256 maxTotal = vm.envOr("MAX_TOTAL_ALLOCATION", defaultMaxTotalAllocation());
        _validateMaxTotalAllocation(maxTotal);

        require(IERC20Metadata(address(token)).decimals() == 18, "AGENTOS is not 18 decimals");
        // The budget is a share of supply: refuse an obviously wrong unit.
        require(maxTotal <= token.totalSupply(), "MAX_TOTAL_ALLOCATION above total supply");

        vm.startBroadcast();
        distributor = new MerkleVestingDistributor(owner, token, maxTotal);
        vm.stopBroadcast();

        // Fund only after this address and its owner have been confirmed on the explorer.
        require(distributor.owner() == owner, "owner mismatch after deploy");

        console2.log("MerkleVestingDistributor:", address(distributor));
        console2.log("Owner:                   ", distributor.owner());
        console2.log("Token:                   ", address(token));
        console2.log("Max total allocation:    ", maxTotal);

        string memory key = "distributor";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "MerkleVestingDistributor", address(distributor));
        vm.serializeAddress(key, "owner", owner);
        vm.serializeAddress(key, "token", address(token));
        // Use a string so JSON consumers can preserve all wei digits.
        string memory json = vm.serializeString(key, "maxTotalAllocation", vm.toString(maxTotal));
        _write(string.concat(_chainName(), "-distributor"), json);
    }
}
