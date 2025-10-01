// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.24;

enum CirclesType {
    Demurrage,
    Inflation
}

interface IERC20Lift {
    function ensureERC20(address avatar, CirclesType circlesType) external returns (address);
    function erc20Circles(CirclesType circlesType, address avatar) external view returns (address);
}
