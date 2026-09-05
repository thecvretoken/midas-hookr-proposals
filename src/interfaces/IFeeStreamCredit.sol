// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title  IFeeStreamCredit
/// @author Midas
/// @notice Pool-native credit against a fee stream, where the stream is the repayment.
///
///         A creator borrows quote currency against fees they have already earned, and the
///         fees that arrive afterwards retire the debt. The most common way a launch dies in
///         month two is the creator selling supply to cover costs. This is the alternative
///         that does not touch supply.
///
///         Three properties define it, and each is a deliberate refusal:
///
///         There is no oracle. A line is sized from realised accrual read out of the stream's
///         own records, V = accruedInWindow(streamId, WINDOW_EPOCHS). Projected fees, token
///         price, volume forecasts and TVL never enter the arithmetic.
///
///         There is no forced sale. No function in this contract swaps, seizes, auctions, or
///         transfers the launched token, and nothing here can be triggered by a lender to take
///         anything. When accrual arrives, a reserve slice is taken, the rest pays the lender
///         down, and only a zero balance releases value to the holder.
///
///         There is no time-based interest. Each draw adds a fixed fee, so debt moves in
///         exactly two places, up at `draw` and down at `repayFromAccrual`. A borrower who does
///         not control the repayment schedule must not carry a balance that grows on its own.
///
///         The haircut is severe and the reason is correlation, not volatility. Fee income is a
///         function of the launched token's volume, and volume collapses in precisely the
///         scenario where a creator defaults. Collateral and ability to pay are one variable.
///
/// @dev    Design spec: docs/FEE-STREAM-COLLATERAL.md. No implementation exists.
///         UNAUDITED and unbuilt; these signatures are for review, not deployment.
///         This design requires an audit before real money is placed against it.
interface IFeeStreamCredit {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    /// @notice Why a line is currently refusing draws. Healthy means it is not.
    /// @dev    Terminal is reached at maturity with debt outstanding and is never left:
    ///         the reserve is applied in full and sweeps continue until the debt is zero.
    enum FreezeState {
        Healthy,
        FrozenServiceRate,
        FrozenReserveBound,
        Terminal
    }

    /// @notice One credit line. Every term is fixed at `open` and immutable thereafter.
    /// @param  streamId       Stream pledged as collateral.
    /// @param  lender         Funder of record. Cannot accelerate, seize, or amend.
    /// @param  quote          Currency of the advance and the repayment.
    /// @param  principal      Total advanced across all draws, before fees.
    /// @param  outstanding    Current debt D, principal plus draw fees, less repayments.
    /// @param  reserve        Backstop balance R, funded from accrual while D is above zero.
    /// @param  haircutBps     h, advance rate against V. Immutable per line.
    /// @param  drawFeeBps     f, added to each draw. Immutable per line.
    /// @param  maturityEpoch  Epoch at which an outstanding line becomes Terminal.
    /// @param  lastValuation  L computed at the most recent draw. Not refreshed between draws.
    struct Line {
        uint256 streamId;
        address lender;
        Currency quote;
        uint256 principal;
        uint256 outstanding;
        uint256 reserve;
        uint16 haircutBps;
        uint16 drawFeeBps;
        uint48 maturityEpoch;
        uint256 lastValuation;
    }

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice The stream holder pledged a stream to a named lender on hashed terms.
    event Pledged(uint256 indexed lineId, uint256 indexed streamId, address indexed lender, bytes32 termsHash);

    /// @notice The lender funded the line on matching terms. Terms are immutable from here.
    event Opened(uint256 indexed lineId, address indexed lender, uint256 haircutBps, uint256 drawFeeBps, uint48 maturityEpoch);

    /// @notice A pledge or an unfunded offer was withdrawn before the handshake completed.
    event PledgeCancelled(uint256 indexed lineId);

    /// @notice A draw was taken. `valuation` is the V used, `line` the resulting L.
    event Drawn(uint256 indexed lineId, uint256 amount, uint256 fee, uint256 valuation, uint256 creditLimit, uint256 outstanding);

    /// @notice Accrual was routed. Reserve first, then the lender, and the holder only at zero.
    event Repaid(uint256 indexed lineId, uint256 toReserve, uint256 toLender, uint256 toHolder, uint256 outstanding);

    /// @notice The freeze state changed. Emitted on every transition, including into Terminal.
    event FreezeChanged(uint256 indexed lineId, FreezeState from, FreezeState to);

    /// @notice Debt reached zero. Reserve is released to the holder and the stream is unlocked.
    event Closed(uint256 indexed lineId, uint256 reserveReleased);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotHolder();
    error NotLender();
    error LineNotFound();
    error LineFrozen();
    error LineClosed();
    error AlreadyPledged();
    error TermsMismatch();
    /// @dev Post-draw D would exceed h * V. Invariant 2.
    error ExceedsCreditLimit();
    /// @dev Post-draw D would exceed R + h * V. Invariant 3.
    error ExceedsReserveBound();
    error HaircutAboveCeiling();
    error DrawFeeAboveCeiling();
    error MaturityOutOfRange();
    error NothingOutstanding();
    error ZeroAmount();

    // ---------------------------------------------------------------------
    // Opening: a two-step handshake, so neither side is committed alone
    // ---------------------------------------------------------------------

    /// @notice Pledge a stream to a named lender on hashed terms. Locks the stream.
    /// @dev    Callable by the stream holder only. `termsHash` binds haircut, draw fee and
    ///         maturity so the lender cannot fund different terms than were offered.
    function pledge(uint256 streamId, address lender, bytes32 termsHash) external returns (uint256 lineId);

    /// @notice Withdraw an unfunded pledge and release the lock. Holder or named lender.
    function cancelPledge(uint256 lineId) external;

    /// @notice Fund a pledged line on terms matching its hash. Callable by the named lender only.
    /// @dev    Every term is validated against the hardcoded ceilings here and is immutable
    ///         afterwards: there is no amend path, for either side. Invariant 11.
    function open(uint256 lineId, uint16 haircutBps, uint16 drawFeeBps, uint48 maturityEpoch) external;

    // ---------------------------------------------------------------------
    // Drawing and repayment
    // ---------------------------------------------------------------------

    /// @notice Draw `amount` of quote against the stream. Stream holder only.
    /// @dev    Recomputes V from the stream at call time, stores L = h * V, and refuses the
    ///         draw unless the post-draw debt satisfies both D <= L and D <= R + h * V.
    ///         Reverts while frozen. This is the only function in the system that raises D.
    ///         Invariants 2, 3, 4, 9.
    function draw(uint256 lineId, uint256 amount) external;

    /// @notice Route accrual recognised by the stream: reserve slice, then lender, then holder.
    /// @dev    Permissionless. Anyone may cause accrual to be routed; nobody can change where
    ///         it goes. Normally called by the stream's `sync`. Evaluates freeze conditions and
    ///         closes the line when the debt reaches zero. Invariant 5.
    function repayFromAccrual(uint256 lineId, uint256 amount) external returns (uint256 toReserve, uint256 toLender, uint256 toHolder);

    /// @notice Repay early from the caller's own funds. Permissionless.
    /// @dev    Present so a creator with outside money can clear a line without waiting for
    ///         volume. It only ever lowers D.
    function repayDirect(uint256 lineId, uint256 amount) external;

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Full record of a line.
    function lineOf(uint256 lineId) external view returns (Line memory);

    /// @notice Current freeze state, evaluated against live accrual.
    /// @dev    F1: A_K / K < S, where S = D / max(1, maturityEpoch - currentEpoch).
    ///         F2: D > R + h * V. Unfreezing requires both to clear with a 25% hysteresis
    ///         margin, so a line at the boundary does not flap. Invariant 8.
    function freezeStateOf(uint256 lineId) external view returns (FreezeState);

    /// @notice Valuation V, the realised quote accrual over the trailing window.
    function valuationOf(uint256 lineId) external view returns (uint256);

    /// @notice Credit limit L = h * V at current valuation. Advisory between draws.
    function creditLimitOf(uint256 lineId) external view returns (uint256);

    /// @notice Backstop reserve balance R.
    function reserveOf(uint256 lineId) external view returns (uint256);

    /// @notice Per-epoch amount needed to retire the debt by maturity.
    function serviceRateOf(uint256 lineId) external view returns (uint256);

    /// @notice The line, if any, holding a lock on a stream. Zero when unpledged.
    function lineForStream(uint256 streamId) external view returns (uint256 lineId);

    // --- Constants and ceilings ------------------------------------------

    /// @notice Advance rate ceiling. 2_500 bps in the reference design, and also its default.
    function MAX_HAIRCUT_BPS() external view returns (uint16);

    /// @notice Draw fee ceiling, 2_000 bps.
    function MAX_DRAW_FEE_BPS() external view returns (uint16);

    /// @notice Reserve slice taken from every accrual while debt is outstanding, 1_000 bps.
    function RESERVE_BPS() external view returns (uint16);

    /// @notice Valuation window in completed epochs, 30.
    function WINDOW_EPOCHS() external view returns (uint48);

    /// @notice Service-rate lookback in completed epochs, 7.
    function SERVICE_EPOCHS() external view returns (uint48);

    /// @notice Hysteresis margin applied to the unfreeze test, 12_500 bps of the service rate.
    function UNFREEZE_MARGIN_BPS() external view returns (uint16);
}
