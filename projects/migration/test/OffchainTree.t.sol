// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MerkleVestingDistributor} from "@migration/MerkleVestingDistributor.sol";
import {IMerkleVestingDistributor} from "@migration/interfaces/IMerkleVestingDistributor.sol";

import {MockERC20} from "./helpers/MockERC20.sol";

/// @notice Cross-checks the off-chain tree builder (offchain/build-tree.mjs, OpenZeppelin
///         StandardMerkleTree) against the contract's leaf encoding.
/// @dev    Regenerate the fixture with:
///         node offchain/build-tree.mjs --input test/fixtures/tree.csv --chain-id 31337 \
///           --distributor 0x00000000000000000000000000000000d157A1b0 --claim-start 1798675200 \
///           --max-total 5000000000000000000000000000 --out test/fixtures/tree.json
contract OffchainTreeTest is Test {
    using stdJson for string;

    address internal constant DISTRIBUTOR = 0x00000000000000000000000000000000d157A1b0;
    uint256 internal constant BUDGET = 5_000_000_000e18;
    uint64 internal constant T0 = 1_798_416_000;
    uint64 internal constant CLAIM_START = 1_798_675_200;

    address internal safe = makeAddr("safe");
    MockERC20 internal agentos;
    MerkleVestingDistributor internal distributor;
    string internal json;

    function setUp() public {
        vm.warp(T0);
        agentos = new MockERC20("AgentOS", "AGENTOS");
        // The leaf binds the distributor address, so the fixture needs a fixed one.
        deployCodeTo(
            "MerkleVestingDistributor.sol:MerkleVestingDistributor",
            abi.encode(safe, IERC20(address(agentos)), BUDGET),
            DISTRIBUTOR
        );
        distributor = MerkleVestingDistributor(DISTRIBUTOR);
        json = vm.readFile("test/fixtures/tree.json");

        assertEq(json.readUint(".chainId"), block.chainid, "fixture chain id");
        assertEq(json.readAddress(".distributor"), DISTRIBUTOR, "fixture distributor");
    }

    function _claimAt(uint256 i) internal view returns (address account, uint256 allocation, bytes32[] memory proof) {
        string memory base = string.concat(".claims[", vm.toString(i), "]");
        account = json.readAddress(string.concat(base, ".account"));
        allocation = json.readUint(string.concat(base, ".allocation"));
        proof = json.readBytes32Array(string.concat(base, ".proof"));
    }

    /// @dev Commits with the sample leaf the builder wrote for exactly this purpose.
    function _commit(uint256 total) internal {
        address account = json.readAddress(".sample.account");
        uint256 allocation = json.readUint(".sample.allocation");
        bytes32[] memory proof = json.readBytes32Array(".sample.proof");
        vm.prank(safe);
        distributor.commitRoot(json.readBytes32(".root"), total, CLAIM_START, account, allocation, proof);
    }

    function test_everyOffchainProofPaysOutOnchain() public {
        uint256 total = json.readUint(".totalAllocation");
        uint256 count = json.readUint(".count");
        agentos.mint(DISTRIBUTOR, total);
        _commit(total);

        // Fully vested, still inside the claim period.
        vm.warp(CLAIM_START + 60 days);
        uint256 sum;
        for (uint256 i; i < count; ++i) {
            (address account, uint256 allocation, bytes32[] memory proof) = _claimAt(i);
            uint256 before = agentos.balanceOf(account);
            uint256 paid = distributor.claim(account, allocation, proof);
            assertEq(paid, allocation, "full payout");
            assertEq(agentos.balanceOf(account) - before, allocation, "received");
            sum += allocation;
        }

        // The file's total is exactly the sum of its leaves, and the contract ends empty.
        assertEq(sum, total, "sum of leaves == totalAllocation");
        assertEq(distributor.totalClaimed(), total);
        assertEq(distributor.outstanding(), 0);
        assertEq(agentos.balanceOf(DISTRIBUTOR), 0);
    }

    function test_offchainProofFailsWithTamperedFields() public {
        uint256 total = json.readUint(".totalAllocation");
        agentos.mint(DISTRIBUTOR, total);
        _commit(total);
        vm.warp(CLAIM_START + 60 days);

        (address account, uint256 allocation, bytes32[] memory proof) = _claimAt(2);
        vm.expectRevert(IMerkleVestingDistributor.InvalidProof.selector);
        distributor.claim(account, allocation + 1, proof);
        vm.expectRevert(IMerkleVestingDistributor.InvalidProof.selector);
        distributor.claim(account, allocation - 1, proof);
        vm.expectRevert(IMerkleVestingDistributor.InvalidProof.selector);
        distributor.claim(address(this), allocation, proof);
    }
}
