// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {MigrationVault} from "@migration/MigrationVault.sol";
import {IMigrationVault} from "@migration/interfaces/IMigrationVault.sol";

import {VaultFixture} from "./helpers/VaultFixture.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {MockTaxERC20} from "./helpers/MockTaxERC20.sol";
import {ReentrantERC20} from "./helpers/ReentrantERC20.sol";

contract MigrationVaultTest is VaultFixture {
    IERC20 internal capT;
    IERC20 internal dackieT;

    function setUp() public {
        _deployVault();
        capT = IERC20(address(cap));
        dackieT = IERC20(address(dackie));
        _fund(alice, 1_000e18, 500e18);
        _fund(bob, 2_000e18, 0);
        _fund(leaked, 100e18, 100e18);
    }

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    function test_constructor_setsConfig() public view {
        assertEq(vault.owner(), safe);
        assertEq(address(vault.CAP()), address(cap));
        assertEq(address(vault.DACKIE()), address(dackie));
        assertEq(vault.DEPOSIT_START(), START);
        assertEq(vault.depositDeadline(), DEADLINE);
        assertEq(vault.MAX_DEPOSIT_DEADLINE(), MAX_DEADLINE);
        assertEq(vault.MIN_RATE_NOTICE(), RATE_NOTICE);
        assertEq(vault.RATE_CORRECTION_CUTOFF(), RATE_CUTOFF);
        assertEq(vault.MAX_DEPOSIT_ALLOCATION(), DEPOSIT_CAP);
        assertEq(vault.RELEASE_DELAY(), RELEASE_DELAY);
        assertEq(vault.SETTLEMENT_GRACE(), GRACE);
        assertEq(vault.settlementDeadline(), DEADLINE + GRACE);
        assertEq(uint8(vault.phase()), uint8(IMigrationVault.Phase.Pending));
    }

    function test_productionDepositCap_boundaryIsExactly4200000000() public {
        uint256 amount = 4_200_000_000e18;
        cap.mint(alice, amount);
        vm.warp(START);
        vm.prank(safe);
        vault.setRates(1e18, 1e18);

        vm.prank(alice);
        vault.deposit(capT, amount, alice);
        assertEq(vault.totalDepositAllocation(), amount);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMigrationVault.DepositCapExceeded.selector, 4_200_000_000e18 + 1, 4_200_000_000e18
            )
        );
        vault.deposit(capT, 1, alice);

        vm.prank(alice);
        vault.withdraw(capT, 1);
        vm.prank(bob);
        vault.deposit(capT, 1, bob);
        assertEq(vault.totalDepositAllocation(), amount);
    }

    function test_constructor_revertsOnBadConfig() public {
        IMigrationVault.InitParams memory p = _params();
        p.owner = address(0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new MigrationVault(p);

        p = _params();
        p.cap = IERC20(address(0));
        vm.expectRevert(IMigrationVault.ZeroAddress.selector);
        new MigrationVault(p);

        p = _params();
        p.dackie = p.cap;
        vm.expectRevert(IMigrationVault.InvalidConfig.selector);
        new MigrationVault(p);

        p = _params();
        p.dackie = IERC20(makeAddr("not a contract"));
        vm.expectRevert(IMigrationVault.InvalidConfig.selector);
        new MigrationVault(p);

        p = _params();
        p.minRateNotice = 7 days - 1;
        vm.expectRevert(IMigrationVault.InvalidConfig.selector);
        new MigrationVault(p);

        p = _params();
        p.releaseDelay = 12 hours - 1;
        vm.expectRevert(IMigrationVault.InvalidConfig.selector);
        new MigrationVault(p);

        // The grace must leave room to release after the delay.
        p = _params();
        p.settlementGrace = p.releaseDelay + 2 days - 1;
        vm.expectRevert(IMigrationVault.InvalidConfig.selector);
        new MigrationVault(p);

        p = _params();
        p.settlementGrace = 60 days + 1;
        vm.expectRevert(IMigrationVault.InvalidConfig.selector);
        new MigrationVault(p);

        // Window shorter than 14 days.
        p = _params();
        p.depositDeadline = p.depositStart + 14 days - 1;
        vm.expectRevert(IMigrationVault.InvalidConfig.selector);
        new MigrationVault(p);

        p = _params();
        p.maxDepositDeadline = p.depositDeadline - 1;
        vm.expectRevert(IMigrationVault.InvalidConfig.selector);
        new MigrationVault(p);

        p = _params();
        p.maxDepositDeadline = p.depositStart + 180 days + 1;
        vm.expectRevert(IMigrationVault.InvalidConfig.selector);
        new MigrationVault(p);

        // A vault that can take no deposit at all is a misconfiguration.
        p = _params();
        p.maxDepositAllocation = 0;
        vm.expectRevert(IMigrationVault.InvalidConfig.selector);
        new MigrationVault(p);
    }

    function test_constructor_windowMeasuredFromDeployWhenStartIsPast() public {
        // Deployed late: a deadline that leaves less than 14 real days must be rejected.
        vm.warp(DEADLINE - 14 days + 1);
        IMigrationVault.InitParams memory p = _params();
        vm.expectRevert(IMigrationVault.InvalidConfig.selector);
        new MigrationVault(p);
    }

    // ------------------------------------------------------------------
    // Deposit
    // ------------------------------------------------------------------

    function test_deposit_creditsAndRecordsRecipient() public {
        vm.warp(START);
        address recipient = makeAddr("alice on robinhood");

        vm.expectEmit(true, true, true, true);
        emit IMigrationVault.RecipientRegistered(alice, recipient);
        vm.expectEmit(true, true, true, true);
        emit IMigrationVault.Deposited(alice, address(cap), 400e18, recipient);
        vm.prank(alice);
        uint256 received = vault.deposit(capT, 400e18, recipient);

        assertEq(received, 400e18);
        assertEq(vault.depositOf(capT, alice), 400e18);
        assertEq(vault.totalDeposited(capT), 400e18);
        assertEq(vault.recipientOf(alice), recipient);
        assertEq(vault.effectiveRecipient(alice), recipient);
        assertEq(cap.balanceOf(address(vault)), 400e18);
        assertEq(uint8(vault.phase()), uint8(IMigrationVault.Phase.Open));
    }

    function test_deposit_bothTokensAccumulate() public {
        vm.warp(START);
        _deposit(alice, cap, 100e18);
        _deposit(alice, cap, 50e18);
        _deposit(alice, dackie, 70e18);
        _deposit(bob, cap, 1_000e18);

        assertEq(vault.depositOf(capT, alice), 150e18);
        assertEq(vault.depositOf(dackieT, alice), 70e18);
        assertEq(vault.totalDeposited(capT), 1_150e18);
        assertEq(vault.totalDeposited(dackieT), 70e18);
    }

    function test_deposit_laterDepositReplacesRecipient() public {
        vm.warp(START);
        address r1 = makeAddr("r1");
        address r2 = makeAddr("r2");
        vm.startPrank(alice);
        vault.deposit(capT, 1e18, r1);
        vault.deposit(dackieT, 1e18, r2);
        vm.stopPrank();
        assertEq(vault.recipientOf(alice), r2);
    }

    function test_deposit_revertsBeforeStart() public {
        vm.warp(START - 1);
        vm.prank(alice);
        vm.expectRevert(IMigrationVault.DepositsNotOpen.selector);
        vault.deposit(capT, 1e18, alice);
    }

    function test_deposit_worksAtDeadlineAndRevertsAfter() public {
        vm.warp(DEADLINE);
        _deposit(alice, cap, 1e18);

        vm.warp(DEADLINE + 1);
        vm.prank(alice);
        vm.expectRevert(IMigrationVault.DepositsNotOpen.selector);
        vault.deposit(capT, 1e18, alice);
    }

    function test_deposit_revertsOnZeroAmountZeroRecipientUnsupportedToken() public {
        vm.warp(START);
        vm.startPrank(alice);

        vm.expectRevert(IMigrationVault.ZeroAmount.selector);
        vault.deposit(capT, 0, alice);

        vm.expectRevert(IMigrationVault.ZeroAddress.selector);
        vault.deposit(capT, 1e18, address(0));

        MockERC20 other = new MockERC20("Other", "OTH");
        vm.expectRevert(abi.encodeWithSelector(IMigrationVault.UnsupportedToken.selector, address(other)));
        vault.deposit(IERC20(address(other)), 1e18, alice);

        vm.stopPrank();
    }

    function test_deposit_revertsWhenPaused_withdrawStillWorks() public {
        vm.warp(START);
        _deposit(alice, cap, 100e18);

        vm.prank(safe);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.deposit(capT, 1e18, alice);

        // Exits are never pausable.
        vm.prank(alice);
        vault.withdraw(capT, 100e18);
        assertEq(cap.balanceOf(alice), 1_000e18);

        vm.prank(safe);
        vault.unpause();
        _deposit(alice, cap, 1e18);
    }

    function test_deposit_plainTransferIsNotADeposit() public {
        vm.warp(START);
        vm.prank(alice);
        cap.transfer(address(vault), 100e18);

        assertEq(vault.depositOf(capT, alice), 0);
        assertEq(vault.totalDeposited(capT), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMigrationVault.InsufficientDeposit.selector, 100e18, 0));
        vault.withdraw(capT, 100e18);
    }

    // ------------------------------------------------------------------
    // Blocklist
    // ------------------------------------------------------------------

    function _block(address account) internal {
        address[] memory list = new address[](1);
        list[0] = account;
        vm.prank(safe);
        vault.setBlocked(list, true);
    }

    function test_blocklist_blocksDepositRegisterAndRecipient() public {
        vm.warp(START);
        _block(leaked);

        vm.startPrank(leaked);
        vm.expectRevert(abi.encodeWithSelector(IMigrationVault.AccountBlocked.selector, leaked));
        vault.deposit(capT, 1e18, makeAddr("attacker"));
        vm.expectRevert(abi.encodeWithSelector(IMigrationVault.AccountBlocked.selector, leaked));
        vault.registerRecipient(makeAddr("attacker"));
        vm.stopPrank();

        // A clean wallet cannot route its AGENTOS to a leaked address either.
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMigrationVault.AccountBlocked.selector, leaked));
        vault.deposit(capT, 1e18, leaked);
        vm.expectRevert(abi.encodeWithSelector(IMigrationVault.AccountBlocked.selector, leaked));
        vault.registerRecipient(leaked);
        vm.stopPrank();
    }

    function test_blocklist_blockedAccountCanStillWithdraw() public {
        vm.warp(START);
        _deposit(leaked, cap, 60e18);
        _block(leaked);

        vm.prank(leaked);
        vault.withdraw(capT, 60e18);
        assertEq(cap.balanceOf(leaked), 100e18);
    }

    function test_blocklist_batchAndUnblock() public {
        address[] memory list = new address[](3);
        list[0] = leaked;
        list[1] = stranger;
        list[2] = leaked; // duplicate is a no-op
        vm.prank(safe);
        vault.setBlocked(list, true);
        assertTrue(vault.isBlocked(leaked));
        assertTrue(vault.isBlocked(stranger));

        vm.prank(safe);
        vault.setBlocked(list, false);
        assertFalse(vault.isBlocked(leaked));

        vm.warp(START);
        _deposit(leaked, cap, 1e18);
    }

    function test_blocklist_onlyOwner() public {
        address[] memory list = new address[](1);
        list[0] = alice;
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setBlocked(list, true);
    }

    // ------------------------------------------------------------------
    // Recipient registry
    // ------------------------------------------------------------------

    function test_registerRecipient_worksBeforeStartWithoutDeposit() public {
        address recipient = makeAddr("long locker on robinhood");
        vm.prank(carol);
        vault.registerRecipient(recipient);
        assertEq(vault.recipientOf(carol), recipient);
        assertEq(vault.effectiveRecipient(carol), recipient);
        // Default for accounts that never registered: the same address.
        assertEq(vault.effectiveRecipient(stranger), stranger);
    }

    function test_registerRecipient_frozenAfterDeadline() public {
        vm.warp(DEADLINE);
        vm.prank(carol);
        vault.registerRecipient(carol);

        vm.warp(DEADLINE + 1);
        vm.prank(carol);
        vm.expectRevert(IMigrationVault.LedgerFrozen.selector);
        vault.registerRecipient(makeAddr("too late"));
    }

    function test_registerRecipient_revertsOnZeroAndAfterCancel() public {
        vm.prank(carol);
        vm.expectRevert(IMigrationVault.ZeroAddress.selector);
        vault.registerRecipient(address(0));

        vm.prank(safe);
        vault.cancel();
        vm.prank(carol);
        vm.expectRevert(IMigrationVault.MigrationCancelled.selector);
        vault.registerRecipient(carol);
    }

    // ------------------------------------------------------------------
    // Withdraw
    // ------------------------------------------------------------------

    function test_withdraw_partialAndFullDuringWindow() public {
        vm.warp(START);
        _deposit(alice, cap, 400e18);

        vm.expectEmit(true, true, true, true);
        emit IMigrationVault.Withdrawn(alice, address(cap), 150e18);
        vm.prank(alice);
        vault.withdraw(capT, 150e18);
        assertEq(vault.depositOf(capT, alice), 250e18);
        assertEq(vault.totalDeposited(capT), 250e18);

        vm.warp(DEADLINE); // last second
        vm.prank(alice);
        vault.withdraw(capT, 250e18);
        assertEq(vault.depositOf(capT, alice), 0);
        assertEq(cap.balanceOf(alice), 1_000e18);
        assertEq(cap.balanceOf(address(vault)), 0);
    }

    function test_withdraw_closedAfterDeadline() public {
        vm.warp(START);
        _deposit(alice, cap, 400e18);

        vm.warp(DEADLINE + 1);
        assertFalse(vault.withdrawalsOpen());
        assertEq(uint8(vault.phase()), uint8(IMigrationVault.Phase.Closed));
        vm.prank(alice);
        vm.expectRevert(IMigrationVault.WithdrawalsClosed.selector);
        vault.withdraw(capT, 1e18);
    }

    function test_withdraw_cannotTakeMoreThanOwnDeposit() public {
        vm.warp(START);
        _deposit(alice, cap, 100e18);
        _deposit(bob, cap, 2_000e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMigrationVault.InsufficientDeposit.selector, 101e18, 100e18));
        vault.withdraw(capT, 101e18);

        // No cross-token credit either.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IMigrationVault.InsufficientDeposit.selector, 1e18, 0));
        vault.withdraw(dackieT, 1e18);

        vm.prank(alice);
        vm.expectRevert(IMigrationVault.ZeroAmount.selector);
        vault.withdraw(capT, 0);
    }

    // ------------------------------------------------------------------
    // Rates
    // ------------------------------------------------------------------

    function test_setRates_onceAndWithNotice() public {
        vm.warp(DEADLINE - RATE_NOTICE); // last valid second
        vm.expectEmit(true, true, true, true);
        emit IMigrationVault.RatesSet(CAP_RATE, DACKIE_RATE);
        _setRates();
        assertTrue(vault.ratesSet());
        assertEq(vault.capRate(), CAP_RATE);
        assertEq(vault.dackieRate(), DACKIE_RATE);
    }

    function test_setRates_canBeCorrectedOnlyBeforeTheNoticeCutoff() public {
        vm.startPrank(safe);
        vault.setRates(DACKIE_RATE, CAP_RATE); // swapped by mistake
        vm.warp(DEADLINE - RATE_NOTICE);
        vault.setRates(CAP_RATE, DACKIE_RATE); // fixed at the last valid second
        assertEq(vault.capRate(), CAP_RATE);
        assertEq(vault.dackieRate(), DACKIE_RATE);

        // From here on the rates are final.
        vm.warp(RATE_CUTOFF + 1);
        vm.expectRevert(IMigrationVault.RatesFinal.selector);
        vault.setRates(1e18, 1e18);
        vm.warp(DEADLINE + 1);
        vm.expectRevert(IMigrationVault.RatesFinal.selector);
        vault.setRates(1e18, 1e18);
        vm.stopPrank();
        assertEq(vault.capRate(), CAP_RATE);
    }

    /// @dev The published "last correction" date (12-10) never moves. Extending the deadline after
    ///      it gives depositors more time, it does not give the owner a new correction window.
    function test_setRates_extensionAfterTheCutoffDoesNotReopenCorrections() public {
        _setRates();
        vm.warp(RATE_CUTOFF + 1);
        vm.startPrank(safe);
        vault.extendDeadline(MAX_DEADLINE);
        // The notice against the new deadline would be respected: it is still refused.
        assertGe(vault.depositDeadline() - block.timestamp, RATE_NOTICE);
        vm.expectRevert(IMigrationVault.RatesFinal.selector);
        vault.setRates(1e18, 1e18);
        vm.stopPrank();
        assertEq(vault.capRate(), CAP_RATE);
        assertEq(vault.dackieRate(), DACKIE_RATE);
    }

    /// @dev Extending early does not push the cutoff later either.
    function test_setRates_extensionBeforeTheCutoffDoesNotMoveIt() public {
        vm.warp(START);
        vm.startPrank(safe);
        vault.setRates(DACKIE_RATE, CAP_RATE); // swapped by mistake
        vault.extendDeadline(MAX_DEADLINE);
        assertEq(vault.RATE_CORRECTION_CUTOFF(), RATE_CUTOFF);

        vm.warp(RATE_CUTOFF);
        vault.setRates(CAP_RATE, DACKIE_RATE); // last valid second, as published
        vm.warp(RATE_CUTOFF + 1);
        vm.expectRevert(IMigrationVault.RatesFinal.selector);
        vault.setRates(1e18, 1e18);
        vm.stopPrank();
        assertEq(vault.capRate(), CAP_RATE);
    }

    /// @dev Rates that are set for the first time after the cutoff (deadline extended first) get no
    ///      correction window: they are final the moment they are set.
    function test_setRates_firstSetAfterTheCutoffIsFinalAtOnce() public {
        vm.warp(RATE_CUTOFF + 1);
        vm.startPrank(safe);
        vault.extendDeadline(MAX_DEADLINE);
        vault.setRates(CAP_RATE, DACKIE_RATE);
        vm.expectRevert(IMigrationVault.RatesFinal.selector);
        vault.setRates(CAP_RATE, DACKIE_RATE + 1);
        vm.stopPrank();
    }

    function test_setRates_revertsWhenNoticeTooShort() public {
        vm.warp(DEADLINE - RATE_NOTICE + 1);
        vm.prank(safe);
        vm.expectRevert(IMigrationVault.RateNoticeTooShort.selector);
        vault.setRates(CAP_RATE, DACKIE_RATE);
    }

    function test_setRates_lateRatesNeedADeadlineExtension() public {
        vm.warp(DEADLINE - 10 days);
        vm.startPrank(safe);
        vm.expectRevert(IMigrationVault.RateNoticeTooShort.selector);
        vault.setRates(CAP_RATE, DACKIE_RATE);

        vault.extendDeadline(uint64(block.timestamp) + RATE_NOTICE);
        vault.setRates(CAP_RATE, DACKIE_RATE);
        vm.stopPrank();
        assertEq(vault.depositDeadline(), DEADLINE + 5 days);
    }

    function test_setRates_revertsOnBadValuesAndNonOwner() public {
        vm.startPrank(safe);
        vm.expectRevert(IMigrationVault.InvalidRate.selector);
        vault.setRates(0, DACKIE_RATE);
        vm.expectRevert(IMigrationVault.InvalidRate.selector);
        vault.setRates(CAP_RATE, 0);
        vm.expectRevert(IMigrationVault.InvalidRate.selector);
        vault.setRates(1_000_000e18 + 1, DACKIE_RATE);
        // Unit mistake: 25 instead of 25e18.
        vm.expectRevert(IMigrationVault.InvalidRate.selector);
        vault.setRates(25, 18);
        vm.expectRevert(IMigrationVault.InvalidRate.selector);
        vault.setRates(CAP_RATE, 1e15 - 1);
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setRates(CAP_RATE, DACKIE_RATE);
    }

    // ------------------------------------------------------------------
    // Deposit cap
    // ------------------------------------------------------------------

    /// @dev A vault that can take 100 CAP worth of AGENTOS at the test rate (2,550 AGENTOS).
    function _smallCapVault() internal returns (MigrationVault v) {
        IMigrationVault.InitParams memory p = _params();
        p.maxDepositAllocation = 100 * CAP_RATE;
        v = new MigrationVault(p);
        address[2] memory users = [alice, bob];
        for (uint256 i; i < users.length; ++i) {
            vm.startPrank(users[i]);
            cap.approve(address(v), type(uint256).max);
            dackie.approve(address(v), type(uint256).max);
            vm.stopPrank();
        }
    }

    function test_depositCap_refusesWhatDoesNotFitTheBudget() public {
        MigrationVault v = _smallCapVault();
        vm.warp(START);
        vm.prank(safe);
        v.setRates(CAP_RATE, DACKIE_RATE);

        vm.prank(alice);
        v.deposit(capT, 100e18, alice); // exactly the cap
        assertEq(v.totalDepositAllocation(), v.MAX_DEPOSIT_ALLOCATION());

        // One more token of either kind does not fit, whoever sends it.
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IMigrationVault.DepositCapExceeded.selector, 101 * CAP_RATE, 100 * CAP_RATE)
        );
        v.deposit(capT, 1e18, bob);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMigrationVault.DepositCapExceeded.selector, 100 * CAP_RATE + DACKIE_RATE, 100 * CAP_RATE
            )
        );
        v.deposit(dackieT, 1e18, alice);
        assertEq(v.totalDeposited(capT), 100e18);
        assertEq(v.totalDeposited(dackieT), 0);
    }

    /// @dev The cap never traps anyone: a withdrawal always works and frees room for someone else.
    function test_depositCap_withdrawalFreesRoom() public {
        MigrationVault v = _smallCapVault();
        vm.warp(START);
        vm.prank(safe);
        v.setRates(CAP_RATE, DACKIE_RATE);
        vm.prank(alice);
        v.deposit(capT, 100e18, alice);

        vm.prank(alice);
        v.withdraw(capT, 10e18);
        vm.prank(bob);
        v.deposit(capT, 10e18, bob);
        assertEq(v.totalDepositAllocation(), 100 * CAP_RATE);
    }

    /// @dev Before the rates are set an allocation is not known, so nothing is refused. Once they are
    ///      set, a vault that is already over the cap takes no new deposit until room is freed.
    function test_depositCap_appliesFromTheMomentRatesAreSet() public {
        MigrationVault v = _smallCapVault();
        vm.warp(START);
        vm.prank(alice);
        v.deposit(capT, 500e18, alice); // 5x the cap, rates not set yet

        vm.prank(safe);
        v.setRates(CAP_RATE, DACKIE_RATE); // setting the rates is never blocked by the cap
        assertGt(v.totalDepositAllocation(), v.MAX_DEPOSIT_ALLOCATION());

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IMigrationVault.DepositCapExceeded.selector, 500 * CAP_RATE + 25, 100 * CAP_RATE)
        );
        v.deposit(capT, 1, bob);

        // Depositors can always leave.
        vm.prank(alice);
        v.withdraw(capT, 500e18);
        vm.prank(bob);
        v.deposit(capT, 100e18, bob);
    }

    function test_allocationViews() public {
        vm.warp(START);
        _deposit(alice, cap, 100e18);
        _deposit(alice, dackie, 10e18);
        assertEq(vault.allocationOf(alice), 0); // no rates yet
        _setRates();
        assertEq(vault.allocationOf(alice), 100 * 25.5e18 + 10 * 18.5e18);
        assertEq(vault.totalDepositAllocation(), 100 * 25.5e18 + 10 * 18.5e18);
    }

    // ------------------------------------------------------------------
    // Deadline extension
    // ------------------------------------------------------------------

    function test_extendDeadline_bounds() public {
        vm.startPrank(safe);
        vm.expectRevert(IMigrationVault.InvalidDeadline.selector);
        vault.extendDeadline(DEADLINE); // not later
        vm.expectRevert(IMigrationVault.InvalidDeadline.selector);
        vault.extendDeadline(MAX_DEADLINE + 1);

        vm.expectEmit(true, true, true, true);
        emit IMigrationVault.DeadlineExtended(DEADLINE, MAX_DEADLINE);
        vault.extendDeadline(MAX_DEADLINE);
        vm.stopPrank();

        assertEq(vault.depositDeadline(), MAX_DEADLINE);
        assertEq(vault.settlementDeadline(), MAX_DEADLINE + GRACE);
    }

    function test_extendDeadline_cannotReopenAClosedWindow() public {
        vm.warp(DEADLINE + 1);
        vm.prank(safe);
        vm.expectRevert(IMigrationVault.LedgerFrozen.selector);
        vault.extendDeadline(DEADLINE + 7 days);
    }

    function test_extendDeadline_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.extendDeadline(DEADLINE + 1 days);
    }

    // ------------------------------------------------------------------
    // Root attestation + release
    // ------------------------------------------------------------------

    function test_attest_revertsWhileWindowOpen() public {
        _setRates();
        vm.warp(DEADLINE);
        vm.prank(safe);
        vm.expectRevert(IMigrationVault.WindowStillOpen.selector);
        vault.attestClaimRoot(ROOT, ATTESTED_TOTAL, ATTESTED_DISTRIBUTOR);
    }

    function test_attest_revertsWithoutRatesOrRoot() public {
        vm.warp(DEADLINE + 1);
        vm.prank(safe);
        vm.expectRevert(IMigrationVault.RatesNotSet.selector);
        vault.attestClaimRoot(ROOT, ATTESTED_TOTAL, ATTESTED_DISTRIBUTOR);
    }

    function test_attest_revertsOnZeroRootAndNonOwner() public {
        _setRates();
        vm.warp(DEADLINE + 1);
        vm.startPrank(safe);
        vm.expectRevert(IMigrationVault.InvalidRoot.selector);
        vault.attestClaimRoot(bytes32(0), ATTESTED_TOTAL, ATTESTED_DISTRIBUTOR);
        vm.expectRevert(IMigrationVault.ZeroAmount.selector);
        vault.attestClaimRoot(ROOT, 0, ATTESTED_DISTRIBUTOR);
        vm.expectRevert(IMigrationVault.ZeroAddress.selector);
        vault.attestClaimRoot(ROOT, ATTESTED_TOTAL, address(0));
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.attestClaimRoot(ROOT, ATTESTED_TOTAL, ATTESTED_DISTRIBUTOR);
    }

    function test_attest_revertsWhenTooLateToRelease() public {
        _setRates();
        vm.warp(DEADLINE + GRACE - RELEASE_DELAY + 1);
        vm.prank(safe);
        vm.expectRevert(IMigrationVault.SettlementWindowOver.selector);
        vault.attestClaimRoot(ROOT, ATTESTED_TOTAL, ATTESTED_DISTRIBUTOR);
    }

    function test_release_needsAttestationAndDelay() public {
        vm.warp(START);
        _deposit(alice, cap, 400e18);
        _deposit(alice, dackie, 300e18);
        _deposit(bob, cap, 2_000e18);
        _setRates();

        vm.warp(DEADLINE + 1);
        vm.startPrank(safe);
        vm.expectRevert(IMigrationVault.RootNotAttested.selector);
        vault.release();

        vm.expectEmit(true, true, true, true);
        emit IMigrationVault.ClaimRootAttested(
            ROOT, ATTESTED_TOTAL, ATTESTED_DISTRIBUTOR, uint64(block.timestamp) + RELEASE_DELAY
        );
        vault.attestClaimRoot(ROOT, ATTESTED_TOTAL, ATTESTED_DISTRIBUTOR);
        assertEq(uint8(vault.phase()), uint8(IMigrationVault.Phase.RootAttested));
        uint64 at = vault.releasableAt();
        assertEq(at, DEADLINE + 1 + RELEASE_DELAY);

        vm.warp(at - 1);
        vm.expectRevert(abi.encodeWithSelector(IMigrationVault.ReleaseDelayNotElapsed.selector, at));
        vault.release();

        vm.warp(at);
        vm.expectEmit(true, true, true, true);
        emit IMigrationVault.Released(safe, 2_400e18, 300e18);
        vault.release();
        vm.stopPrank();

        assertTrue(vault.released());
        assertEq(uint8(vault.phase()), uint8(IMigrationVault.Phase.Released));
        assertEq(cap.balanceOf(safe), 2_400e18);
        assertEq(dackie.balanceOf(safe), 300e18);
        assertEq(cap.balanceOf(address(vault)), 0);
        assertEq(dackie.balanceOf(address(vault)), 0);
        // The ledger stays readable for the claim tree.
        assertEq(vault.depositOf(capT, alice), 400e18);
        assertEq(vault.totalDeposited(capT), 2_400e18);
    }

    function test_release_reattestRestartsTheDelay() public {
        vm.warp(START);
        _deposit(alice, cap, 400e18);
        _toReleasable();

        bytes32 fixedRoot = keccak256("fixed root");
        vm.startPrank(safe);
        vault.attestClaimRoot(fixedRoot, ATTESTED_TOTAL + 1, ATTESTED_DISTRIBUTOR);
        uint64 at = vault.releasableAt();
        assertEq(at, uint64(block.timestamp) + RELEASE_DELAY);
        vm.expectRevert(abi.encodeWithSelector(IMigrationVault.ReleaseDelayNotElapsed.selector, at));
        vault.release();
        vm.stopPrank();
        assertEq(vault.claimRoot(), fixedRoot);
        assertEq(vault.attestedTotalAllocation(), ATTESTED_TOTAL + 1);
        assertEq(vault.attestedDistributor(), ATTESTED_DISTRIBUTOR);
    }

    function test_release_onlyOwnerAndOnlyOnce() public {
        vm.warp(START);
        _deposit(alice, cap, 400e18);
        _toReleasable();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.release();

        vm.startPrank(safe);
        vault.release();
        vm.expectRevert(IMigrationVault.AlreadyReleased.selector);
        vault.release();
        vm.expectRevert(IMigrationVault.AlreadyReleased.selector);
        vault.attestClaimRoot(ROOT, ATTESTED_TOTAL, ATTESTED_DISTRIBUTOR);
        vm.expectRevert(IMigrationVault.AlreadyReleased.selector);
        vault.cancel();
        vm.stopPrank();
    }

    function test_release_closesEveryExit() public {
        vm.warp(START);
        _deposit(alice, cap, 400e18);
        _toReleasable();
        vm.prank(safe);
        vault.release();

        vm.prank(alice);
        vm.expectRevert(IMigrationVault.WithdrawalsClosed.selector);
        vault.withdraw(capT, 400e18);
        vm.expectRevert(IMigrationVault.NotRefunding.selector);
        vault.refund(alice);

        // Even long after the settlement deadline.
        vm.warp(DEADLINE + GRACE + 365 days);
        assertFalse(vault.withdrawalsOpen());
        vm.prank(alice);
        vm.expectRevert(IMigrationVault.WithdrawalsClosed.selector);
        vault.withdraw(capT, 400e18);
        vm.expectRevert(IMigrationVault.NotRefunding.selector);
        vault.refund(alice);
    }

    function test_release_goesToTheCurrentOwner() public {
        address newSafe = makeAddr("new safe");
        vm.prank(safe);
        vault.transferOwnership(newSafe);
        vm.prank(newSafe);
        vault.acceptOwnership();

        vm.warp(START);
        _deposit(alice, cap, 400e18);
        vm.prank(newSafe);
        vault.setRates(CAP_RATE, DACKIE_RATE);
        vm.warp(DEADLINE + 1);
        vm.startPrank(newSafe);
        vault.attestClaimRoot(ROOT, ATTESTED_TOTAL, ATTESTED_DISTRIBUTOR);
        vm.warp(block.timestamp + RELEASE_DELAY);
        vault.release();
        vm.stopPrank();
        assertEq(cap.balanceOf(newSafe), 400e18);
        assertEq(cap.balanceOf(safe), 0);
    }

    // ------------------------------------------------------------------
    // Timeout refund (owner never releases)
    // ------------------------------------------------------------------

    function test_timeout_refundsOpenWhenOwnerNeverReleases() public {
        vm.warp(START);
        _deposit(alice, cap, 400e18);
        _deposit(alice, dackie, 300e18);
        _deposit(bob, cap, 2_000e18);

        // Last second of the settlement window: still locked.
        vm.warp(DEADLINE + GRACE);
        assertFalse(vault.withdrawalsOpen());

        vm.warp(DEADLINE + GRACE + 1);
        assertTrue(vault.withdrawalsOpen());
        assertEq(uint8(vault.phase()), uint8(IMigrationVault.Phase.Refunding));

        vm.prank(alice);
        vault.withdraw(capT, 400e18);
        // Anyone can push the rest.
        vm.prank(stranger);
        vault.refund(alice);
        vm.prank(stranger);
        vault.refund(bob);

        assertEq(cap.balanceOf(alice), 1_000e18);
        assertEq(dackie.balanceOf(alice), 500e18);
        assertEq(cap.balanceOf(bob), 2_000e18);
        assertEq(cap.balanceOf(address(vault)), 0);
        assertEq(vault.totalDeposited(capT), 0);
        assertEq(vault.totalDeposited(dackieT), 0);
    }

    function test_timeout_ownerCannotReleaseOrAttestAfterIt() public {
        vm.warp(START);
        _deposit(alice, cap, 400e18);
        _toReleasable();

        vm.warp(DEADLINE + GRACE + 1);
        vm.startPrank(safe);
        vm.expectRevert(IMigrationVault.SettlementWindowOver.selector);
        vault.release();
        vm.expectRevert(IMigrationVault.SettlementWindowOver.selector);
        vault.attestClaimRoot(ROOT, ATTESTED_TOTAL, ATTESTED_DISTRIBUTOR);
        vm.stopPrank();

        vm.prank(alice);
        vault.withdraw(capT, 400e18);
        assertEq(cap.balanceOf(alice), 1_000e18);
    }

    function test_timeout_releaseWorksAtTheLastSecond() public {
        vm.warp(START);
        _deposit(alice, cap, 400e18);
        _toReleasable();

        vm.warp(DEADLINE + GRACE);
        vm.prank(safe);
        vault.release();
        assertEq(cap.balanceOf(safe), 400e18);
    }

    // ------------------------------------------------------------------
    // Cancel
    // ------------------------------------------------------------------

    function test_cancel_duringWindow_stopsDepositsOpensRefunds() public {
        vm.warp(START);
        _deposit(alice, cap, 400e18);

        vm.expectEmit(true, true, true, true);
        emit IMigrationVault.Cancelled(safe);
        vm.prank(safe);
        vault.cancel();
        assertEq(uint8(vault.phase()), uint8(IMigrationVault.Phase.Refunding));

        vm.prank(alice);
        vm.expectRevert(IMigrationVault.DepositsNotOpen.selector);
        vault.deposit(capT, 1e18, alice);

        // Refunds stay open for ever.
        vm.warp(DEADLINE + 3650 days);
        vm.prank(alice);
        vault.withdraw(capT, 400e18);
        assertEq(cap.balanceOf(alice), 1_000e18);
    }

    function test_cancel_afterCloseAndAfterAttestation() public {
        vm.warp(START);
        _deposit(alice, cap, 400e18);
        _deposit(alice, dackie, 100e18);
        _toReleasable();

        vm.startPrank(safe);
        vault.cancel();
        vm.expectRevert(IMigrationVault.MigrationCancelled.selector);
        vault.release();
        vm.expectRevert(IMigrationVault.MigrationCancelled.selector);
        vault.attestClaimRoot(ROOT, ATTESTED_TOTAL, ATTESTED_DISTRIBUTOR);
        vm.expectRevert(IMigrationVault.MigrationCancelled.selector);
        vault.cancel();
        vm.expectRevert(IMigrationVault.MigrationCancelled.selector);
        vault.extendDeadline(MAX_DEADLINE);
        vm.stopPrank();

        vm.expectEmit(true, true, true, true);
        emit IMigrationVault.Refunded(alice, address(cap), 400e18, stranger);
        vm.expectEmit(true, true, true, true);
        emit IMigrationVault.Refunded(alice, address(dackie), 100e18, stranger);
        vm.prank(stranger);
        vault.refund(alice);
        assertEq(cap.balanceOf(alice), 1_000e18);
        assertEq(dackie.balanceOf(alice), 500e18);
    }

    function test_cancel_notByStrangers() public {
        vm.prank(stranger);
        vm.expectRevert(IMigrationVault.NotAuthorized.selector);
        vault.cancel();
    }

    // ------------------------------------------------------------------
    // Guardian veto
    // ------------------------------------------------------------------

    function test_guardian_canVetoOnlyBetweenAttestationAndRelease() public {
        assertEq(vault.GUARDIAN(), guardian);
        vm.warp(START);
        _deposit(alice, cap, 400e18);

        // Window open: no power.
        vm.prank(guardian);
        vm.expectRevert(IMigrationVault.WindowStillOpen.selector);
        vault.cancel();

        // Closed, nothing attested: no power.
        _setRates();
        vm.warp(DEADLINE + 1);
        vm.prank(guardian);
        vm.expectRevert(IMigrationVault.RootNotAttested.selector);
        vault.cancel();

        // Root attested: veto. Depositors get their tokens back, the owner cannot release.
        vm.prank(safe);
        vault.attestClaimRoot(ROOT, ATTESTED_TOTAL, ATTESTED_DISTRIBUTOR);
        vm.expectEmit(true, true, true, true);
        emit IMigrationVault.Cancelled(guardian);
        vm.prank(guardian);
        vault.cancel();

        vm.warp(block.timestamp + RELEASE_DELAY);
        vm.prank(safe);
        vm.expectRevert(IMigrationVault.MigrationCancelled.selector);
        vault.release();
        vault.refund(alice);
        assertEq(cap.balanceOf(alice), 1_000e18);
    }

    function test_guardian_hasNoOtherPower() public {
        vm.warp(START);
        _deposit(alice, cap, 400e18);
        address[] memory list = new address[](1);
        list[0] = alice;

        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.setBlocked(list, true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.setRates(CAP_RATE, DACKIE_RATE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.pause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.rescue(capT, guardian, 1);
        vm.stopPrank();

        _toReleasable();
        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.release();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.attestClaimRoot(ROOT, ATTESTED_TOTAL, ATTESTED_DISTRIBUTOR);
        vm.stopPrank();
    }

    function test_guardian_cannotCancelAfterReleaseOrAfterTimeout() public {
        vm.warp(START);
        _deposit(alice, cap, 400e18);
        _toReleasable();

        uint256 snap = vm.snapshotState();
        vm.prank(safe);
        vault.release();
        vm.prank(guardian);
        vm.expectRevert(IMigrationVault.AlreadyReleased.selector);
        vault.cancel();

        vm.revertToState(snap);
        vm.warp(DEADLINE + GRACE + 1); // already refunding by timeout
        vm.prank(guardian);
        vm.expectRevert(IMigrationVault.SettlementWindowOver.selector);
        vault.cancel();
    }

    function test_guardian_optionalAndNeverTheOwner() public {
        IMigrationVault.InitParams memory p = _params();
        p.guardian = address(0);
        MigrationVault v = new MigrationVault(p);
        assertEq(v.GUARDIAN(), address(0));

        p.guardian = p.owner;
        vm.expectRevert(IMigrationVault.InvalidConfig.selector);
        new MigrationVault(p);
    }

    // ------------------------------------------------------------------
    // Boundaries the audit asked for
    // ------------------------------------------------------------------

    function test_attest_worksAtTheLastUsefulSecond() public {
        vm.warp(START);
        _deposit(alice, cap, 400e18);
        _setRates();
        vm.warp(DEADLINE + GRACE - RELEASE_DELAY); // release lands exactly on the settlement deadline
        vm.startPrank(safe);
        vault.attestClaimRoot(ROOT, ATTESTED_TOTAL, ATTESTED_DISTRIBUTOR);
        vm.warp(DEADLINE + GRACE);
        vault.release();
        vm.stopPrank();
        assertEq(cap.balanceOf(safe), 400e18);
    }

    function test_extendDeadline_atTheLastSecondAndAfterRates() public {
        _setRates();
        vm.warp(DEADLINE);
        vm.prank(safe);
        vault.extendDeadline(DEADLINE + 3 days);
        // Rates stay as set, the window simply stays open longer.
        assertEq(vault.capRate(), CAP_RATE);
        vm.warp(DEADLINE + 3 days);
        _deposit(alice, cap, 1e18);
        vm.prank(alice);
        vault.withdraw(capT, 1e18);
    }

    function test_blocklist_afterDepositAndRegistration_exitsStillWork() public {
        vm.warp(START);
        vm.prank(alice);
        vault.deposit(capT, 100e18, leaked); // names an address that gets blocked later
        _deposit(leaked, cap, 60e18);
        _block(leaked);

        // The stale recipient stays on the ledger: the tree builder must exclude it.
        assertEq(vault.recipientOf(alice), leaked);
        assertTrue(vault.isBlocked(vault.effectiveRecipient(alice)));

        // Alice can repoint, a blocked depositor can still be refunded.
        vm.prank(alice);
        vault.registerRecipient(alice);
        vm.prank(safe);
        vault.cancel();
        vault.refund(leaked);
        vault.refund(alice);
        assertEq(cap.balanceOf(leaked), 100e18);
        assertEq(cap.balanceOf(alice), 1_000e18);
    }

    function test_cancel_blocksLateRates() public {
        vm.startPrank(safe);
        vault.cancel();
        vm.expectRevert(IMigrationVault.MigrationCancelled.selector);
        vault.setRates(CAP_RATE, DACKIE_RATE);
        vm.stopPrank();
    }

    function test_refund_onlyInRefundModeAndOnlyOnce() public {
        vm.warp(START);
        _deposit(alice, cap, 400e18);

        vm.expectRevert(IMigrationVault.NotRefunding.selector);
        vault.refund(alice); // window open: only the owner of the deposit may move it

        vm.warp(DEADLINE + 1);
        vm.expectRevert(IMigrationVault.NotRefunding.selector);
        vault.refund(alice);

        vm.prank(safe);
        vault.cancel();
        vault.refund(alice);
        vm.expectRevert(IMigrationVault.ZeroAmount.selector);
        vault.refund(alice);
        assertEq(cap.balanceOf(alice), 1_000e18);
    }

    // ------------------------------------------------------------------
    // Rescue
    // ------------------------------------------------------------------

    function test_rescue_onlyExcessOfMigrationTokens() public {
        vm.warp(START);
        _deposit(alice, cap, 400e18);
        cap.mint(address(vault), 7e18); // stray transfer

        assertEq(vault.excessOf(capT), 7e18);
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(IMigrationVault.InsufficientExcess.selector, 7e18 + 1, 7e18));
        vault.rescue(capT, safe, 7e18 + 1);

        vault.rescue(capT, safe, 7e18);
        vm.stopPrank();
        assertEq(cap.balanceOf(safe), 7e18);
        assertEq(cap.balanceOf(address(vault)), 400e18);

        // Deposits are untouched and still fully withdrawable.
        vm.prank(alice);
        vault.withdraw(capT, 400e18);
    }

    function test_rescue_cannotTouchDepositsEvenInRefundMode() public {
        vm.warp(START);
        _deposit(alice, cap, 400e18);
        vm.prank(safe);
        vault.cancel();

        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(IMigrationVault.InsufficientExcess.selector, 1, 0));
        vault.rescue(capT, safe, 1);
    }

    function test_rescue_otherTokensAndAfterRelease() public {
        MockERC20 other = new MockERC20("Other", "OTH");
        other.mint(address(vault), 5e18);
        vm.prank(safe);
        vault.rescue(IERC20(address(other)), safe, 5e18);
        assertEq(other.balanceOf(safe), 5e18);

        vm.warp(START);
        _deposit(alice, cap, 400e18);
        _toReleasable();
        vm.prank(safe);
        vault.release();
        cap.mint(address(vault), 3e18); // arrives after release
        vm.prank(safe);
        vault.rescue(capT, safe, 3e18);
        assertEq(cap.balanceOf(safe), 403e18);
    }

    function test_rescue_guards() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.rescue(capT, stranger, 1);

        vm.startPrank(safe);
        vm.expectRevert(IMigrationVault.ZeroAddress.selector);
        vault.rescue(capT, address(0), 1);
        vm.expectRevert(IMigrationVault.ZeroAmount.selector);
        vault.rescue(capT, safe, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Ownership
    // ------------------------------------------------------------------

    function test_ownership_twoStepAndNoRenounce() public {
        address newSafe = makeAddr("new safe");
        vm.prank(safe);
        vault.transferOwnership(newSafe);
        assertEq(vault.owner(), safe); // not until accepted
        assertEq(vault.pendingOwner(), newSafe);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.acceptOwnership();

        vm.prank(newSafe);
        vault.acceptOwnership();
        assertEq(vault.owner(), newSafe);

        vm.prank(newSafe);
        vm.expectRevert(IMigrationVault.RenounceDisabled.selector);
        vault.renounceOwnership();
    }

    function test_pause_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.pause();
    }

    function test_rejectsEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ------------------------------------------------------------------
    // Non-standard tokens
    // ------------------------------------------------------------------

    function _vaultWith(IERC20 capLike) internal returns (MigrationVault v) {
        IMigrationVault.InitParams memory p = _params();
        p.cap = capLike;
        v = new MigrationVault(p);
    }

    function test_feeOnTransfer_creditsOnlyWhatArrived() public {
        MockTaxERC20 taxed = new MockTaxERC20("Taxed CAP", "tCAP", 100); // 1%
        MigrationVault v = _vaultWith(IERC20(address(taxed)));
        taxed.mint(alice, 1_000e18);
        taxed.mint(bob, 1_000e18);
        vm.prank(alice);
        taxed.approve(address(v), type(uint256).max);
        vm.prank(bob);
        taxed.approve(address(v), type(uint256).max);

        vm.warp(START);
        vm.prank(alice);
        uint256 received = v.deposit(IERC20(address(taxed)), 1_000e18, alice);
        vm.prank(bob);
        v.deposit(IERC20(address(taxed)), 1_000e18, bob);

        assertEq(received, 990e18);
        assertEq(v.depositOf(IERC20(address(taxed)), alice), 990e18);
        assertEq(v.totalDeposited(IERC20(address(taxed))), 1_980e18);
        // Solvent: the vault holds exactly what it owes, so the last withdrawer is not short.
        assertEq(taxed.balanceOf(address(v)), 1_980e18);

        vm.prank(alice);
        v.withdraw(IERC20(address(taxed)), 990e18);
        vm.prank(bob);
        v.withdraw(IERC20(address(taxed)), 990e18);
        assertEq(taxed.balanceOf(address(v)), 0);
    }

    function test_feeOnTransfer_fullTaxRevertsInsteadOfCreditingZero() public {
        MockTaxERC20 taxed = new MockTaxERC20("Taxed CAP", "tCAP", 10_000); // 100%
        MigrationVault v = _vaultWith(IERC20(address(taxed)));
        taxed.mint(alice, 1_000e18);
        vm.startPrank(alice);
        taxed.approve(address(v), type(uint256).max);
        vm.warp(START);
        vm.expectRevert(IMigrationVault.NothingReceived.selector);
        v.deposit(IERC20(address(taxed)), 1_000e18, alice);
        vm.stopPrank();
    }

    function test_reentrancy_tokenCannotReenterDuringDeposit() public {
        ReentrantERC20 evil = new ReentrantERC20();
        MigrationVault v = _vaultWith(IERC20(address(evil)));
        evil.mint(alice, 1_000e18);
        vm.prank(alice);
        evil.approve(address(v), type(uint256).max);
        vm.warp(START);
        vm.prank(alice);
        v.deposit(IERC20(address(evil)), 500e18, alice);

        bytes[] memory attacks = new bytes[](3);
        attacks[0] = abi.encodeCall(v.withdraw, (IERC20(address(evil)), 1));
        attacks[1] = abi.encodeCall(v.deposit, (IERC20(address(evil)), 1, alice));
        attacks[2] = abi.encodeCall(v.refund, (alice));

        for (uint256 i; i < attacks.length; ++i) {
            evil.arm(address(v), attacks[i]);
            vm.prank(alice);
            vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            v.deposit(IERC20(address(evil)), 100e18, alice);
        }
        evil.disarm();
        assertEq(v.depositOf(IERC20(address(evil)), alice), 500e18);
    }

    function test_reentrancy_tokenCannotReenterDuringWithdrawOrRefund() public {
        ReentrantERC20 evil = new ReentrantERC20();
        MigrationVault v = _vaultWith(IERC20(address(evil)));
        evil.mint(alice, 1_000e18);
        vm.prank(alice);
        evil.approve(address(v), type(uint256).max);
        vm.warp(START);
        vm.prank(alice);
        v.deposit(IERC20(address(evil)), 500e18, alice);

        evil.arm(address(v), abi.encodeCall(v.withdraw, (IERC20(address(evil)), 1)));
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        v.withdraw(IERC20(address(evil)), 100e18);

        vm.prank(safe);
        v.cancel();
        evil.arm(address(v), abi.encodeCall(v.refund, (alice)));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        v.refund(alice);

        evil.disarm();
        v.refund(alice);
        assertEq(evil.balanceOf(alice), 1_000e18);
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    function testFuzz_depositThenWithdraw_returnsExactly(uint256 depositAmount, uint256 withdrawAmount, uint256 when)
        public
    {
        depositAmount = bound(depositAmount, 1, 1_000e18);
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);
        when = bound(when, START, DEADLINE);

        vm.warp(when);
        _deposit(alice, cap, depositAmount);
        vm.prank(alice);
        vault.withdraw(capT, withdrawAmount);

        assertEq(vault.depositOf(capT, alice), depositAmount - withdrawAmount);
        assertEq(vault.totalDeposited(capT), depositAmount - withdrawAmount);
        assertEq(cap.balanceOf(alice), 1_000e18 - depositAmount + withdrawAmount);
        assertEq(cap.balanceOf(address(vault)), depositAmount - withdrawAmount);
    }

    /// @dev At any time, exactly one of "user can exit" / "owner can still release" holds once the
    ///      window is closed, and the user can always exit while it is open.
    function testFuzz_exitAndReleaseAreMutuallyExclusive(uint256 when, bool attest) public {
        when = bound(when, START, DEADLINE + GRACE + 30 days);
        vm.warp(START);
        _deposit(alice, cap, 400e18);
        _setRates();

        if (attest && when > DEADLINE + 1 + RELEASE_DELAY && when <= DEADLINE + GRACE) {
            vm.warp(DEADLINE + 1);
            vm.prank(safe);
            vault.attestClaimRoot(ROOT, ATTESTED_TOTAL, ATTESTED_DISTRIBUTOR);
        }
        vm.warp(when);

        bool canExit = vault.withdrawalsOpen();
        vm.prank(safe);
        (bool canRelease,) = address(vault).call(abi.encodeCall(vault.release, ()));

        if (when <= DEADLINE) {
            assertTrue(canExit);
            assertFalse(canRelease);
        } else if (when > DEADLINE + GRACE) {
            assertTrue(canExit);
            assertFalse(canRelease);
        } else {
            assertFalse(canExit && canRelease);
        }
    }
}
