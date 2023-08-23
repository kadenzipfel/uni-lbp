# Uni-LBP

Uniswap V4 hook-enabled, capital efficient, liquidity bootstrapping pool.

## Overview

Uni-LBP is a Uniswap v4 liquidity bootstrapping pool enabled by v4 hooks. Similar to Balancer's LBP, the pool allows for a token to be sold at a linearly decreasing price. The pool gradually increases liquidity and sell pressure along a pre-defined schedule, allowing for accurate price discovery while providing equal opportunity to every purchaser and disincentivizing usage of bots.

### Benefits

Beyond the general advantages of LBPs, this pool in particular has a few **additional benefits**:

- Zero starting capital requirements (excluding the token to be bootstrapped)
    - By providing single sided liquidity and selling into the pool, unlike other LBPs, no liquidity is required for the other token in the pool
- Capital efficient
    - With Uniswap v4 concentrated liquidity
- Limit orders
    - Traders can effectively place limit orders on the pool by adding single sided with the other token
- Gas efficient

## Mechanism

Every epoch (default 1 hour but can be defined as any period of time), before a swap can take place, the pool syncs a liquidity position volume and range corresponding to the amount of time which has passed in the defined bootstrapping period. As time progresses, liquidity is incrementally introduced to the pool. The quantity and lower bound of this liquidity diminishes linearly according to:

The ratio of the difference between the current target minimum tick and the maximum tick to the overall range (maxTick - minTick) equals the fraction of elapsed time to the total duration:
`(maxTick - targetMinTick) / (maxTick - minTick) = timeElapsed / timeTotal`

The proportion of target liquidity to the total amount mirrors the ratio of elapsed time to the total duration:
`(targetLiquidity / totalAmount) = timeElapsed / timeTotal`

While the price is in range of our liquidity position, additional liquidity to be provided following the target amount of liquidity will be sold into the pool, pushing the price down until it is out of range before continuing to provide liquidity. This allows for efficient price discovery and liquidity at optimal prices.

The contract is easily adaptable to variances in price decay mechanisms such that the provided liquidity is optimal for the intended purpose.

## Todo

- [ ] Native currency support
- [ ] Different price decay functions
- [ ] Decaying upper bound of liquidity range

## License

This project is licensed under the MIT License.

## Disclaimer

This is experimental software and is provided on an "as is" and "as available" basis. We do not give any warranties and will not be liable for any loss incurred through any use of this codebase.