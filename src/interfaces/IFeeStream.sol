// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title  IFeeStream
/// @author Midas
/// @notice A transferable wrapper around one pool's deployer fee bucket.
///
///         A creator who launches through a hook such as PolicyEnvelopeHook or MidasRWAHook
///         earns a share of every swap, claimable by whoever initialised the pool. That is
///         income, not capital: it cannot be sold, escrowed, or borrowed against without
///         selling the underlying token, which is the action that hurts holders most.
///
///         A fee stream is that claim right made into a position. The wrapper initialises the
///         pool itself, so it is the pool's deployer of record and the only address that can
///         claim the bucket. `sync` pulls the bucket in and records the amount against the
///         current epoch, which is what gives the stream a verifiable, realised earnings
///         history. That history, and nothing else, is what a credit line values.
///
///         The wrapper is deliberately narrow. It never swaps, never prices anything, never
///         reads an oracle, and never touches the launched token beyond forwarding it to the
///         holder untouched. Valuation is the sum of amounts this contract actually received.
///
/// @dev    VALUATION IS BACKWARD LOOKING BY CONSTRUCTION. `accruedInWindow` sums completed
///         epochs only. Fees left unclaimed inside the hook are invisible to it, which errs
///         conservative: a stream can only ever look poorer than it is, never richer.
///
/// @dev    Design spec: docs/FEE-STREAM-COLLATERAL.md. No implementation exists.
///         UNAUDITED and unbuilt; these signatures are for review, not deployment.
interface IFeeStream {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    /// @notice A wrapped fee stream.
    /// @param  poolId      The pool whose deployer bucket this stream receives.
    /// @param  quote       The currency valuation and credit are denominated in. Fixed at wrap.
    /// @param  base        The other currency of the pair. Forwarded to the holder, never valued.
    /// @param  holder      Current owner of record. Receives quote only after debt is retired.
    /// @param  pendingHolder Proposed transferee. Zero when no transfer is outstanding.
    /// @param  creditLine  The credit contract holding the lock, or zero when unlocked.
    /// @param  createdEpoch Epoch in which the stream was wrapped.
    struct Stream {
        PoolId poolId;
        Currency quote;
        Currency base;
        address holder;
        address pendingHolder;
        address creditLine;
        uint48 createdEpoch;
    }

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice A pool was initialised through this wrapper and a stream opened against it.
    event StreamWrapped(uint256 indexed streamId, PoolId indexed poolId, address indexed holder, Currency quote, Currency base);

    /// @notice Accrual was claimed from the hook and attributed to an epoch.
    /// @dev    `epoch` is the epoch of the sync call, not of the swaps that produced the fees.
    event Synced(uint256 indexed streamId, uint48 indexed epoch, uint256 quoteAmount, uint256 baseAmount);

    /// @notice A transfer was proposed. Proposing address(0) cancels an outstanding proposal.
    event TransferProposed(uint256 indexed streamId, address indexed from, address indexed to);

    /// @notice A proposed transfer was accepted. Only `holder` changes; debt travels with the stream.
    event TransferAccepted(uint256 indexed streamId, address indexed from, address indexed to);

    /// @notice The stream was pledged to a credit line and can no longer be unwrapped or re-pledged.
    event Locked(uint256 indexed streamId, address indexed creditLine);

    /// @notice The credit line released its lock, debt having reached zero.
    event Unlocked(uint256 indexed streamId, address indexed creditLine);

    /// @notice Value was paid out to the holder.
    event RemainderClaimed(uint256 indexed streamId, address indexed to, Currency currency, uint256 amount);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotHolder();
    error NotPendingHolder();
    error NotCreditLine();
    error StreamLocked();
    error StreamNotFound();
    error AlreadyWrapped();
    error PoolMismatch();
    error QuoteNotInPair();
    error NothingToClaim();
    /// @dev Raised when quote would reach the holder while debt is outstanding. Invariant 5.
    error LenderHasSeniority();

    // ---------------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------------

    /// @notice Initialise `key` through this wrapper and open a stream over its deployer bucket.
    /// @dev    The wrapper calls `initialize` itself so that it, and not the creator, is the
    ///         deployer of record. It verifies the returned PoolId against `key` before
    ///         recording the stream. Under PolicyEnvelopeHook the wrapper also receives the
    ///         policy capsule and immediately proposes it to `holder`: the wrapper must never
    ///         hold fee-setting authority over a pool it is valuing.
    /// @param  key         The pool to initialise. Its hook must expose claimDeployer/deployerBucket.
    /// @param  sqrtPriceX96 Initial price passed through to the pool manager.
    /// @param  quote       Which leg of the pair denominates the stream. Must be one of the two.
    /// @param  holder      Initial owner of record, normally the creator.
    /// @return streamId    Identifier of the new stream.
    function wrap(PoolKey calldata key, uint160 sqrtPriceX96, Currency quote, address holder)
        external
        returns (uint256 streamId);

    /// @notice Claim the pool's deployer bucket into the wrapper and attribute it to this epoch.
    /// @dev    Permissionless by design: a lender must be able to force recognition, and a
    ///         borrower must not be able to hide income by declining to claim it. Routes the
    ///         quote side through the credit line first when one is open, so reserve and
    ///         repayment take priority over the holder.
    /// @param  streamId The stream to sync.
    /// @return quoteAmount Quote currency recognised in this call.
    /// @return baseAmount  Launched-token side recognised, forwarded to the holder untouched.
    function sync(uint256 streamId) external returns (uint256 quoteAmount, uint256 baseAmount);

    /// @notice Pay the holder what is theirs: base at any time, quote only when no debt remains.
    /// @dev    Reverts with LenderHasSeniority if quote is requested while a line is outstanding.
    ///         There is no payout-address parameter anywhere in this interface: value goes to the
    ///         holder of record or nowhere.
    function claimRemainder(uint256 streamId, Currency currency) external returns (uint256 amount);

    /// @notice Close a stream with no outstanding line and return its claim right to the holder.
    /// @dev    Reverts with StreamLocked while a credit line holds the lock. Invariant 10.
    function unwrap(uint256 streamId) external;

    // ---------------------------------------------------------------------
    // Transfer: two steps, so a stream is never sent to an address that cannot use it
    // ---------------------------------------------------------------------

    /// @notice Propose a new holder. Pass address(0) to cancel an outstanding proposal.
    /// @dev    The current holder retains every right until acceptance.
    function proposeTransfer(uint256 streamId, address to) external;

    /// @notice Accept a proposed transfer. Callable only by the proposed address.
    /// @dev    Changes `holder` and nothing else. Debt, reserve, epoch history, lock state and
    ///         lender are untouched: a buyer takes the stream subject to the lender's seniority.
    ///         Invariant 7.
    function acceptTransfer(uint256 streamId) external;

    // ---------------------------------------------------------------------
    // Lock, held by the credit line
    // ---------------------------------------------------------------------

    /// @notice Record that a credit line has pledged this stream. Callable by that line only.
    function lock(uint256 streamId) external;

    /// @notice Release the lock once debt is zero. Callable by the locking line only.
    function unlock(uint256 streamId) external;

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Realised quote accrual over the last `epochs` COMPLETED epochs.
    /// @dev    The current, incomplete epoch is always excluded. Invariant 12. This is the only
    ///         valuation input in the system: no price, no forecast, no TVL.
    function accruedInWindow(uint256 streamId, uint48 epochs) external view returns (uint256);

    /// @notice Quote accrual attributed to one specific epoch.
    function accrualAt(uint256 streamId, uint48 epoch) external view returns (uint256);

    /// @notice Full record of a stream.
    function streamOf(uint256 streamId) external view returns (Stream memory);

    /// @notice Current epoch number under this wrapper's clock.
    function currentEpoch() external view returns (uint48);

    /// @notice Seconds per epoch. Immutable. One day in the reference design.
    function EPOCH_LENGTH() external view returns (uint256);

    /// @notice Amount held for the holder that is not yet claimable or routed.
    function heldFor(uint256 streamId, Currency currency) external view returns (uint256);
}
