# Uni-LBP

A capital-efficient liquidity bootstrapping pool (LBP) for Uniswap V4 via hooks.

## Overview

Uni-LBP is a Uniswap v4 pool, allowing tokens to be sold at a linearly decreasing price. By leveraging v4 hooks, it emulates the functionality of Balancer's LBP. The pool smoothly increases liquidity and sell pressure based on a set schedule, ensuring accurate price discovery, equality for all purchasers, and reduced bot effectiveness.

### Benefits

In addition to typical LBP advantages, Uni-LBP offers:

- **No initial capital requirements**: Only the bootstrapping token is needed.
- **Capital efficiency**: Thanks to Uniswap v4's concentrated liquidity.
- **Limit orders**: Enables traders to place effective limit orders by adding single-sided liquidity.
- **Gas efficiency**: Optimized for lower transaction costs.

## Mechanism

Before allowing a swap in any epoch (defaulted at 1 hour but customizable), the pool adjusts its liquidity position based on the elapsed bootstrapping time. Over time, liquidity is progressively added. The quantity and minimum range of this liquidity decreases linearly:

- Price range equation: `(maxTick - targetMinTick) / (maxTick - minTick) = timeElapsed / timeTotal`
- Target liquidity equation: `(targetLiquidity / totalAmount) = timeElapsed / timeTotal`

If the price is within our liquidity range, additional liquidity, matching the target amount, will be sold into the pool. This drives the price downwards until it exits the range, after which liquidity provision continues. This ensures efficient price discovery and liquidity provisioning at the best prices.

The contract is easily adaptable to variances in price decay mechanisms such that the provided liquidity is optimal for the intended purpose.

## Todo

- [ ] Native currency support
- [ ] Different price decay functions
- [ ] Decaying upper bound of liquidity range

## License

This project is licensed under the MIT License.

## Disclaimer

This is experimental software and is provided on an "as is" and "as available" basis. We do not give any warranties and will not be liable for any loss incurred through any use of this codebase.