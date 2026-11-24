// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MigrationVault} from "@migration/MigrationVault.sol";
import {IMigrationVault} from "@migration/interfaces/IMigrationVault.sol";

import {VaultFixture} from "../helpers/VaultFixture.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

/// @notice Drives the vault with random users, a random owner and random time jumps.
contract VaultHandler is Test {
    MigrationVault internal immutable vault;
    MockERC20 internal immutable cap;
    MockERC20 internal immutable dackie;
    address internal immutable safe;
    address internal immutable guardian;

    address[] public actors;
    uint256 public constant INITIAL = 1_000_000e18;

    // Ghost state
    uint256 public releasedCap;
    uint256 public releasedDackie;
    uint256 public strayCap; // total ever sent to the vault without depositing
    bool public exitWasOpenAfterRelease;
    bool public guardianCancelledOutsideWindow;
    bool public depositWentAboveCap;
    bool public ratesChangedAfterCutoff;

    constructor(MigrationVault vault_, MockERC20 cap_, MockERC20 dackie_, address safe_, address guardian_) {
        guardian = guardian_;
        vault = vault_;
        cap = cap_;
        dackie = dackie_;
        safe = safe_;
        for (uint256 i; i < 5; ++i) {
            address actor = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(actor);
            cap.mint(actor, INITIAL);
            dackie.mint(actor, INITIAL);
            vm.startPrank(actor);
            cap.approve(address(vault), type(uint256).max);
            dackie.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _token(uint256 seed) internal view returns (MockERC20) {
        return seed % 2 == 0 ? cap : dackie;
    }

    function deposit(uint256 actorSeed, uint256 tokenSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        MockERC20 token = _token(tokenSeed);
        amount = _bound(amount, 1, token.balanceOf(actor) + 1);
        vm.prank(actor);
        vault.deposit(IERC20(address(token)), amount, actor);
        // Only reached when the deposit went through.
        if (vault.ratesSet() && vault.totalDepositAllocation() > vault.MAX_DEPOSIT_ALLOCATION()) {
            depositWentAboveCap = true;
        }
    }

    function withdraw(uint256 actorSeed, uint256 tokenSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        MockERC20 token = _token(tokenSeed);
        amount = _bound(amount, 1, vault.depositOf(IERC20(address(token)), actor) + 1);
        vm.prank(actor);
        vault.withdraw(IERC20(address(token)), amount);
    }

    function refund(uint256 callerSeed, uint256 actorSeed) external {
        vm.prank(_actor(callerSeed));
        vault.refund(_actor(actorSeed));
    }

    function strayTransfer(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = _bound(amount, 0, cap.balanceOf(actor) / 100);
        vm.prank(actor);
        cap.transfer(address(vault), amount);
        strayCap += amount;
    }

    function warp(uint256 delta) external {
        vm.warp(block.timestamp + _bound(delta, 1, 5 days));
    }

    /// @dev Jump to just after the deposit deadline, so settlement paths get explored.
    function warpPastDeadline(uint256 extra) external {
        uint256 target = uint256(vault.depositDeadline()) + _bound(extra, 1, 20 days);
        if (target > block.timestamp) vm.warp(target);
    }

    /// @dev The honest owner path: fix rates in time, attest after close, release after the delay.
    function ownerSettleStep(bytes32 root) external {
        vm.startPrank(safe);
        if (!vault.ratesSet()) {
            vault.setRates(25.5e18, 18.5e18);
        } else if (vault.claimRoot() == bytes32(0)) {
            vault.attestClaimRoot(root == bytes32(0) ? bytes32(uint256(1)) : root, 1e18, address(0xD157));
        } else {
            uint256 at = vault.releasableAt();
            if (block.timestamp < at && at <= vault.settlementDeadline()) vm.warp(at);
            uint256 capBefore = cap.balanceOf(safe);
            uint256 dackieBefore = dackie.balanceOf(safe);
            vault.release();
            releasedCap = cap.balanceOf(safe) - capBefore;
            releasedDackie = dackie.balanceOf(safe) - dackieBefore;
        }
        vm.stopPrank();
    }

    function ownerSetRates(uint256 capRate, uint256 dackieRate) external {
        bool alreadySet = vault.ratesSet();
        vm.prank(safe);
        vault.setRates(_bound(capRate, 1, 1_000_000e18), _bound(dackieRate, 1, 1_000_000e18));
        // Only reached when the call went through.
        if (alreadySet && block.timestamp > vault.RATE_CORRECTION_CUTOFF()) ratesChangedAfterCutoff = true;
    }

    function ownerExtend(uint256 delta) external {
        uint64 newDeadline = vault.depositDeadline() + uint64(_bound(delta, 1, 10 days));
        vm.prank(safe); // after reading state: a prank only covers the very next call
        vault.extendDeadline(newDeadline);
    }

    function ownerAttest(bytes32 root) external {
        vm.prank(safe);
        vault.attestClaimRoot(root, 1e18, address(0xD157));
    }

    function ownerRelease() external {
        uint256 capBefore = cap.balanceOf(safe);
        uint256 dackieBefore = dackie.balanceOf(safe);
        vm.prank(safe);
        vault.release();
        releasedCap = cap.balanceOf(safe) - capBefore;
        releasedDackie = dackie.balanceOf(safe) - dackieBefore;
    }

    function ownerCancel(uint256 seed) external {
        if (seed % 20 != 0) return; // keep cancellation rare so the other paths get explored
        vm.prank(safe);
        vault.cancel();
    }

    /// @dev The owner tries to take deposits through every door except `release`.
    function ownerRescue(uint256 tokenSeed, uint256 amount) external {
        MockERC20 token = _token(tokenSeed);
        uint256 excess = vault.excessOf(IERC20(address(token)));
        amount = _bound(amount, 1, excess + 1_000e18);
        vm.prank(safe);
        vault.rescue(IERC20(address(token)), safe, amount);
    }

    /// @dev The guardian tries everything. Only its veto window may ever succeed.
    function guardianCancel(uint256 seed) external {
        if (seed % 10 != 0) return;
        bool vetoWindow = vault.claimRoot() != bytes32(0) && !vault.released() && !vault.cancelled()
            && block.timestamp > vault.depositDeadline() && block.timestamp <= vault.settlementDeadline();
        vm.prank(guardian);
        try vault.cancel() {
            if (!vetoWindow) guardianCancelledOutsideWindow = true;
        } catch {}
    }

    function ownerPause(bool on) external {
        vm.prank(safe);
        if (on) vault.pause();
        else vault.unpause();
    }

    function checkExitAfterRelease() external {
        if (vault.released() && vault.withdrawalsOpen()) exitWasOpenAfterRelease = true;
    }
}

contract VaultInvariantTest is VaultFixture {
    VaultHandler internal handler;

    /// @dev Low enough to be reached by the handler's actors (5 x 1M of each token).
    function _depositCap() internal pure override returns (uint256) {
        return 60_000_000e18;
    }

    IERC20 internal capT;
    IERC20 internal dackieT;

    function setUp() public {
        _deployVault();
        capT = IERC20(address(cap));
        dackieT = IERC20(address(dackie));
        handler = new VaultHandler(vault, cap, dackie, safe, guardian);
        vm.warp(START);
        targetContract(address(handler));
    }

    function _sum(IERC20 token) internal view returns (uint256 sum) {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += vault.depositOf(token, handler.actors(i));
        }
    }

    /// @dev The ledger always adds up: sum of user deposits == totalDeposited.
    function invariant_ledgerAddsUp() public view {
        assertEq(_sum(capT), vault.totalDeposited(capT), "CAP ledger");
        assertEq(_sum(dackieT), vault.totalDeposited(dackieT), "DACKIE ledger");
    }

    /// @dev Until release, the vault holds at least everything it owes. The owner cannot make it
    ///      insolvent with rescue, pause, cancel, extend, rates or attestations.
    function invariant_solventUntilReleased() public view {
        if (vault.released()) return;
        assertGe(cap.balanceOf(address(vault)), vault.totalDeposited(capT), "CAP solvency");
        assertGe(dackie.balanceOf(address(vault)), vault.totalDeposited(dackieT), "DACKIE solvency");
    }

    /// @dev Until release no user token is anywhere but the user's wallet or the vault ledger.
    function invariant_userFundsConservedUntilReleased() public view {
        if (vault.released()) return;
        uint256 n = handler.actorCount();
        uint256 walletsCap;
        uint256 walletsDackie;
        for (uint256 i; i < n; ++i) {
            address actor = handler.actors(i);
            walletsCap += cap.balanceOf(actor);
            walletsDackie += dackie.balanceOf(actor);
            assertEq(dackie.balanceOf(actor) + vault.depositOf(dackieT, actor), handler.INITIAL(), "DACKIE per user");
        }
        // CAP: users also made stray transfers, some of which the owner rescued.
        assertEq(walletsCap + vault.totalDeposited(capT) + _strayCapEver(), n * handler.INITIAL(), "CAP total");
        assertEq(walletsDackie + vault.totalDeposited(dackieT), n * handler.INITIAL(), "DACKIE total");
        assertEq(dackie.balanceOf(safe), 0, "owner holds no DACKIE before release");
        assertLe(cap.balanceOf(safe), handler.strayCap(), "owner holds at most the stray CAP before release");
    }

    function _strayCapEver() internal view returns (uint256) {
        // stray CAP still in the vault + stray CAP the owner rescued
        return (cap.balanceOf(address(vault)) - vault.totalDeposited(capT)) + cap.balanceOf(safe);
    }

    /// @dev Release hands over exactly the ledger totals, and then nothing can be withdrawn.
    function invariant_releaseIsExactAndFinal() public view {
        if (!vault.released()) return;
        assertEq(handler.releasedCap(), vault.totalDeposited(capT), "released CAP");
        assertEq(handler.releasedDackie(), vault.totalDeposited(dackieT), "released DACKIE");
        assertFalse(vault.withdrawalsOpen(), "no exit after release");
        assertFalse(vault.cancelled(), "never both cancelled and released");
        assertTrue(vault.ratesSet(), "rates were fixed before release");
        assertTrue(vault.claimRoot() != bytes32(0), "root was attested before release");
        assertFalse(handler.exitWasOpenAfterRelease());
    }

    /// @dev No deposit is ever accepted that takes the deposit path above its AGENTOS cap.
    function invariant_depositsRespectTheCap() public view {
        assertFalse(handler.depositWentAboveCap());
    }

    /// @dev Rates that are set never change after the published cutoff, whatever the deadline does.
    function invariant_ratesAreFinalAfterTheCutoff() public view {
        assertFalse(handler.ratesChangedAfterCutoff());
        assertEq(vault.RATE_CORRECTION_CUTOFF(), RATE_CUTOFF);
    }

    /// @dev The guardian can only ever cancel inside its veto window.
    function invariant_guardianOnlyVetoes() public view {
        assertFalse(handler.guardianCancelledOutsideWindow());
    }

    /// @dev The deadline only moves later and never past the hard ceiling.
    function invariant_deadlineBounded() public view {
        assertGe(vault.depositDeadline(), DEADLINE);
        assertLe(vault.depositDeadline(), MAX_DEADLINE);
    }
}
