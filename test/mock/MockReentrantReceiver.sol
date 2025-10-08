// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

interface IERC1155Receiver {
    function onERC1155Received(address, address from, uint256 id, uint256 value, bytes calldata data)
        external
        returns (bytes4);

    function redeemInvitation(address inviter) external;
}

contract MockReentrantReceiver {
    address invitationEscrow;

    constructor(address _invitationEscrow) {
        invitationEscrow = _invitationEscrow;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        IERC1155Receiver(invitationEscrow).redeemInvitation(address(this));

        return bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"));
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"));
    }
}
