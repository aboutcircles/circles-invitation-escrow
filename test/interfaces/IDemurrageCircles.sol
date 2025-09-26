// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.24;

struct DiscountedBalance {
    uint192 balance;
    uint64 lastUpdatedDay;
}

interface IDemurrageCircles {
    function discountedBalances(address) external view returns (DiscountedBalance memory);
}
