import { TestPool, makeTokenPool, Token } from './FacadePool'
import { expect } from "chai";
import "@nomiclabs/hardhat-ethers";
import { ethers } from 'hardhat';
import { toSqrtPrice, fromSqrtPrice, maxSqrtPrice, minSqrtPrice, ZERO_ADDR, MAX_PRICE } from './FixedPoint';
import { solidity } from "ethereum-waffle";
import chai from "chai";
import { MockERC20 } from '../typechain/MockERC20';
import { OrderDirective, SettlementDirective, HopDirective, PoolDirective, AmbientDirective, ConcentratedDirective, encodeOrderDirective } from './EncodeOrder';
import { BigNumber } from 'ethers';
import { makeRe } from 'minimatch';

chai.use(solidity);

describe('Pool Rebalance', () => {
    let test: TestPool
    let baseToken: Token
    let quoteToken: Token
    const feeRate = 225 * 100

    beforeEach("deploy",  async () => {
       test = await makeTokenPool()
       baseToken = await test.base
       quoteToken = await test.quote

       await test.initPool(feeRate, 0, 1, 1.0)
       test.useHotPath = true;
    })

    function makeRebalOrder(): OrderDirective {
        let open: SettlementDirective = {
            token: baseToken.address,
            limitQty: BigNumber.from("1000000000000000000"),
            dustThresh: BigNumber.from(0),
            useSurplus: true
        }

        let close: SettlementDirective = {
            token: quoteToken.address,
            limitQty: BigNumber.from("1000000000000000000"),
            dustThresh: BigNumber.from(0),
            useSurplus: true
        }

        let order: OrderDirective = { 
            schemaType: 1,
            open: open,
            hops: []
        }

        let hop: HopDirective = {
            pools: [],
            settlement: close,
            improve: { isEnabled: false, useBaseSide: false }
        }
        order.hops.push(hop)

        let emptyAmbient: AmbientDirective = {
            isAdd: false,
            liquidity: BigNumber.from(0)
        }

        let firstDir: PoolDirective = {
            poolIdx: BigNumber.from(test.poolIdx),
            passive: { ambient: emptyAmbient, concentrated: [] },
            swap: {
                isBuy: true,
                inBaseQty: true,
                qty: BigNumber.from(5000),
                rollType: 4,
                limitPrice: MAX_PRICE
            },
            chain: {
                rollExit: false,
                swapDefer: true,
                offsetSurplus: false
            }
        }

        let burnLp: ConcentratedDirective = {
            openTick: -500,
            bookends: [
                { closeTick: -200, isAdd: false, liquidity: BigNumber.from(1000*1024) }
            ]
        }
        firstDir.passive.concentrated.push(burnLp)
        hop.pools.push(firstDir)

        let secondDir: PoolDirective = {
            poolIdx: BigNumber.from(test.poolIdx),
            passive: { ambient: emptyAmbient, concentrated: [] },
            swap: {
                isBuy: true,
                inBaseQty: true,
                qty: BigNumber.from(0),
                limitPrice: MAX_PRICE
            },
            chain: {
                rollExit: false,
                swapDefer: true,
                offsetSurplus: false
            }
        }

        let mintLp: ConcentratedDirective = {
            openTick: -100,
            bookends: [
                { closeTick: 100, isAdd: false, 
                    rollType: 5,
                    liquidity: BigNumber.from(0) }
            ]
        }
        secondDir.passive.concentrated.push(mintLp)
        hop.pools.push(secondDir)

        return order
    }


    it("rebalance range", async() => {
        await test.testMint(-1000, 1000, 100000)
        await test.testMint(-500, -200, 1000);

        let order = makeRebalOrder()
        let tx = await test.testOrder(order);

        let baseSurp = (await test.query).querySurplus(await (await test.trader).getAddress(), baseToken.address)
        let quoteSurp = (await test.query).querySurplus(await (await test.trader).getAddress(), quoteToken.address)

        expect(await baseSurp).to.be.gt(0)
        expect(await baseSurp).to.be.lt(100)
        expect(await quoteSurp).to.be.gt(0)
        expect(await quoteSurp).to.be.lt(100)

        test.snapStart()
        await test.testBurn(-100, 100, 1000)
        let basePos = await test.snapBaseOwed()
        let quotePos = await test.snapQuoteOwed()
        expect(basePos).to.be.equal(-5181)
        expect(quotePos).to.be.equal(-5032)        
    })


    it("rebalance gas", async() => {
        await test.testMint(-1000, 1000, 100000)
        await test.testMint(-500, -200, 1000);

        let order = makeRebalOrder()
        let tx = await test.testOrder(order);

        expect((await tx.wait()).gasUsed).to.lt(315000)
    })
    
})