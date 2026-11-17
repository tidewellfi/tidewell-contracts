// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// Receives protocol fees. Implemented later by the RevenueRouter, which pays referral rewards first.
interface IRevenueSink {
    /// Called by a vault right after it sent `amount` of `token` (address zero = ETH) as protocol fee for `user`.
    function onProtocolFee(address user, address token, uint256 amount) external;
}

/// Returns the fee discount of a user in basis points (The Well and referral discounts). Capped by the factory.
interface IFeeDiscount {
    function discountBps(address user) external view returns (uint256);
}

interface ITidewellFactory {
    function keeper() external view returns (address);
    function paused() external view returns (bool);
    function positionManager() external view returns (address);
    function uniswapFactory() external view returns (address);
    function weth() external view returns (address);
    function feeRecipient() external view returns (address);
    function protocolFeeBps() external view returns (uint256);
    function feeDiscount() external view returns (address);
    function maxSlippageBps() external view returns (uint256);
    function minCooldown() external view returns (uint32);
    function cardinalityTarget() external view returns (uint16);
    function maxGasPrice() external view returns (uint256);
    function maxRefundWei() external view returns (uint256);
    function refundOverheadGas() external view returns (uint256);
    function checkDeposit(address token, uint256 amount) external view;
    function checkPrice(address pool) external view;
    function checkOracle(address t0, address t1, uint160 sqrtPriceX96) external view returns (bool);
    function maxTickDeviation() external view returns (int24);
    function poolManager() external view returns (address);
    function positionManagerV4() external view returns (address);
    function permit2() external view returns (address);
    function allowedHook(address hook) external view returns (bool);
    function swapper() external view returns (address);
    function swapPool(uint8 kind, address t0, address t1)
        external
        view
        returns (uint24 fee, int24 tickSpacing, address hooks);
    function feeRank(address token) external view returns (uint8);
    function isVault(address vault) external view returns (bool);
}
