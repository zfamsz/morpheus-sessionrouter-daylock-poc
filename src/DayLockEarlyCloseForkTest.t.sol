// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {
    ISessionRouter,
    IMarketplace,
    IModelRegistry,
    IProviderRegistry,
    IERC20
} from "./Interfaces.sol";

/// @title Independent reproduction: SessionRouter day-lock only covers the final UTC day
/// @notice Written from the Morpheus-Lumerin-Node source alone
///         (contracts/diamond/facets/SessionRouter.sol, _rewardUserAfterClose).
///         Shape under test — EARLY CLOSE of a multi-day session: the session is
///         closed mid-way (about 2.5 days into a ~5.5-day session), not late on its
///         final day. That is the gap this reproduction targets: the lock formula
///         anchors to the UTC day of min(closedAt, endsAt), so for ANY close that
///         spans more than one UTC day, the stake backing the earlier days'
///         already-drawn stipend is released in the same close transaction.
///
///         The same capital then funds a second full session in the same UTC day,
///         which draws a fresh stipend from the funding account. Net new capital
///         across both sessions is zero.
///
///         Fork test against live Base bytecode, pinned block, read-only.
///         Run:  BASE_RPC_URL=https://mainnet.base.org forge test --match-contract SessionDayLockForkTest -vv
contract SessionDayLockForkTest is Test {
    // Live deployment under test (Base mainnet)
    address constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address constant MOROFT = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    uint256 constant BLOCK_PINNED = 58_461_106;

    ISessionRouter router = ISessionRouter(DIAMOND);

    // Single self-dealing actor: consumer AND provider on its own bid.
    // No privilege, no counterparty, no admin role.
    uint256 operatorKey = 0x5EEDCA7;
    address operator;

    // Parameters chosen for this reproduction (not copied from any other PoC).
    uint256 constant STAKE_ONE = 5000e18;
    uint256 constant PROVIDER_STAKE = 10000e18;
    uint256 constant MODEL_STAKE = 250e18;
    uint256 constant PRICE_PER_SECOND = 3e13;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), BLOCK_PINNED);
        operator = vm.addr(operatorKey);
        deal(MOROFT, operator, 20000e18);
        vm.prank(operator);
        IERC20(MOROFT).approve(DIAMOND, type(uint256).max);
    }

    function _signPayload(bytes memory payload) internal view returns (bytes memory sig) {
        bytes32 digest = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(payload))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _registerOwnOffer() internal returns (bytes32 bidId) {
        string[] memory labels = new string[](1);
        labels[0] = "independent";
        vm.startPrank(operator);
        IProviderRegistry(DIAMOND).providerRegister(operator, PROVIDER_STAKE, "https://independent");
        IModelRegistry(DIAMOND).modelRegister(
            operator, keccak256("independent-base"), keccak256("independent-cid"), 0, MODEL_STAKE, "independent", labels
        );
        bytes32 modelId = IModelRegistry(DIAMOND).getModelId(operator, keccak256("independent-base"));
        bidId = IMarketplace(DIAMOND).postModelBid(operator, modelId, PRICE_PER_SECOND);
        vm.stopPrank();
        assertTrue(bidId != bytes32(0), "offer must exist");
    }

    function _open(bytes32 bidId, uint256 amount) internal returns (bytes32 sessionId) {
        bytes memory approval = abi.encode(bidId, block.chainid, operator, uint128(block.timestamp));
        vm.prank(operator);
        sessionId = router.openSession(operator, amount, false, approval, _signPayload(approval));
    }

    /// @notice Early close of a multi-day session releases the stake that backed
    ///         the earlier UTC days' already-drawn stipend, and the refund funds
    ///         a second session the same UTC day that draws a fresh stipend.
    function test_earlyCloseReleasesPriorDaysStake() public {
        bytes32 bidId = _registerOwnOffer();

        bytes32 sessionOne = _open(bidId, STAKE_ONE);
        uint128 openedAt = uint128(block.timestamp);

        uint128 plannedEnd = router.getSessionEnd(STAKE_ONE, PRICE_PER_SECOND, openedAt);
        emit log_named_uint("planned session length (days)", (plannedEnd - openedAt) / 1 days);
        assertGt(plannedEnd - openedAt, 3 days, "close must be genuinely early in a multi-day session");

        // Close ~2.5 days in: mid-session, and across at least two UTC midnights.
        uint128 closeAt = openedAt + 2 days + 12 hours;
        (uint256 refunded, uint256 lockedNow, uint256 providerPaidAtClose) =
            _closeFirstSession(sessionOne, closeAt);

        uint128 closeDayStart = router.startOfTheDay(closeAt);
        uint256 utcDaysSpanned = (closeDayStart - router.startOfTheDay(openedAt)) / 1 days + 1;
        emit log_named_uint("UTC days spanned by session one", utcDaysSpanned);
        assertGe(utcDaysSpanned, 3, "session consumed compute across at least 3 UTC days");

        // The lock must equal ONLY the final-day slice: recompute it from the
        // public views, independently of the close path. (utcDaysSpanned >= 3
        // implies closeDayStart > openedAt, so the final-day slice is simply
        // closeAt - closeDayStart.)
        uint256 expectedLock =
            router.stipendToStake((closeAt - closeDayStart) * PRICE_PER_SECOND, closeDayStart);
        emit log_named_uint("stake locked on hold", lockedNow);
        emit log_named_uint("expected final-day-only lock", expectedLock);
        emit log_named_uint("stake refunded in the close tx", refunded);
        assertLe(lockedNow, (expectedLock * 101) / 100, "lock exceeds the final-day-only amount");
        assertGe(lockedNow, (expectedLock * 99) / 100, "lock is not the final-day-only amount");

        // Most of the stake came straight back even though it already backed
        // stipend drawn for the earlier days.
        assertGe(refunded, (STAKE_ONE * 70) / 100, "majority of the stake must be refunded at close");

        // The provider was paid for the elapsed time at close, out of the
        // funding account (not out of the user's stake: direct payment is off).
        assertEq(
            providerPaidAtClose,
            (closeAt - openedAt) * PRICE_PER_SECOND,
            "provider must be paid elapsed time at close"
        );

        (uint256 secondStipend, uint256 lockedAfterBoth) =
            _runSecondSession(bidId, refunded, closeDayStart);
        emit log_named_uint("second session stipend drawn (funding account)", secondStipend);
        assertGt(secondStipend, 0, "second session must draw a fresh stipend");

        // Across both full sessions, the user's capital was effectively
        // encumbered only for the two final days — not for two full sessions.
        emit log_named_uint("total stake locked after both sessions", lockedAfterBoth);
        assertLt(lockedAfterBoth, STAKE_ONE, "locked fraction must stay far below the original stake");
    }

    /// @notice Warps to closeAt, closes session one early with a valid
    ///         self-signed receipt, and measures what came back.
    function _closeFirstSession(bytes32 sessionOne, uint128 closeAt)
        internal
        returns (uint256 refunded, uint256 lockedNow, uint256 providerPaidAtClose)
    {
        vm.warp(closeAt);
        uint256 balanceBeforeClose = IERC20(MOROFT).balanceOf(operator);
        bytes memory receipt =
            abi.encode(sessionOne, block.chainid, uint128(block.timestamp), uint32(1000), uint32(100));
        vm.prank(operator);
        router.closeSession(receipt, _signPayload(receipt));
        (, lockedNow) = router.getUserStakesOnHold(operator, 1);
        refunded = STAKE_ONE - lockedNow;
        providerPaidAtClose = (IERC20(MOROFT).balanceOf(operator) - balanceBeforeClose) - refunded;
        emit log_named_uint("provider paid at close (funding account)", providerPaidAtClose);
    }

    /// @notice Opens a second session with the refunded stake in the same UTC
    ///         day, then draws its stipend after its end.
    function _runSecondSession(bytes32 bidId, uint256 refunded, uint128 closeDayStart)
        internal
        returns (uint256 secondStipend, uint256 lockedAfterBoth)
    {
        assertEq(router.startOfTheDay(uint128(block.timestamp)), closeDayStart, "still the close UTC day");
        bytes32 sessionTwo = _open(bidId, refunded);
        assertTrue(sessionTwo != bytes32(0), "refund must fund a new session the same UTC day");
        uint128 endsAtTwo = router.getSessionEnd(refunded, PRICE_PER_SECOND, uint128(block.timestamp));
        vm.warp(endsAtTwo + 1);
        uint256 providerBeforeClaim = IERC20(MOROFT).balanceOf(operator);
        vm.prank(operator);
        router.claimForProvider(sessionTwo);
        secondStipend = IERC20(MOROFT).balanceOf(operator) - providerBeforeClaim;
        (, lockedAfterBoth) = router.getUserStakesOnHold(operator, 5);
    }
}
