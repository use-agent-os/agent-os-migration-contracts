// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal Merkle tree builder for tests. Pairs are hashed sorted (commutative), the same
///         rule as OpenZeppelin `MerkleProof`. An unpaired node is carried up unchanged.
library MerkleHelper {
    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        require(leaves.length > 0, "empty tree");
        bytes32[] memory layer = leaves;
        while (layer.length > 1) {
            layer = _nextLayer(layer);
        }
        return layer[0];
    }

    function proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory) {
        require(index < leaves.length, "index");
        bytes32[] memory buffer = new bytes32[](256);
        uint256 count;
        bytes32[] memory layer = leaves;
        while (layer.length > 1) {
            uint256 sibling = index ^ 1;
            if (sibling < layer.length) buffer[count++] = layer[sibling];
            index /= 2;
            layer = _nextLayer(layer);
        }
        bytes32[] memory out = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            out[i] = buffer[i];
        }
        return out;
    }

    function _nextLayer(bytes32[] memory layer) private pure returns (bytes32[] memory next) {
        uint256 length = layer.length;
        next = new bytes32[]((length + 1) / 2);
        for (uint256 i; i < length; i += 2) {
            next[i / 2] = i + 1 < length ? hashPair(layer[i], layer[i + 1]) : layer[i];
        }
    }
}
