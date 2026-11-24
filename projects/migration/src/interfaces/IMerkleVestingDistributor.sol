// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IMerkleVestingDistributor
/// @notice Pays AGENTOS claims on Robinhood from a Merkle root, with vesting and a claim deadline.
interface IMerkleVestingDistributor {
    // ---------- Events ----------

    event RootCommitted(bytes32 indexed root, uint256 totalAllocation, uint64 claimStart, uint64 latestClaimStart);
    event ClaimStartPostponed(uint64 previousClaimStart, uint64 newClaimStart);
    event Claimed(
        bytes32 indexed leaf, address indexed account, uint256 amount, uint256 totalClaimedForLeaf, address caller
    );
    event ExcessSwept(address indexed to, uint256 amount);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    // ---------- Errors ----------

    error ZeroAddress();
    error ZeroAmount();
    error InvalidConfig();
    error InvalidRoot();
    error RootAlreadyCommitted();
    error RootNotCommitted();
    error InvalidAllocation();
    error InvalidClaimStart();
    error Underfunded(uint256 required, uint256 balance);
    error ClaimsNotOpen(uint64 claimStart);
    error ClaimsAlreadyOpen();
    error ClaimsExpired(uint64 claimDeadline);
    error InvalidProof();
    error InvalidSampleLeaf();
    error NothingToClaim();
    error AllocationExceeded();
    error NothingToSweep();
    error CannotRescueDistributedToken();
    error RenounceDisabled();

    // ---------- User actions ----------

    function claim(address account, uint256 allocation, bytes32[] calldata proof) external returns (uint256 amount);

    // ---------- Owner actions ----------

    function commitRoot(
        bytes32 root,
        uint256 totalAllocation_,
        uint64 claimStart_,
        address sampleAccount,
        uint256 sampleAllocation,
        bytes32[] calldata sampleProof
    ) external;
    function postponeClaimStart(uint64 newClaimStart) external;
    function sweepExcess(address to) external returns (uint256 amount);
    function rescue(address token, address to, uint256 amount) external;

    // ---------- Views ----------

    function leafOf(address account, uint256 allocation) external view returns (bytes32);
    function vestedAmount(uint256 allocation, uint256 timestamp) external view returns (uint256);
    function claimableAmount(address account, uint256 allocation) external view returns (uint256);
    function claimDeadline() external view returns (uint64);
    function outstanding() external view returns (uint256);
    function excess() external view returns (uint256);
}
