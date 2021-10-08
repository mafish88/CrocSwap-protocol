import { BigNumber, BytesLike, ethers } from 'ethers';
import { OrderDirective, PassiveDirective, SwapDirective, PoolDirective, ConcentratedBookend, ConcentratedDirective, SettlementDirective, HopDirective, encodeOrderDirective } from './EncodeOrder';

export function singleHop (open: string, close: string, pool: PoolDirective): OrderDirective {
    return {
        open: simpleSettle(open),
        hops: [ { settlement: simpleSettle(close), pools: [pool], 
            improve: { isEnabled: false, useBaseSide: false },
            chain: { rollExit: false, swapDefer: false}} ]
    }
}

export function simpleSettle (token: string): SettlementDirective {
    return { token: token, limitQty: BigNumber.from("100000000000000000"),
        dustThresh: BigNumber.from(0), useReserves: false }
}

export function simpleMint (poolIdx: number, lowerTick: number, upperTick: number, liq: number): PoolDirective  {
     return { 
        poolIdx: poolIdx,
        passive: {
            ambient: { isAdd: false, liquidity: BigNumber.from(0) },
            concentrated: [{ openTick: lowerTick,
                bookends: [{ closeTick: upperTick, 
                    isAdd: BigNumber.from(liq).gte(0), liquidity: BigNumber.from(liq).abs()}]
            }]
        },
        passivePost: {
            ambient: { isAdd: false, liquidity: BigNumber.from(0) },
            concentrated: [{ openTick: 0,
                bookends: [] }]
        },
        swap: {
            liqMask: 0,
            isBuy: false,
            inBaseQty: false,
            qty: BigNumber.from(0),
            limitPrice: BigNumber.from(0)
        }
    }
}

export function simpleSwap (poolIdx: number, isBuy: boolean, inBaseQty: boolean, 
    qty: number, limitPrice: BigNumber): PoolDirective  {
    return { 
       poolIdx: poolIdx,
       passive: {
        ambient: { isAdd: false, liquidity: BigNumber.from(0) },
        concentrated: [{ openTick: 0,
            bookends: [] }]
       },
       passivePost: {
           ambient: { isAdd: false, liquidity: BigNumber.from(0) },
           concentrated: [{ openTick: 0,
               bookends: [] }]
       },
       swap: {
           liqMask: 0,
           isBuy: isBuy,
           inBaseQty: inBaseQty,
           qty: BigNumber.from(qty),
           limitPrice: BigNumber.from(limitPrice)
       }
   }
}
