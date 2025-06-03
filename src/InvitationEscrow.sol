// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Demurrage} from "src/Demurrage.sol";
import {IHub} from "src/interfaces/IHub.sol";

contract InvitationEscrow is Demurrage {
    /*//////////////////////////////////////////////////////////////
                             Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a function is called by any address that is not the HubV2.
    error OnlyHub();

    /// @notice Thrown when the invitation deposit is attempted by a non-human avatar address in the Hub.
    error OnlyHumanAvatarsAreInviters();

    /// @notice Thrown when the invitation is attempted by an operator or from other avatar address than submitted token.
    error OnlyInviter();

    /// @notice Thrown when the received CRC amount is less than `MIN_CRC_AMOUNT` or more than `MAX_CRC_AMOUNT`.
    /// @param received The actual CRC amount received.
    error SubmittedCRCAmountOutOfRange(uint256 received);

    /*//////////////////////////////////////////////////////////////
                           Constants
    //////////////////////////////////////////////////////////////*/

    /// @notice Circles Hub v2.
    IHub public constant HUB_V2 = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));

    /// @notice Minimum amount of Circles (ERC1155) to submit for one invitation.
    uint256 public constant MIN_CRC_AMOUNT = 97 ether;

    /// @notice Maximum amount of Circles (ERC1155) to submit for one invitation.
    uint256 public constant MAX_CRC_AMOUNT = 100 ether;

    /*//////////////////////////////////////////////////////////////
                            Modifiers
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev A minimal non-reentrancy guard using transient storage.
     *      See https://soliditylang.org/blog/2024/01/26/transient-storage/
     */
    modifier nonReentrant() {
        assembly {
            if tload(0) { revert(0, 0) }
            tstore(0, 1)
        }
        _;
        assembly {
            tstore(0, 0)
        }
    }

    /*//////////////////////////////////////////////////////////////
                           Callback
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice ERC1155 callback invoked when HubV2 transfers CRC tokens to this contract.
     * @dev This function ensures that:
     *      1. The caller is HubV2.
     *      2. The correct CRC amount (100 CRC) is transferred.
     *      3. The avatar (inviter) is human in HubV2 and transferring personal tokens to this contract.
     *      4. The inviter trusts the invitee.
     *      5. Accounts CRC to invitee and awaits to be resolved by invitee or revoked by inviter.
     * @param operator The address that initiated the transfer (must be the same as `from`/`avatar`).
     * @param from The address from which CRC tokens are sent (must be the avatar).
     * @param id The CRC token ID, which is the numeric representation of the avatar address.
     * @param value The amount of CRC tokens transferred.
     * @param data Encoded invitee address.
     * @return The function selector to confirm the ERC1155 receive operation.
     */
    function onERC1155Received(address operator, address from, uint256 id, uint256 value, bytes calldata data)
        external
        nonReentrant
        returns (bytes4)
    {
        if (msg.sender != address(HUB_V2)) revert OnlyHub();

        address avatar = address(uint160(id));
        if (!HUB_V2.isHuman(avatar)) revert OnlyHumanAvatarsAreInviters();

        if (operator != from || from != avatar) revert OnlyInviter();

        if (value < MIN_CRC_AMOUNT || value > MAX_CRC_AMOUNT) revert SubmittedCRCAmountOutOfRange(value);

        // decode the invitee address from `data`
        address invitee = abi.decode(data, (address));

        // account submission

        return this.onERC1155Received.selector;
    }
}
