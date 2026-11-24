// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IMigrationVault
/// @notice Escrow on Base for the CAP + DACKIE -> AGENTOS migration.
interface IMigrationVault {
    // ---------- Types ----------

    /// @notice Lifecycle of the vault. Derived from state and time, never stored.
    /// @dev    Pending       deposits not open yet (recipients can already be registered)
    ///         Open          deposit + withdraw
    ///         Closed        ledger frozen, waiting for the claim root attestation
    ///         RootAttested  claim root attested, release possible once the delay has passed
    ///         Released      CAP + DACKIE handed to the owner for the sale (terminal)
    ///         Refunding     cancelled, or not released in time: withdrawals only (terminal)
    enum Phase {
        Pending,
        Open,
        Closed,
        RootAttested,
        Released,
        Refunding
    }

    /// @notice Constructor arguments.
    /// @param owner              Team Safe on Base.
    /// @param guardian           Optional independent veto. Can only cancel while a claim root is
    ///                           attested and not released yet. Zero disables it.
    /// @param cap                CAP token.
    /// @param dackie             DACKIE token.
    /// @param depositStart       First second deposits are accepted.
    /// @param depositDeadline    Last second deposits and withdrawals are accepted (inclusive).
    /// @param maxDepositDeadline Hard ceiling for `extendDeadline`.
    /// @param minRateNotice      Rates must be set at least this long before the deadline.
    /// @param releaseDelay       Minimum time between the root attestation and `release`.
    /// @param settlementGrace    Time after the deadline in which `release` must happen.
    /// @param maxDepositAllocation AGENTOS (18 decimals) the deposits may convert to, at most. Once
    ///                           the rates are set, a deposit that would go above it is refused.
    ///                           Leave room under the 5B budget for the long-lock allocations.
    struct InitParams {
        address owner;
        address guardian;
        IERC20 cap;
        IERC20 dackie;
        uint64 depositStart;
        uint64 depositDeadline;
        uint64 maxDepositDeadline;
        uint64 minRateNotice;
        uint64 releaseDelay;
        uint64 settlementGrace;
        uint256 maxDepositAllocation;
    }

    // ---------- Events ----------

    event Deposited(address indexed account, address indexed token, uint256 amount, address indexed recipient);
    event Withdrawn(address indexed account, address indexed token, uint256 amount);
    event Refunded(address indexed account, address indexed token, uint256 amount, address indexed caller);
    event RecipientRegistered(address indexed account, address indexed recipient);
    event BlockedSet(address indexed account, bool blocked);
    event RatesSet(uint256 capRate, uint256 dackieRate);
    event DeadlineExtended(uint64 previousDeadline, uint64 newDeadline);
    event ClaimRootAttested(
        bytes32 indexed root, uint256 totalAllocation, address indexed distributor, uint64 releasableAt
    );
    event Released(address indexed to, uint256 capAmount, uint256 dackieAmount);
    event Cancelled(address indexed by);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    // ---------- Errors ----------

    error ZeroAddress();
    error ZeroAmount();
    error InvalidConfig();
    error UnsupportedToken(address token);
    error DepositsNotOpen();
    error WithdrawalsClosed();
    error NotRefunding();
    error AccountBlocked(address account);
    error InsufficientDeposit(uint256 requested, uint256 available);
    error NothingReceived();
    error LedgerFrozen();
    error RatesFinal();
    error DepositCapExceeded(uint256 allocation, uint256 cap);
    error MigrationCancelled();
    error AlreadyReleased();
    error NotAuthorized();
    error InvalidRoot();
    error RatesNotSet();
    error InvalidRate();
    error RateNoticeTooShort();
    error InvalidDeadline();
    error WindowStillOpen();
    error SettlementWindowOver();
    error RootNotAttested();
    error ReleaseDelayNotElapsed(uint64 releasableAt);
    error InsufficientExcess(uint256 requested, uint256 available);
    error RenounceDisabled();

    // ---------- User actions ----------

    function deposit(IERC20 token, uint256 amount, address recipient) external returns (uint256 received);
    function withdraw(IERC20 token, uint256 amount) external;
    function refund(address account) external;
    function registerRecipient(address recipient) external;

    // ---------- Owner actions ----------

    function setBlocked(address[] calldata accounts, bool isBlocked) external;
    function setRates(uint256 capRate, uint256 dackieRate) external;
    function extendDeadline(uint64 newDeadline) external;
    function attestClaimRoot(bytes32 root, uint256 totalAllocation, address distributor) external;
    function release() external;
    function cancel() external;
    function pause() external;
    function unpause() external;
    function rescue(IERC20 token, address to, uint256 amount) external;

    // ---------- Views ----------

    function phase() external view returns (Phase);
    function settlementDeadline() external view returns (uint64);
    function releasableAt() external view returns (uint64);
    function withdrawalsOpen() external view returns (bool);
    function isSupportedToken(IERC20 token) external view returns (bool);
    function effectiveRecipient(address account) external view returns (address);
    function allocationOf(address account) external view returns (uint256);
    function totalDepositAllocation() external view returns (uint256);
    function excessOf(IERC20 token) external view returns (uint256);
}
