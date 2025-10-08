// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

// enum CirclesType {
//     Demurrage, // 0
//     Inflation // 1
// }

interface IERC20Lift {
    type CirclesType is uint8;

    error CirclesAmountOverflow(uint256 amount, uint8 code);
    error CirclesErrorAddressUintArgs(address, uint256, uint8);
    error CirclesErrorNoArgs(uint8);
    error CirclesErrorOneAddressArg(address, uint8);
    error CirclesIdMustBeDerivedFromAddress(uint256 providedId, uint8 code);
    error CirclesInvalidCirclesId(uint256 id, uint8 code);
    error CirclesInvalidParameter(uint256 parameter, uint8 code);
    error CirclesProxyAlreadyInitialized();
    error CirclesReentrancyGuard(uint8 code);

    event ERC20WrapperDeployed(address indexed avatar, address indexed erc20Wrapper, uint8 circlesType);
    event ProxyCreation(address proxy, address masterCopy);

    function ERC20_WRAPPER_SETUP_CALLPREFIX() external view returns (bytes4);
    function ensureERC20(address _avatar, uint8 _circlesType) external returns (address);
    function erc20Circles(uint8, address) external view returns (address);
    function hub() external view returns (address);
    function masterCopyERC20Wrapper(uint256) external view returns (address);
    function nameRegistry() external view returns (address);
}
