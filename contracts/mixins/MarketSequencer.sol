// SPDX-License-Identifier: GPL-3

pragma solidity ^0.8.4;

import '../libraries/Directives.sol';
import '../libraries/PoolSpecs.sol';
import '../libraries/PriceGrid.sol';
import '../libraries/SwapCurve.sol';
import '../libraries/CurveMath.sol';
import '../libraries/CurveRoll.sol';
import '../libraries/CurveCache.sol';
import '../libraries/Chaining.sol';
import './PositionRegistrar.sol';
import './LiquidityCurve.sol';
import './LevelBook.sol';
import './ColdInjector.sol';
import './TradeMatcher.sol';
import './ColdInjector.sol';

/* @title Market sequencer.
 * @notice Mixin class that's responsibile for coordinating one or multiple sequetial
 *         trade actions within a single liqudity pool. */
contract MarketSequencer is TradeMatcher {

    using SafeCast for int256;
    using SafeCast for int128;
    using SafeCast for uint256;
    using SafeCast for uint128;
    using TickMath for uint128;
    using PoolSpecs for PoolSpecs.Pool;
    using SwapCurve for CurveMath.CurveState;
    using CurveRoll for CurveMath.CurveState;
    using CurveMath for CurveMath.CurveState;
    using CurveCache for CurveCache.Cache;
    using Directives for Directives.ConcentratedDirective;
    using PriceGrid for PriceGrid.ImproveSettings;
    using Chaining for Chaining.PairFlow;
    using Chaining for Chaining.RollTarget;

    /* @notice Performs a sequence of an arbitrary potential combination of mints, 
     *         burns, and swaps on a single pool. 
     *
     * @param flow Output accumulator, into which we'll net and and add the token flows 
     *             associated with the trade actions in this call.
     * @param dir A directive specifying an arbitrary sequences of action.
     * @param cntx Provides the execution context for the operation, including the pool
     *             to execute on and it's pre-loaded specs, off-grid price improvement
     *             settings, and parameters for rolling gap-failled quantities if they
     *             appear in the directive. */
    function tradeOverPool (Chaining.PairFlow memory flow,
                            Directives.PoolDirective memory dir,
                            Chaining.ExecCntx memory cntx) internal {
        // To avoid repeatedly loading and storing the curve on each operation, we load
        // it once into memory...
        CurveCache.Cache memory curve;
        curve.curve_ = snapCurve(cntx.pool_.hash_);
        applyToCurve(flow, dir, curve, cntx);
        /// ...Then check it back into storage when complete
        commitCurve(cntx.pool_.hash_, curve.curve_);
    }

    /* @notice Performs a single swap over the pool.
     * @param dir The user-specified directive governing the size, direction and limit
     *            price of the swap to be performed.
     * @param pool The pre-loaded speciication and hash of the pool to be swapped against.
     * @return flow The net token flows generated by the swap. */
    function swapOverPool (Directives.SwapDirective memory dir,
                           PoolSpecs.PoolCursor memory pool)
        internal returns (Chaining.PairFlow memory flow) {
        CurveMath.CurveState memory curve = snapCurve(pool.hash_);
        sweepSwapLiq(flow, curve, curve.priceRoot_.getTickAtSqrtRatio(), dir, pool);
        commitCurve(pool.hash_, curve);
    }

    /* @notice Mints concentrated liquidity in the form of a range order on to the pool.
     *
     * @param bidTick The price tick associated with the lower boundary of the range
     *                order.
     * @param askTick The price tick associated with the upper boundary of the range
     *                order.
     * @param liq The amount of liquidity being minted represented as the equivalent to
     *            sqrt(X*Y) in a constant product AMM pool.
     * @param pool The pre-loaded speciication and hash of the pool to be swapped against.
     * @param minPrice The minimum acceptable curve price to mint liquidity. If curve
     *                 price falls outside this point, the transaction is reverted.
     * @param maxPrice The maximum acceptable curve price to mint liquidity. If curve
     *                 price falls outside this point, the transaction is reverted.
     * @param lpConduit The address of the ICrocLpConduit that the liquidity will be
     *                  assigned to (0 for user owned liquidity).
     *
     * @return baseFlow The total amount of base-side token collateral that must be
     *                  committed to the pool as part of the mint. Will always be
     *                  positive as it's paid to the pool from the user.
     * @return quoteFlow The total amount of quote-side token collateral that must be
     *                   committed to the pool as part of the mint. */
    function mintOverPool (int24 bidTick, int24 askTick, uint128 liq,
                           PoolSpecs.PoolCursor memory pool,
                           uint128 minPrice, uint128 maxPrice,
                           address lpConduit)
        internal returns (int128 baseFlow, int128 quoteFlow) {
        CurveMath.CurveState memory curve = snapCurveInRange
            (pool.hash_, minPrice, maxPrice);
        (baseFlow, quoteFlow) =
            mintRange(curve, curve.priceRoot_.getTickAtSqrtRatio(),
                      bidTick, askTick, liq, pool.hash_, lpConduit);
        PriceGrid.verifyFit(bidTick, askTick, pool.head_.tickSize_);
        commitCurve(pool.hash_, curve);
    }

    /* @notice Burns concentrated liquidity in the form of a range order on to the pool.
     *
     * @param bidTick The price tick associated with the lower boundary of the range
     *                order.
     * @param askTick The price tick associated with the upper boundary of the range
     *                order.
     * @param liq The amount of liquidity to burn represented as the equivalent to
     *            sqrt(X*Y) in a constant product AMM pool.
     * @param pool The pre-loaded speciication and hash of the pool to be swapped against.
     * @param minPrice The minimum acceptable curve price to mint liquidity. If curve
     *                 price falls outside this point, the transaction is reverted.
     * @param maxPrice The maximum acceptable curve price to mint liquidity. If curve
     *                 price falls outside this point, the transaction is reverted.
     *
     * @return baseFlow The total amount of base-side token collateral that is returned
     *                  from the pool as part of the burn. Will always be
     *                  negative as it's paid from the pool to the user.
     * @return quoteFlow The total amount of quote-side token collateral that is returned
     *                   from the pool as part of the burn. */
    function burnOverPool (int24 bidTick, int24 askTick, uint128 liq,
                           PoolSpecs.PoolCursor memory pool,
                           uint128 minPrice, uint128 maxPrice, address lpConduit)
        internal returns (int128 baseFlow, int128 quoteFlow) {
        CurveMath.CurveState memory curve = snapCurveInRange
            (pool.hash_, minPrice, maxPrice);
        (baseFlow, quoteFlow) =
            burnRange(curve, curve.priceRoot_.getTickAtSqrtRatio(),
                      bidTick, askTick, liq, pool.hash_, lpConduit);
        commitCurve(pool.hash_, curve);
    }

    /* @notice Harvests rewards from a concentrated liquidity position.
     *
     * @param bidTick The price tick associated with the lower boundary of the range
     *                order.
     * @param askTick The price tick associated with the upper boundary of the range
     *                order.
     * @param pool The pre-loaded speciication and hash of the pool to be swapped against.
     * @param minPrice The minimum acceptable curve price to mint liquidity. If curve
     *                 price falls outside this point, the transaction is reverted.
     * @param maxPrice The maximum acceptable curve price to mint liquidity. If curve
     *                 price falls outside this point, the transaction is reverted.
     *
     * @return baseFlow The total amount of base-side token collateral that is returned
     *                  from the pool as part of the burn. Will always be
     *                  negative as it's paid from the pool to the user.
     * @return quoteFlow The total amount of quote-side token collateral that is returned
     *                   from the pool as part of the burn. */
    function harvestOverPool (int24 bidTick, int24 askTick,
                              PoolSpecs.PoolCursor memory pool,
                              uint128 minPrice, uint128 maxPrice, address lpConduit)
        internal returns (int128 baseFlow, int128 quoteFlow) {
        CurveMath.CurveState memory curve = snapCurveInRange
            (pool.hash_, minPrice, maxPrice);
        (baseFlow, quoteFlow) =
            harvestRange(curve, curve.priceRoot_.getTickAtSqrtRatio(),
                         bidTick, askTick, pool.hash_, lpConduit);
        commitCurve(pool.hash_, curve);
    }

    /* @notice Mints ambient liquidity on to the pool's curve.
     *
     * @param liq The amount of liquidity being minted represented as the equivalent to
     *            sqrt(X*Y) in a constant product AMM pool.
     * @param pool The pre-loaded speciication and hash of the pool to be swapped against.
     * @param minPrice The minimum acceptable curve price to mint liquidity. If curve
     *                 price falls outside this point, the transaction is reverted.
     * @param maxPrice The maximum acceptable curve price to mint liquidity. If curve
     *                 price falls outside this point, the transaction is reverted.
     * @param lpConduit The address of the ICrocLpConduit that the liquidity will be
     *                  assigned to (0 for user owned liquidity).
     *
     * @return baseFlow The total amount of base-side token collateral that must be
     *                  committed to the pool as part of the mint. Will always be
     *                  positive as it's paid to the pool from the user.
     * @return quoteFlow The total amount of quote-side token collateral that must be
     *                   committed to the pool as part of the mint. */
    function mintOverPool (uint128 liq, PoolSpecs.PoolCursor memory pool,
                           uint128 minPrice, uint128 maxPrice, address lpConduit)
        internal returns (int128 baseFlow, int128 quoteFlow) {
        CurveMath.CurveState memory curve = snapCurveInRange
            (pool.hash_, minPrice, maxPrice);
        (baseFlow, quoteFlow) =
            mintAmbient(curve, liq, pool.hash_, lpConduit);
        commitCurve(pool.hash_, curve);
    }

    
    /* @notice Burns ambient liquidity on to the pool's curve.
     *
     * @param liq The amount of liquidity to burn represented as the equivalent to
     *            sqrt(X*Y) in a constant product AMM pool.
     * @param pool The pre-loaded speciication and hash of the pool to be swapped against.
     * @param minPrice The minimum acceptable curve price to mint liquidity. If curve
     *                 price falls outside this point, the transaction is reverted.
     * @param maxPrice The maximum acceptable curve price to mint liquidity. If curve
     *                 price falls outside this point, the transaction is reverted.
     *
     * @return baseFlow The total amount of base-side token collateral that is returned
     *                  from the pool as part of the burn. Will always be negative
     *                  as it's paid from the pool to the user.
     * @return quoteFlow The total amount of quote-side token collateral that is returned
     *                   from the pool as part of the burn. */
    function burnOverPool (uint128 liq, PoolSpecs.PoolCursor memory pool,
                           uint128 minPrice, uint128 maxPrice, address lpConduit)
        internal returns (int128 baseFlow, int128 quoteFlow) {
        CurveMath.CurveState memory curve = snapCurveInRange
            (pool.hash_, minPrice, maxPrice);
        (baseFlow, quoteFlow) =
            burnAmbient(curve, liq, pool.hash_, lpConduit);
        commitCurve(pool.hash_, curve);
    }

    /* @notice Initializes a new liquidity curve for the pool.
       
     * @dev This does *not* check whether the curve was previously initialized. It's
     *      the caller's responsibility to make sure this is never called on an already
     *      initialized pool.
     *
     * @param pool The pre-loaded speciication and hash of the pool to be swapped against.
     * @param price The initial price to set the curve at. Represented as the square root
     *              of price in Q64.64 fixed point.
     * @param initLiq The initial ambient liquidity commitment that will be permanetely 
     *                locked in the pool. Represeted as sqrt(X*Y) constant-product AMM
     *                liquidity.
     *
     * @return baseFlow The total amount of base-side token collateral that must be
     *                  committed to the pool as part of the mint. Will always be
     *                  positive as it's paid to the pool from the user.
     * @return quoteFlow The total amount of quote-side token collateral that must be
     *                   committed to the pool as part of the mint. */     
    function initCurve (PoolSpecs.PoolCursor memory pool,
                        uint128 price, uint128 initLiq)
        internal returns (int128 baseFlow, int128 quoteFlow) {
        CurveMath.CurveState memory curve = snapCurveInit(pool.hash_);
        initPrice(curve, price);
        if (initLiq == 0) { initLiq = 1; }
        (baseFlow, quoteFlow) = lockAmbient(curve, initLiq);
        commitCurve(pool.hash_, curve);
    }

    /* @notice Appplies the pool directive on to a pre-loaded liquidity curve. */
    function applyToCurve (Chaining.PairFlow memory flow,
                           Directives.PoolDirective memory dir,
                           CurveCache.Cache memory curve,
                           Chaining.ExecCntx memory cntx) private {
        if (!dir.chain_.swapDefer_) {
            applySwap(flow, dir.swap_, curve, cntx);
        }
        applyAmbient(flow, dir.ambient_, curve, cntx);
        applyConcentrateds(flow, dir.conc_, curve, cntx);
        if (dir.chain_.swapDefer_) {
            applySwap(flow, dir.swap_, curve, cntx);
        }
    }

    /* @notice Applies the swap directive on to a pre-loaded liquidity curve. */
    function applySwap (Chaining.PairFlow memory flow,
                        Directives.SwapDirective memory dir,
                        CurveCache.Cache memory curve,
                        Chaining.ExecCntx memory cntx) private {
        cntx.roll_.plugSwapGap(dir, flow);
        if (dir.qty_ != 0) {
            callSwap(flow, curve, dir, cntx.pool_);            
        }
    }

    /* @notice Applies an ambient liquidity directive to a pre-loaded liquidity curve. */
    function applyAmbient (Chaining.PairFlow memory flow,
                           Directives.AmbientDirective memory dir,
                           CurveCache.Cache memory curve,
                           Chaining.ExecCntx memory cntx) private {
        cntx.roll_.plugLiquidity(dir, curve.curve_, flow);
        
        if (dir.liquidity_ > 0) {
            (int128 base, int128 quote) = dir.isAdd_ ?
                callMintAmbient(curve, dir.liquidity_, cntx.pool_.hash_) :
                callBurnAmbient(curve, dir.liquidity_, cntx.pool_.hash_);
        
            flow.accumFlow(base, quote);
        }
    }

    /* @notice Applies zero, one or a series of concentrated liquidity directives to a 
     *         pre-loaded liquidity curve. */
    function applyConcentrateds (Chaining.PairFlow memory flow,
                                 Directives.ConcentratedDirective[] memory dirs,
                                 CurveCache.Cache memory curve,
                                 Chaining.ExecCntx memory cntx) private {
        unchecked { // Only arithmetic in block is ++i which will never overflow
        for (uint i = 0; i < dirs.length; ++i) {
            (int128 nextBase, int128 nextQuote) = applyConcentrated
                (curve, flow, cntx, dirs[i]);
            flow.accumFlow(nextBase, nextQuote);
        }
        }
    }

    /* Applies a single concentrated liquidity range order to the liquidity curve. */
    function applyConcentrated (CurveCache.Cache memory curve,
                                Chaining.PairFlow memory flow,
                                Chaining.ExecCntx memory cntx,
                                Directives.ConcentratedDirective memory bend)
        private returns (int128, int128) {

        // If ticks are relative, normalize against current pool price.
        if (bend.isTickRel_) {
            int24 priceTick = curve.pullPriceTick();
            bend.lowTick_ = priceTick + bend.lowTick_;
            bend.highTick_ = priceTick + bend.highTick_;
            require((bend.lowTick_ >= TickMath.MIN_TICK) &&
                    (bend.highTick_ <= TickMath.MAX_TICK) &&
                    (bend.lowTick_ <= bend.highTick_), "RT");
        }

        // If liquidity is set based on rolling balance, dynamically set in base
        // liquidity space.
        cntx.roll_.plugLiquidity(bend, curve.curve_, bend.lowTick_,
                                 bend.highTick_, flow);

        if (bend.isAdd_) {
            bool offGrid = cntx.improve_.verifyFit(bend.lowTick_, bend.highTick_,
                                                   bend.liquidity_,
                                                   cntx.pool_.head_.tickSize_,
                                                   curve.pullPriceTick());

            // Off-grid positions are only eligible when the LP has committed
            // to a minimum liquidity commitment above some threshold. This opens
            // up the possibility of a user minting an off-grid LP position above the
            // the threshold, then partially burning the position to resize the position *below*
            // the threhsold. 
            // To prevent this all off-grid positions are marked as atomic which prevents partial 
            // (but not full) burns. An off-grid LP wishing to reduce their position must fully 
            // burn the position, then mint a new position, which will be checked that it meets 
            // the size threshold at mint time.
            if (offGrid) {
                markPosAtomic(lockHolder_, cntx.pool_.hash_,
                              bend.lowTick_, bend.highTick_);
            }
        }

        if (bend.liquidity_ == 0) { return (0, 0); }
        return bend.isAdd_ ?
            callMintRange(curve, bend.lowTick_, bend.highTick_,
                          bend.liquidity_, cntx.pool_.hash_) :
            callBurnRange(curve, bend.lowTick_, bend.highTick_,
                          bend.liquidity_, cntx.pool_.hash_);
    }

}
