// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {MigrationVault} from "@migration/MigrationVault.sol";

/// @notice Turns a list of leaked addresses into Safe Transaction Builder files that call
///         `MigrationVault.setBlocked(chunk, true)`. Nothing is broadcast: the Safe imports the
///         files and signs. No hot key ever holds a role on the vault.
///
/// @dev Env vars:
///   VAULT                 required, MigrationVault address
///   BLOCKLIST_FILE        required, one address per line (blank lines and # comments skipped),
///                         must be under ./configs
///   BLOCKLIST_BATCH       optional, addresses per setBlocked call (default 400)
///   BLOCKLIST_TX_PER_FILE optional, setBlocked calls per Safe batch file (default 3)
///
///   forge script scripts/BlocklistBatches.s.sol --rpc-url base
///
/// Output: deployments/blocklist-<n>.json, to import in the Safe Transaction Builder in order.
/// After execution, check a few addresses with `isBlocked(address)`.
contract BlocklistBatches is Script {
    function run() external {
        address vault = vm.envAddress("VAULT");
        address[] memory list = _readAddresses(vm.envString("BLOCKLIST_FILE"));
        uint256 batch = vm.envOr("BLOCKLIST_BATCH", uint256(400));
        uint256 perFile = vm.envOr("BLOCKLIST_TX_PER_FILE", uint256(3));
        require(batch != 0 && perFile != 0, "batch sizes must be non-zero");

        uint256 fileIndex;
        uint256 txInFile;
        string memory txs;
        for (uint256 from; from < list.length; from += batch) {
            uint256 to = from + batch > list.length ? list.length : from + batch;
            address[] memory chunk = new address[](to - from);
            for (uint256 i = from; i < to; ++i) {
                chunk[i - from] = list[i];
            }
            bytes memory data = abi.encodeCall(MigrationVault.setBlocked, (chunk, true));
            txs = string.concat(
                txs,
                txInFile == 0 ? "" : ",",
                '{"to":"',
                vm.toString(vault),
                '","value":"0","data":"',
                vm.toString(data),
                '"}'
            );
            if (++txInFile == perFile || to == list.length) {
                _writeFile(++fileIndex, txs);
                txs = "";
                txInFile = 0;
            }
        }

        console2.log("Addresses:", list.length);
        console2.log("Safe batch files written:", fileIndex);
    }

    function _writeFile(uint256 index, string memory txs) internal {
        string memory path = string.concat("deployments/blocklist-", vm.toString(index), ".json");
        vm.writeFile(
            path,
            string.concat(
                '{"version":"1.0","chainId":"',
                vm.toString(block.chainid),
                '","meta":{"name":"MigrationVault blocklist ',
                vm.toString(index),
                '"},"transactions":[',
                txs,
                "]}\n"
            )
        );
        console2.log("Wrote", path);
    }

    /// @dev One address per line. Blank lines and lines starting with '#' are skipped.
    ///      Duplicates are rejected so the count matches the source list.
    function _readAddresses(string memory path) internal view returns (address[] memory out) {
        string[] memory lines = vm.split(vm.readFile(path), "\n");
        address[] memory buffer = new address[](lines.length);
        uint256 count;
        for (uint256 i; i < lines.length; ++i) {
            string memory line = vm.trim(lines[i]);
            bytes memory raw = bytes(line);
            if (raw.length == 0 || raw[0] == "#") continue;
            address account = vm.parseAddress(line);
            require(account != address(0), "zero address in blocklist");
            buffer[count++] = account;
        }
        require(count != 0, "blocklist file has no addresses");
        out = new address[](count);
        for (uint256 i; i < count; ++i) {
            out[i] = buffer[i];
        }
    }
}
