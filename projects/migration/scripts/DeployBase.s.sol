// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Shared guards for the deploy scripts.
abstract contract DeployBase is Script {
    uint256 internal constant BASE_CHAIN_ID = 8453;
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 internal constant LOCAL_CHAIN_ID = 31337;

    /// @dev The owner must be the team Safe on THIS chain: a contract that answers
    ///      `getThreshold()` with at least 2 and has at least as many owners. Skipped only on a
    ///      local chain, or with ALLOW_EOA_OWNER=true on a chain that is not Base or Robinhood
    ///      (testnet dry runs). On a production chain the flag makes the script revert.
    function _requireSafeOwner(address owner) internal view {
        _checkSafeOwner(owner, vm.envOr("ALLOW_EOA_OWNER", false));
    }

    function _checkSafeOwner(address owner, bool allowEoaOwner) internal view {
        require(owner != address(0), "OWNER is zero");
        if (block.chainid == LOCAL_CHAIN_ID) return;
        if (allowEoaOwner) {
            require(!_isProductionChain(block.chainid), "ALLOW_EOA_OWNER is not allowed on a production chain");
            return;
        }
        require(owner.code.length > 0, "OWNER has no code on this chain: expected the team Safe");

        (bool okThreshold, bytes memory threshold) = owner.staticcall(abi.encodeWithSignature("getThreshold()"));
        require(okThreshold && threshold.length == 32, "OWNER is not a Safe: getThreshold() failed");
        uint256 required = abi.decode(threshold, (uint256));
        require(required >= 2, "OWNER Safe threshold is below 2");

        (bool okOwners, bytes memory owners) = owner.staticcall(abi.encodeWithSignature("getOwners()"));
        require(okOwners, "OWNER is not a Safe: getOwners() failed");
        require(abi.decode(owners, (address[])).length >= required, "OWNER Safe has fewer owners than its threshold");
    }

    /// @dev Each script runs on its own chain. ALLOW_ANY_CHAIN=true lets it run on a testnet, never
    ///      on the other production chain (the vault on Robinhood, the distributor on Base).
    function _requireChain(uint256 expected) internal view {
        _checkChain(expected, vm.envOr("ALLOW_ANY_CHAIN", false));
    }

    function _checkChain(uint256 expected, bool allowAnyChain) internal view {
        if (block.chainid == LOCAL_CHAIN_ID || block.chainid == expected) return;
        require(allowAnyChain, "wrong chain for this script");
        require(!_isProductionChain(block.chainid), "ALLOW_ANY_CHAIN is not allowed on a production chain");
    }

    function _isProductionChain(uint256 id) internal pure returns (bool) {
        return id == BASE_CHAIN_ID || id == ROBINHOOD_CHAIN_ID;
    }

    function _chainName() internal view returns (string memory) {
        uint256 id = block.chainid;
        if (id == BASE_CHAIN_ID) return "baseMainnet";
        if (id == 84532) return "baseSepolia";
        if (id == ROBINHOOD_CHAIN_ID) return "robinhoodMainnet";
        if (id == LOCAL_CHAIN_ID) return "localhost";
        return string.concat("chain-", vm.toString(id));
    }

    function _write(string memory file, string memory json) internal {
        string memory path = string.concat("deployments/", file, ".json");
        vm.writeFile(path, json);
        console2.log("Wrote deployment to", path);
    }
}
