// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IMigrationVault} from "@migration/interfaces/IMigrationVault.sol";

/// @title MigrationVault
/// @notice Escrow on Base for the CAP + DACKIE -> AGENTOS migration.
///
///         Holders deposit CAP / DACKIE during the window and name the address that receives AGENTOS
///         on Robinhood. Deposits can be withdrawn in full until the deadline. After the deadline the
///         ledger is frozen and the owner (team Safe) may take the tokens for the sale, but only after
///         it attested the claim root here and a public delay has passed.
///
/// @dev    Security model (see README for the full threat model):
///         - Not upgradeable. No delegatecall. No arbitrary external calls.
///         - Exits are never pausable: `withdraw` and `refund` ignore `pause`.
///         - The owner can never move user deposits except through `release`, which needs:
///           window closed + rates fixed on-chain + claim root attested + `RELEASE_DELAY` elapsed.
///         - If the owner does not release before `settlementDeadline`, or cancels, every depositor
///           gets a permissionless refund. Lost Safe keys cannot trap funds.
///         - Balances are credited by the amount actually received, so a fee-on-transfer token
///           (CAP is a Virtuals AgentToken whose owner can enable taxes on new pools) cannot make
///           the vault insolvent.
///         - Rates that are set can be corrected only until `RATE_CORRECTION_CUTOFF`, a date fixed
///           at deployment. Extending the deadline never reopens it.
///         - Once the rates are set, deposits that would exceed `MAX_DEPOSIT_ALLOCATION` revert.
///           A rate correction can still raise the value of existing deposits. Exits are not capped.
///         - Base cannot read Robinhood state. `attestClaimRoot` is the owner's public statement of
///           the root, total and distributor address committed on Robinhood. Anyone can compare
///           both chains during `RELEASE_DELAY`. This is public verifiability, not an on-chain
///           proof. An optional `GUARDIAN` can veto (cancel) in that delay, nothing else.
contract MigrationVault is IMigrationVault, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------- Constants ----------

    /// @notice Rates are AGENTOS (18 decimals) per 1 token (18 decimals), scaled by 1e18.
    uint256 public constant RATE_PRECISION = 1e18;
    /// @notice Sanity bounds for a rate, against unit mistakes (e.g. `25` instead of `25e18`).
    ///         Indicative rates are ~18e18 to ~26e18.
    uint256 public constant MIN_RATE = 1e15;
    uint256 public constant MAX_RATE = 1_000_000e18;

    uint64 public constant MIN_WINDOW = 14 days;
    uint64 public constant MAX_WINDOW = 180 days;
    uint64 public constant MIN_RATE_NOTICE_FLOOR = 7 days;
    uint64 public constant MAX_RATE_NOTICE = 30 days;
    uint64 public constant MIN_RELEASE_DELAY = 12 hours;
    uint64 public constant MAX_RELEASE_DELAY = 7 days;
    /// @notice Settlement must leave at least this much room after the release delay.
    uint64 public constant MIN_SETTLEMENT_MARGIN = 2 days;
    uint64 public constant MAX_SETTLEMENT_GRACE = 60 days;

    // ---------- Immutables ----------

    IERC20 public immutable CAP;
    IERC20 public immutable DACKIE;
    /// @notice Optional independent veto: may only `cancel` while a root is attested and not
    ///         released. Zero when disabled.
    address public immutable GUARDIAN;
    /// @notice First second deposits are accepted.
    uint64 public immutable DEPOSIT_START;
    /// @notice `extendDeadline` can never go past this.
    uint64 public immutable MAX_DEPOSIT_DEADLINE;
    /// @notice Rates must be set at least this long before the deposit deadline.
    uint64 public immutable MIN_RATE_NOTICE;
    /// @notice Last second a rate that is already set can be corrected: the initial deposit
    ///         deadline minus `MIN_RATE_NOTICE`. Fixed for good, `extendDeadline` does not move it.
    uint64 public immutable RATE_CORRECTION_CUTOFF;
    /// @notice Most AGENTOS the deposits may convert to. Enforced on `deposit` once rates are set.
    uint256 public immutable MAX_DEPOSIT_ALLOCATION;
    /// @notice Minimum time between `attestClaimRoot` and `release`.
    uint64 public immutable RELEASE_DELAY;
    /// @notice `release` must happen within this long after the deposit deadline.
    uint64 public immutable SETTLEMENT_GRACE;

    // ---------- State ----------

    /// @notice Last second deposits, withdrawals and recipient changes are accepted (inclusive).
    uint64 public depositDeadline;
    /// @notice Time of the latest claim root attestation. Zero when none.
    uint64 public claimRootAttestedAt;
    /// @notice True once the owner cancelled the migration. Irreversible.
    bool public cancelled;
    /// @notice True once CAP + DACKIE were handed to the owner for the sale. Irreversible.
    bool public released;
    /// @notice True once rates are set. They can be corrected only until `RATE_CORRECTION_CUTOFF`.
    bool public ratesSet;

    /// @notice Claim root the owner states was committed in the distributor on Robinhood.
    bytes32 public claimRoot;
    /// @notice `totalAllocation` the owner states was committed with that root.
    uint256 public attestedTotalAllocation;
    /// @notice Address of the distributor on Robinhood the owner states holds that root.
    address public attestedDistributor;

    /// @notice AGENTOS per CAP, scaled by `RATE_PRECISION`.
    uint256 public capRate;
    /// @notice AGENTOS per DACKIE, scaled by `RATE_PRECISION`.
    uint256 public dackieRate;

    /// @notice token => account => deposited amount (as received by the vault).
    mapping(IERC20 token => mapping(address account => uint256 amount)) public depositOf;
    /// @notice token => sum of all deposits. Kept as a record after `release`.
    mapping(IERC20 token => uint256 amount) public totalDeposited;
    /// @notice account => Robinhood address that receives its AGENTOS. Zero means "same address".
    mapping(address account => address recipient) public recipientOf;
    /// @notice Accounts that may not deposit, register, or be named as a recipient (leaked keys).
    mapping(address account => bool) public isBlocked;

    // ---------- Constructor ----------

    constructor(InitParams memory p) Ownable(p.owner) {
        if (address(p.cap) == address(0) || address(p.dackie) == address(0)) revert ZeroAddress();
        if (address(p.cap) == address(p.dackie)) revert InvalidConfig();
        if (address(p.cap).code.length == 0 || address(p.dackie).code.length == 0) revert InvalidConfig();

        if (p.minRateNotice < MIN_RATE_NOTICE_FLOOR || p.minRateNotice > MAX_RATE_NOTICE) revert InvalidConfig();
        if (p.releaseDelay < MIN_RELEASE_DELAY || p.releaseDelay > MAX_RELEASE_DELAY) revert InvalidConfig();
        if (p.settlementGrace < p.releaseDelay + MIN_SETTLEMENT_MARGIN || p.settlementGrace > MAX_SETTLEMENT_GRACE) {
            revert InvalidConfig();
        }

        // The window is measured from when deposits can really start.
        uint256 opening = p.depositStart > block.timestamp ? p.depositStart : block.timestamp;
        if (p.depositDeadline < opening + MIN_WINDOW) revert InvalidConfig();
        if (p.depositDeadline < opening + p.minRateNotice) revert InvalidConfig();
        if (p.maxDepositDeadline < p.depositDeadline) revert InvalidConfig();
        if (p.maxDepositDeadline > opening + MAX_WINDOW) revert InvalidConfig();

        // A guardian that is also the owner would be no check at all.
        if (p.guardian == p.owner) revert InvalidConfig();
        if (p.maxDepositAllocation == 0) revert InvalidConfig();

        CAP = p.cap;
        DACKIE = p.dackie;
        GUARDIAN = p.guardian;
        DEPOSIT_START = p.depositStart;
        MAX_DEPOSIT_DEADLINE = p.maxDepositDeadline;
        MIN_RATE_NOTICE = p.minRateNotice;
        RATE_CORRECTION_CUTOFF = p.depositDeadline - p.minRateNotice;
        MAX_DEPOSIT_ALLOCATION = p.maxDepositAllocation;
        RELEASE_DELAY = p.releaseDelay;
        SETTLEMENT_GRACE = p.settlementGrace;
        depositDeadline = p.depositDeadline;
    }

    // =====================================================================
    //                              USER ACTIONS
    // =====================================================================

    /// @notice Deposit CAP or DACKIE for migration.
    /// @dev    Only `msg.sender` is credited: a plain transfer to the vault is not a deposit.
    ///         The recipient applies to the whole account (both tokens and any long-lock
    ///         entitlement) and replaces the one set before.
    ///         Once the rates are set, reverts if the deposits would convert to more than
    ///         `MAX_DEPOSIT_ALLOCATION` AGENTOS. A withdrawal frees that room again.
    /// @param token     CAP or DACKIE.
    /// @param amount    Amount to pull from the caller.
    /// @param recipient Address that receives the caller's AGENTOS on Robinhood. EOAs normally pass
    ///                  their own address. Contract wallets must pass an address they control there.
    /// @return received Amount credited (what the vault actually received).
    function deposit(IERC20 token, uint256 amount, address recipient)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 received)
    {
        _requireSupported(token);
        if (!_depositsOpen()) revert DepositsNotOpen();
        if (amount == 0) revert ZeroAmount();
        _setRecipient(msg.sender, recipient);

        // Credit what arrived, not what was asked for (fee-on-transfer safe).
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        received = token.balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert NothingReceived();

        depositOf[token][msg.sender] += received;
        totalDeposited[token] += received;

        // Before the rates are set this is zero: an allocation is not known yet.
        uint256 allocation = totalDepositAllocation();
        if (allocation > MAX_DEPOSIT_ALLOCATION) revert DepositCapExceeded(allocation, MAX_DEPOSIT_ALLOCATION);

        emit Deposited(msg.sender, address(token), received, recipient);
    }

    /// @notice Take back a deposit. Open during the window, and again for good if the migration is
    ///         cancelled or the owner did not release in time. Never pausable.
    function withdraw(IERC20 token, uint256 amount) external nonReentrant {
        _requireSupported(token);
        if (!withdrawalsOpen()) revert WithdrawalsClosed();
        if (amount == 0) revert ZeroAmount();

        _debit(token, msg.sender, amount);
        token.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, address(token), amount);
    }

    /// @notice Push a full refund of both tokens to `account`. Anyone can call it, the tokens only
    ///         ever go to `account`. Only when the migration is cancelled or timed out.
    function refund(address account) external nonReentrant {
        if (!_refunding()) revert NotRefunding();

        uint256 capAmount = depositOf[CAP][account];
        uint256 dackieAmount = depositOf[DACKIE][account];
        if (capAmount == 0 && dackieAmount == 0) revert ZeroAmount();

        if (capAmount != 0) {
            _debit(CAP, account, capAmount);
            CAP.safeTransfer(account, capAmount);
            emit Refunded(account, address(CAP), capAmount, msg.sender);
        }
        if (dackieAmount != 0) {
            _debit(DACKIE, account, dackieAmount);
            DACKIE.safeTransfer(account, dackieAmount);
            emit Refunded(account, address(DACKIE), dackieAmount, msg.sender);
        }
    }

    /// @notice Set the Robinhood address that receives the caller's AGENTOS, without depositing.
    /// @dev    For contract wallets, and for DACKIE long-lockers who never deposit. Callable before
    ///         the window opens. Frozen with the ledger at the deposit deadline.
    function registerRecipient(address recipient) external {
        if (cancelled) revert MigrationCancelled();
        if (block.timestamp > depositDeadline) revert LedgerFrozen();
        _setRecipient(msg.sender, recipient);
    }

    // =====================================================================
    //                              OWNER ACTIONS
    // =====================================================================

    /// @notice Block or unblock accounts (leaked keys). A blocked account cannot deposit, register a
    ///         recipient, or be named as one. It can still withdraw what it deposited before.
    function setBlocked(address[] calldata accounts, bool blocked_) external onlyOwner {
        uint256 length = accounts.length;
        for (uint256 i; i < length; ++i) {
            address account = accounts[i];
            if (isBlocked[account] != blocked_) {
                isBlocked[account] = blocked_;
                emit BlockedSet(account, blocked_);
            }
        }
    }

    /// @notice Set the conversion rates. Always at least `MIN_RATE_NOTICE` before the deadline, so
    ///         every depositor has that long to withdraw after the last change.
    /// @dev    A correction (wrong unit, swapped arguments) is possible only until
    ///         `RATE_CORRECTION_CUTOFF`. After it, rates that are set are final for good: extending
    ///         the deadline gives depositors more time, never the owner a new correction window.
    ///         Rates that were never set can still be set late, after `extendDeadline` restored the
    ///         notice. They are then final at once.
    ///         The deposit cap does not block this call. If the new rates put the existing deposits
    ///         above `MAX_DEPOSIT_ALLOCATION`, new deposits stop until withdrawals free room.
    /// @param capRate_    AGENTOS per CAP, scaled by 1e18.
    /// @param dackieRate_ AGENTOS per DACKIE, scaled by 1e18.
    function setRates(uint256 capRate_, uint256 dackieRate_) external onlyOwner {
        if (cancelled) revert MigrationCancelled();
        if (capRate_ < MIN_RATE || dackieRate_ < MIN_RATE || capRate_ > MAX_RATE || dackieRate_ > MAX_RATE) {
            revert InvalidRate();
        }
        if (ratesSet && block.timestamp > RATE_CORRECTION_CUTOFF) revert RatesFinal();
        if (block.timestamp + MIN_RATE_NOTICE > depositDeadline) revert RateNoticeTooShort();

        ratesSet = true;
        capRate = capRate_;
        dackieRate = dackieRate_;

        emit RatesSet(capRate_, dackieRate_);
    }

    /// @notice Push the deposit deadline later. Only while the window is still open, never past
    ///         `MAX_DEPOSIT_DEADLINE`. It can only give depositors more time, never less. It does
    ///         not move `RATE_CORRECTION_CUTOFF`.
    function extendDeadline(uint64 newDeadline) external onlyOwner {
        if (cancelled) revert MigrationCancelled();
        uint64 current = depositDeadline;
        if (block.timestamp > current) revert LedgerFrozen();
        if (newDeadline <= current || newDeadline > MAX_DEPOSIT_DEADLINE) revert InvalidDeadline();

        depositDeadline = newDeadline;

        emit DeadlineExtended(current, newDeadline);
    }

    /// @notice State publicly what was committed in the distributor on Robinhood.
    /// @dev    Starts the `RELEASE_DELAY` clock. Attesting again (to fix a mistake) restarts it.
    ///         Nothing here is checked against Robinhood: it is published so anyone can compare
    ///         `distributor.merkleRoot()` and `distributor.totalAllocation()` on chain 4663.
    /// @param root            `merkleRoot` committed in the distributor.
    /// @param totalAllocation `totalAllocation` committed in the distributor.
    /// @param distributor     Address of the distributor on Robinhood.
    function attestClaimRoot(bytes32 root, uint256 totalAllocation, address distributor) external onlyOwner {
        _requireSettling();
        if (!ratesSet) revert RatesNotSet();
        if (root == bytes32(0)) revert InvalidRoot();
        if (totalAllocation == 0) revert ZeroAmount();
        if (distributor == address(0)) revert ZeroAddress();
        // Too late to ever release: fail here instead of giving a false sense of progress.
        if (block.timestamp + RELEASE_DELAY > settlementDeadline()) revert SettlementWindowOver();

        claimRoot = root;
        attestedTotalAllocation = totalAllocation;
        attestedDistributor = distributor;
        claimRootAttestedAt = uint64(block.timestamp);

        emit ClaimRootAttested(root, totalAllocation, distributor, uint64(block.timestamp) + RELEASE_DELAY);
    }

    /// @notice Hand all deposited CAP + DACKIE to the owner (team Safe) for the sale.
    /// @dev    Both tokens leave in one call so the vault is never half released.
    function release() external onlyOwner nonReentrant {
        _requireSettling();
        if (claimRoot == bytes32(0)) revert RootNotAttested();
        uint64 releasableAt_ = claimRootAttestedAt + RELEASE_DELAY;
        if (block.timestamp < releasableAt_) revert ReleaseDelayNotElapsed(releasableAt_);

        released = true;

        address to = owner();
        uint256 capAmount = totalDeposited[CAP];
        uint256 dackieAmount = totalDeposited[DACKIE];
        if (capAmount != 0) CAP.safeTransfer(to, capAmount);
        if (dackieAmount != 0) DACKIE.safeTransfer(to, dackieAmount);

        emit Released(to, capAmount, dackieAmount);
    }

    /// @notice Cancel the migration. Deposits stop, every depositor can withdraw. Irreversible.
    /// @dev    The owner can cancel any time before `release`. The guardian, if there is one, can
    ///         cancel only while a claim root is attested and not released: a veto over a release
    ///         it believes is wrong, and nothing more.
    function cancel() external {
        if (msg.sender != owner()) {
            if (msg.sender != GUARDIAN) revert NotAuthorized();
            _requireSettling();
            if (claimRoot == bytes32(0)) revert RootNotAttested();
        }
        if (released) revert AlreadyReleased();
        if (cancelled) revert MigrationCancelled();

        cancelled = true;

        emit Cancelled(msg.sender);
    }

    /// @notice Stop new deposits. Withdrawals and refunds are not affected.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Recover tokens sent to the vault by mistake. For CAP / DACKIE only the amount above
    ///         what depositors are owed can leave.
    function rescue(IERC20 token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 available = excessOf(token);
        if (amount > available) revert InsufficientExcess(amount, available);

        token.safeTransfer(to, amount);

        emit Rescued(address(token), to, amount);
    }

    /// @dev The owner is the only party that can release or cancel. It must always exist.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // =====================================================================
    //                                 VIEWS
    // =====================================================================

    /// @inheritdoc IMigrationVault
    function phase() external view returns (Phase) {
        if (released) return Phase.Released;
        if (cancelled) return Phase.Refunding;
        if (block.timestamp < DEPOSIT_START) return Phase.Pending;
        if (block.timestamp <= depositDeadline) return Phase.Open;
        if (block.timestamp > settlementDeadline()) return Phase.Refunding;
        if (claimRoot != bytes32(0)) return Phase.RootAttested;
        return Phase.Closed;
    }

    /// @notice Last second `release` is possible. After it, refunds open for good.
    function settlementDeadline() public view returns (uint64) {
        return depositDeadline + SETTLEMENT_GRACE;
    }

    /// @notice Earliest time `release` can be called. Zero when no root is attested.
    function releasableAt() external view returns (uint64) {
        uint64 attestedAt = claimRootAttestedAt;
        return attestedAt == 0 ? 0 : attestedAt + RELEASE_DELAY;
    }

    /// @notice True when `withdraw` works right now.
    function withdrawalsOpen() public view returns (bool) {
        if (released) return false;
        if (cancelled) return true;
        return block.timestamp <= depositDeadline || block.timestamp > settlementDeadline();
    }

    function isSupportedToken(IERC20 token) public view returns (bool) {
        return token == CAP || token == DACKIE;
    }

    /// @notice Address that receives `account`'s AGENTOS: the registered one, else itself.
    function effectiveRecipient(address account) external view returns (address) {
        address recipient = recipientOf[account];
        return recipient == address(0) ? account : recipient;
    }

    /// @notice AGENTOS that `account`'s deposits convert to. Zero until the rates are set.
    /// @dev    The claim tree must use this exact formula (each token rounded down on its own).
    function allocationOf(address account) external view returns (uint256) {
        return (depositOf[CAP][account] * capRate) / RATE_PRECISION
            + (depositOf[DACKIE][account] * dackieRate) / RATE_PRECISION;
    }

    /// @notice Upper bound of the AGENTOS owed to all depositors. Zero until the rates are set.
    ///         Team deposits count here too, although they get no leaf.
    function totalDepositAllocation() public view returns (uint256) {
        return (totalDeposited[CAP] * capRate) / RATE_PRECISION + (totalDeposited[DACKIE] * dackieRate) / RATE_PRECISION;
    }

    /// @notice Amount of `token` the owner may rescue: everything above what depositors are owed.
    function excessOf(IERC20 token) public view returns (uint256) {
        uint256 balance = token.balanceOf(address(this));
        if (!isSupportedToken(token) || released) return balance;
        uint256 owed = totalDeposited[token];
        return balance > owed ? balance - owed : 0;
    }

    // =====================================================================
    //                               INTERNALS
    // =====================================================================

    function _requireSupported(IERC20 token) internal view {
        if (!isSupportedToken(token)) revert UnsupportedToken(address(token));
    }

    function _depositsOpen() internal view returns (bool) {
        return !cancelled && block.timestamp >= DEPOSIT_START && block.timestamp <= depositDeadline;
    }

    function _refunding() internal view returns (bool) {
        if (released) return false;
        return cancelled || block.timestamp > settlementDeadline();
    }

    /// @dev Reverts unless the vault is between the deposit deadline and the settlement deadline,
    ///      not cancelled and not released. `release` and refunds are mutually exclusive in time.
    function _requireSettling() internal view {
        if (cancelled) revert MigrationCancelled();
        if (released) revert AlreadyReleased();
        if (block.timestamp <= depositDeadline) revert WindowStillOpen();
        if (block.timestamp > settlementDeadline()) revert SettlementWindowOver();
    }

    function _setRecipient(address account, address recipient) internal {
        if (recipient == address(0)) revert ZeroAddress();
        if (isBlocked[account]) revert AccountBlocked(account);
        if (isBlocked[recipient]) revert AccountBlocked(recipient);

        if (recipientOf[account] != recipient) {
            recipientOf[account] = recipient;
            emit RecipientRegistered(account, recipient);
        }
    }

    function _debit(IERC20 token, address account, uint256 amount) internal {
        uint256 available = depositOf[token][account];
        if (amount > available) revert InsufficientDeposit(amount, available);
        unchecked {
            depositOf[token][account] = available - amount;
        }
        // Sum of deposits always equals totalDeposited, so this cannot underflow.
        totalDeposited[token] -= amount;
    }
}
