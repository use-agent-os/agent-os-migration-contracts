// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IMerkleVestingDistributor} from "@migration/interfaces/IMerkleVestingDistributor.sol";

/// @title MerkleVestingDistributor
/// @notice Holds AGENTOS on Robinhood and pays migration claims from a Merkle root.
///         Vesting: 20% unlocks when claims open, 80% unlocks linearly over the next 60 days.
///         Every leaf follows the same schedule. Claims close 30 days after vesting ends, and
///         whatever was not claimed by then goes back to treasury.
///
/// @dev    Security model (see README for the full threat model):
///         - Not upgradeable. No delegatecall. No pause: once the root is committed nobody,
///           the owner included, can stop, change or redirect a claim before `claimDeadline()`.
///         - The root is committed once and can never change.
///         - `commitRoot` reverts unless the contract already holds the full `totalAllocation`, and
///           `totalAllocation` can never exceed `MAX_TOTAL_ALLOCATION` (the 5B budget in the
///           current migration deployment).
///         - The owner can only ever take out what is above `outstanding()` (committed, not yet
///           claimed). Before the root is committed nothing is owed, so the owner can take all.
///         - `claimDeadline()` is derived from `claimStart` and two constants. The owner cannot
///           choose it or bring it closer. Until that second (inclusive) the committed tokens
///           are out of the owner's reach. After it claims are closed for good and
///           `outstanding()` is zero, so `sweepExcess` returns the unclaimed rest to treasury.
///         - A leaf binds chain id and this contract's address, so a proof cannot be replayed on
///           another deployment or chain. `commitRoot` proves one sample leaf, so a tree built for
///           the wrong chain or address is rejected instead of locking the funds for 90 days.
///         - Robinhood (4663) is an Arbitrum Orbit chain: `block.number` is the L1 block there.
///           Only `block.timestamp` is used.
contract MerkleVestingDistributor is IMerkleVestingDistributor, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------- Constants ----------

    uint256 public constant BPS = 10_000;
    /// @notice Share unlocked when claims open: 20%.
    uint256 public constant INITIAL_UNLOCK_BPS = 2_000;
    /// @notice The other 80% unlocks linearly over this long.
    uint64 public constant VESTING_DURATION = 60 days;
    /// @notice Claims stay open this long after vesting ends. Then the unclaimed rest can be swept.
    uint64 public constant CLAIM_GRACE = 30 days;
    /// @notice Claims must open, at the latest, this long after the root is committed.
    uint64 public constant MAX_CLAIM_START_DELAY = 30 days;

    // ---------- Immutables ----------

    /// @notice The distributed token (AGENTOS).
    IERC20 public immutable TOKEN;
    /// @notice Ceiling for `totalAllocation`. The migration budget.
    uint256 public immutable MAX_TOTAL_ALLOCATION;

    // ---------- State ----------

    /// @notice Root of the claim tree. Zero until committed, immutable after.
    bytes32 public merkleRoot;
    /// @notice When claims open and every leaf starts vesting.
    uint64 public claimStart;
    /// @notice `postponeClaimStart` can never go past this. Fixed when the root is committed.
    uint64 public latestClaimStart;
    /// @notice Sum of all leaves, as stated by the owner at commit. Never changes after.
    uint256 public totalAllocation;
    /// @notice Sum of everything paid out.
    uint256 public totalClaimed;
    /// @notice leaf => amount already paid for that leaf.
    mapping(bytes32 leaf => uint256 amount) public claimedOf;

    // ---------- Constructor ----------

    /// @param owner_              Team Safe on Robinhood.
    /// @param token_              AGENTOS.
    /// @param maxTotalAllocation_ Budget ceiling (5B AGENTOS in the current migration deployment).
    constructor(address owner_, IERC20 token_, uint256 maxTotalAllocation_) Ownable(owner_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        if (address(token_).code.length == 0) revert InvalidConfig();
        if (maxTotalAllocation_ == 0) revert InvalidConfig();

        TOKEN = token_;
        MAX_TOTAL_ALLOCATION = maxTotalAllocation_;
    }

    // =====================================================================
    //                              USER ACTIONS
    // =====================================================================

    /// @notice Pay out everything vested so far for one leaf. Anyone can call it for any account,
    ///         the tokens only ever go to `account`. Open from `claimStart` to `claimDeadline()`,
    ///         both inclusive.
    /// @param account    Recipient written in the leaf.
    /// @param allocation Total AGENTOS of the leaf.
    /// @param proof      Merkle proof of the leaf.
    /// @return amount    AGENTOS transferred by this call.
    function claim(address account, uint256 allocation, bytes32[] calldata proof)
        external
        nonReentrant
        returns (uint256 amount)
    {
        bytes32 root = merkleRoot;
        if (root == bytes32(0)) revert RootNotCommitted();
        uint64 claimStart_ = claimStart;
        if (block.timestamp < claimStart_) revert ClaimsNotOpen(claimStart_);
        uint64 deadline = _deadlineOf(claimStart_);
        if (block.timestamp > deadline) revert ClaimsExpired(deadline);

        bytes32 leaf = leafOf(account, allocation);
        if (!MerkleProof.verifyCalldata(proof, root, leaf)) revert InvalidProof();

        uint256 alreadyClaimed = claimedOf[leaf];
        uint256 vested = _vested(allocation, claimStart_, block.timestamp);
        if (vested <= alreadyClaimed) revert NothingToClaim();
        unchecked {
            amount = vested - alreadyClaimed;
        }

        uint256 newTotalClaimed = totalClaimed + amount;
        // The tree can never pay more than was committed and funded.
        if (newTotalClaimed > totalAllocation) revert AllocationExceeded();

        claimedOf[leaf] = vested;
        totalClaimed = newTotalClaimed;

        TOKEN.safeTransfer(account, amount);

        emit Claimed(leaf, account, amount, vested, msg.sender);
    }

    // =====================================================================
    //                              OWNER ACTIONS
    // =====================================================================

    /// @notice Commit the claim tree. Once. The contract must already hold `totalAllocation_`.
    /// @dev    The sample leaf must be a real leaf of the tree. It proves the tree was built for
    ///         this chain and this contract with the right encoding: a root that nobody can claim
    ///         from would lock the committed tokens until the claim deadline.
    /// @param root             Merkle root of the published tree.
    /// @param totalAllocation_ Sum of all leaves. Must match the published tree exactly.
    /// @param claimStart_      When claims open. Claims close `VESTING_DURATION + CLAIM_GRACE` later.
    /// @param sampleAccount    Account of any one leaf of the tree.
    /// @param sampleAllocation Allocation of that leaf.
    /// @param sampleProof      Merkle proof of that leaf.
    function commitRoot(
        bytes32 root,
        uint256 totalAllocation_,
        uint64 claimStart_,
        address sampleAccount,
        uint256 sampleAllocation,
        bytes32[] calldata sampleProof
    ) external onlyOwner {
        if (merkleRoot != bytes32(0)) revert RootAlreadyCommitted();
        if (root == bytes32(0)) revert InvalidRoot();
        if (totalAllocation_ == 0 || totalAllocation_ > MAX_TOTAL_ALLOCATION) revert InvalidAllocation();

        uint64 latest = uint64(block.timestamp) + MAX_CLAIM_START_DELAY;
        if (claimStart_ <= block.timestamp || claimStart_ > latest) revert InvalidClaimStart();

        uint256 balance = TOKEN.balanceOf(address(this));
        if (balance < totalAllocation_) revert Underfunded(totalAllocation_, balance);

        if (sampleAccount == address(0) || sampleAllocation == 0 || sampleAllocation > totalAllocation_) {
            revert InvalidSampleLeaf();
        }
        if (!MerkleProof.verifyCalldata(sampleProof, root, leafOf(sampleAccount, sampleAllocation))) {
            revert InvalidSampleLeaf();
        }

        merkleRoot = root;
        totalAllocation = totalAllocation_;
        claimStart = claimStart_;
        latestClaimStart = latest;

        emit RootCommitted(root, totalAllocation_, claimStart_, latest);
    }

    /// @notice Open claims later than planned (the liquidity must be in place first). Only before
    ///         claims opened, only later, and never past `latestClaimStart`. Vesting and the claim
    ///         deadline move with it, so claimants never get less time.
    function postponeClaimStart(uint64 newClaimStart) external onlyOwner {
        if (merkleRoot == bytes32(0)) revert RootNotCommitted();
        uint64 current = claimStart;
        if (block.timestamp >= current) revert ClaimsAlreadyOpen();
        if (newClaimStart <= current || newClaimStart > latestClaimStart) revert InvalidClaimStart();

        claimStart = newClaimStart;

        emit ClaimStartPostponed(current, newClaimStart);
    }

    /// @notice Send everything above `outstanding()` to `to`. Before the claim deadline that is the
    ///         unused budget. After it, it is everything left: the AGENTOS nobody claimed.
    function sweepExcess(address to) external onlyOwner nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = excess();
        if (amount == 0) revert NothingToSweep();

        TOKEN.safeTransfer(to, amount);

        emit ExcessSwept(to, amount);
    }

    /// @notice Recover any other token sent here by mistake. Never the distributed token.
    function rescue(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(TOKEN)) revert CannotRescueDistributedToken();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransfer(to, amount);

        emit Rescued(token, to, amount);
    }

    /// @dev Keeps the excess sweepable for ever. An owner must always exist.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // =====================================================================
    //                                 VIEWS
    // =====================================================================

    /// @notice Leaf hash. Same layout as OpenZeppelin `StandardMerkleTree` with the types
    ///         `["uint256", "address", "address", "uint256"]`. One leaf per account.
    /// @dev    Hashed twice, so a 64-byte inner node can never be passed off as a leaf.
    function leafOf(address account, uint256 allocation) public view returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(block.chainid, address(this), account, allocation))));
    }

    /// @notice Amount of `allocation` vested at `timestamp`. Ignores the claim deadline.
    function vestedAmount(uint256 allocation, uint256 timestamp) external view returns (uint256) {
        if (merkleRoot == bytes32(0)) return 0;
        return _vested(allocation, claimStart, timestamp);
    }

    /// @notice Amount `claim` would pay right now for this leaf. Does not check the proof.
    function claimableAmount(address account, uint256 allocation) external view returns (uint256) {
        if (merkleRoot == bytes32(0)) return 0;
        uint64 claimStart_ = claimStart;
        if (block.timestamp > _deadlineOf(claimStart_)) return 0;
        uint256 vested = _vested(allocation, claimStart_, block.timestamp);
        uint256 alreadyClaimed = claimedOf[leafOf(account, allocation)];
        return vested > alreadyClaimed ? vested - alreadyClaimed : 0;
    }

    /// @notice Last second a claim is accepted: vesting end + `CLAIM_GRACE`. Zero until the root is
    ///         committed. Moves only with `postponeClaimStart`, and only later.
    function claimDeadline() public view returns (uint64) {
        if (merkleRoot == bytes32(0)) return 0;
        return _deadlineOf(claimStart);
    }

    /// @notice AGENTOS committed to claimants and not paid yet. Zero once the claim deadline has
    ///         passed: nothing is owed any more.
    function outstanding() public view returns (uint256) {
        if (merkleRoot != bytes32(0) && block.timestamp > _deadlineOf(claimStart)) return 0;
        return totalAllocation - totalClaimed;
    }

    /// @notice AGENTOS held above `outstanding()`. The only amount the owner can take.
    function excess() public view returns (uint256) {
        uint256 balance = TOKEN.balanceOf(address(this));
        uint256 owed = outstanding();
        return balance > owed ? balance - owed : 0;
    }

    // =====================================================================
    //                               INTERNALS
    // =====================================================================

    function _deadlineOf(uint64 claimStart_) internal pure returns (uint64) {
        return claimStart_ + VESTING_DURATION + CLAIM_GRACE;
    }

    /// @dev 0 before claims open, 20% when they open, then linear to 100% after `VESTING_DURATION`.
    ///      Monotonic in `timestamp`, never above `allocation`, exactly `allocation` at the end.
    function _vested(uint256 allocation, uint64 claimStart_, uint256 timestamp) internal pure returns (uint256) {
        if (timestamp < claimStart_) return 0;

        uint256 elapsed = timestamp - claimStart_;
        if (elapsed >= VESTING_DURATION) return allocation;

        uint256 initial = (allocation * INITIAL_UNLOCK_BPS) / BPS;
        return initial + ((allocation - initial) * elapsed) / VESTING_DURATION;
    }
}
