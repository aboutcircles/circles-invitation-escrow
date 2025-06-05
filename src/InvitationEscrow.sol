// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Demurrage} from "src/Demurrage.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract InvitationEscrow is Demurrage {
    /*//////////////////////////////////////////////////////////////
                             Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a function is called by any address that is not the HubV2.
    error OnlyHub();

    /// @notice Thrown when the invitation escrow is attempted by a non-human avatar address in the Hub.
    error OnlyHumanAvatarsAreInviters();

    /// @notice Thrown when the invitation is attempted by an operator or from other avatar address than CRC token.
    error OnlyInviter();

    /// @notice Thrown when the received CRC amount is less than `MIN_CRC_AMOUNT` or more than `MAX_CRC_AMOUNT`.
    /// @param received The actual CRC amount received.
    error EscrowedCRCAmountOutOfRange(uint256 received);

    error InvalidEncoding();

    error InviteeAlreadyRegistered();

    error InvalidInvitee();

    error InviteAlreadyEscrowed();

    error InvalidEscrow();

    /*//////////////////////////////////////////////////////////////
                             Events
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when a invitation for `invitee` is escrowed by `inviter`.
     * @param inviter The address that locked tokens into escrow for the invitee.
     * @param invitee The address designated to use the escrowed tokens upon accepting the invitation.
     * @param amount The amount of tokens that were placed into escrow.
     */
    event InvitationEscrowed(address indexed inviter, address indexed invitee, uint256 indexed amount);

    /**
     * @notice Emitted when an invitee successfully claims (uses) the escrowed invitation.
     * @param inviter The address that originally escrowed tokens for the invitee.
     * @param invitee The address that claimed the escrowed tokens.
     * @param amount  The amount of tokens that were released from escrow.
     */
    event InvitationRedeemed(address indexed inviter, address indexed invitee, uint256 indexed amount);

    /**
     * @notice Emitted when the escrow for an unused invitation is returned to its inviter
     *         because the invitee claimed a different inviter’s escrow.
     * @param inviter The address whose escrow was returned.
     * @param invitee The address for which the original escrow was unused.
     * @param amount  The amount of tokens that were refunded to the inviter.
     */
    event InvitationRefunded(address indexed inviter, address indexed invitee, uint256 indexed amount);

    /**
     * @notice Emitted when an inviter explicitly revokes their escrowed invitation before it’s claimed.
     * @param inviter The address that revoked their escrow.
     * @param invitee The address that would have been entitled to claim (now revoked).
     * @param amount  The amount of tokens that were taken back by the inviter.
     */
    event InvitationRevoked(address indexed inviter, address indexed invitee, uint256 indexed amount);

    /*//////////////////////////////////////////////////////////////
                           Constants
    //////////////////////////////////////////////////////////////*/

    /// @dev A non-zero “null” pointer used to mark the start/end of the list.
    address private constant SENTINEL = address(0x1);

    /// @notice Circles Hub v2.
    IHub public constant HUB_V2 = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));

    /// @notice Minimum amount of Circles (ERC1155) to escrow for one invitation. 52 days of demurrage.
    uint256 public constant MIN_CRC_AMOUNT = 97 ether;

    /// @notice Maximum amount of Circles (ERC1155) to escrow for one invitation. 205 days of demurrage.
    uint256 public constant MAX_CRC_AMOUNT = 100 ether;

    /*//////////////////////////////////////////////////////////////
                            Storage
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Bidirectional linked list connecting inviters to their invitees and invitees to their inviters.
     * @dev When accessed as invitationLinkedList[inviter], this mapping links to invitee linked list.
     *      When accessed as invitationLinkedList[invitee], it links to inviters linked list.
     *      A sentinel address is used as the head of each list.
     */
    mapping(address inviterOrInvitee => mapping(address => address) inviteesOrInviters) internal invitationLinkedList;

    mapping(address inviter => mapping(address invitee => DiscountedBalance)) internal escrowedAmounts;

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
                         Invitation Logic
    //////////////////////////////////////////////////////////////*/

    function redeemInvitation(address inviter) external nonReentrant {
        DiscountedBalance memory discountedBalance = escrowedAmounts[inviter][msg.sender];

        if (discountedBalance.balance == 0) revert InvalidEscrow();

        address prevInviter = invitationLinkedList[msg.sender][SENTINEL];

        while (prevInviter != SENTINEL) {
            address currInviter = prevInviter;
            // next inviter
            prevInviter = invitationLinkedList[msg.sender][prevInviter];

            uint256 amount = _revokeInvitation(currInviter, msg.sender);
            if (currInviter != inviter) {
                // here transfer ERC20
                _wrapAndTransfer(currInviter, amount);

                emit InvitationRefunded(currInviter, msg.sender, amount);
            } else {
                // here transfer ERC1155
                HUB_V2.safeTransferFrom(address(this), currInviter, uint256(uint160(currInviter)), amount, "");

                emit InvitationRedeemed(currInviter, msg.sender, amount);
            }
        }
    }

    function revokeInvitation(address invitee) external {
        uint256 amount = _revokeInvitation(msg.sender, invitee);
        // transfer amount to inviter as wrapped demurrage ERC20
        _wrapAndTransfer(msg.sender, amount);

        emit InvitationRevoked(msg.sender, invitee, amount);
    }

    function revokeAllInvitations() external {
        address prevInvitee = invitationLinkedList[msg.sender][SENTINEL];
        if (prevInvitee == address(0) || prevInvitee == SENTINEL) return;

        uint256 amount;
        while (prevInvitee != SENTINEL) {
            address invitee = prevInvitee;
            // next invitee
            prevInvitee = invitationLinkedList[msg.sender][prevInvitee];
            uint256 revokedAmount = _revokeInvitation(msg.sender, invitee);
            amount += revokedAmount;

            emit InvitationRevoked(msg.sender, invitee, revokedAmount);
        }

        // transfer amount to inviter as wrapped demurrage ERC20
        _wrapAndTransfer(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                           Callback
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice ERC1155 callback invoked when HubV2 transfers CRC tokens to this contract.
     * @dev This function ensures that:
     *      1. The caller is HubV2.
     *      2. The correct CRC amount (97 - 100 CRC) is transferred.
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

        address inviter = address(uint160(id));
        if (!HUB_V2.isHuman(inviter)) revert OnlyHumanAvatarsAreInviters();

        if (operator != from || from != inviter) revert OnlyInviter();

        if (value < MIN_CRC_AMOUNT || value > MAX_CRC_AMOUNT) revert EscrowedCRCAmountOutOfRange(value);

        if (data.length != 32) revert InvalidEncoding();

        // decode the invitee address from `data`
        address invitee = abi.decode(data, (address));

        // check that invitee is not avatar - not registered yet
        if (HUB_V2.avatars(invitee) != address(0)) revert InviteeAlreadyRegistered();

        if (invitee == address(0)) revert InvalidInvitee();

        // check double-invite
        if (escrowedAmounts[inviter][invitee].balance != 0) revert InviteAlreadyEscrowed();

        // account escrow
        uint64 day = day(block.timestamp);

        escrowedAmounts[inviter][invitee] = DiscountedBalance({balance: uint192(value), lastUpdatedDay: day});

        // insert links into invite linked lists
        _insertInvitation(inviter, invitee);

        _insertInvitation(invitee, inviter);

        emit InvitationEscrowed(inviter, invitee, value);

        return this.onERC1155Received.selector;
    }

    /*//////////////////////////////////////////////////////////////
                           View functions
    //////////////////////////////////////////////////////////////*/

    function getInviters(address invitee) external view returns (address[] memory inviters) {
        inviters = _getInviteesOrInviters(invitee);
    }

    function getInvitees(address inviter) external view returns (address[] memory invitees) {
        invitees = _getInviteesOrInviters(inviter);
    }

    function getEscrowedAmountAndDays(address inviter, address invitee)
        external
        view
        returns (uint256 escrowedAmount, uint64 days_)
    {
        DiscountedBalance memory discountedBalance = escrowedAmounts[inviter][invitee];
        days_ = day(block.timestamp) - discountedBalance.lastUpdatedDay;
        escrowedAmount = _calculateDiscountedBalance(discountedBalance.balance, days_);
    }

    /*//////////////////////////////////////////////////////////////
                           Internal functions
    //////////////////////////////////////////////////////////////*/

    function _revokeInvitation(address inviter, address invitee) internal returns (uint256 amount) {
        DiscountedBalance memory discountedBalance = escrowedAmounts[inviter][invitee];

        if (discountedBalance.balance == 0) revert InvalidEscrow();
        // remove escrow
        delete escrowedAmounts[inviter][invitee];

        // remove links in invitation linked lists
        _removeInvitation(inviter, invitee);

        _removeInvitation(invitee, inviter);

        // calculate amount after demurrage
        amount = _calculateDiscountedBalance(
            discountedBalance.balance, day(block.timestamp) - discountedBalance.lastUpdatedDay
        );
    }

    function _wrapAndTransfer(address avatar, uint256 amount) internal {
        address demurrageERC20 = HUB_V2.wrap(avatar, amount, uint8(0));
        IERC20(demurrageERC20).transfer(avatar, amount);
    }

    function _insertInvitation(address inviterOrInvitee, address inviteeOrInviter) internal {
        // load the current head; if unset (zero), treat as empty and point to SENTINEL
        address previous = invitationLinkedList[inviterOrInvitee][SENTINEL];
        if (previous == address(0)) {
            previous = SENTINEL;
        }

        // link the new node to the old head
        invitationLinkedList[inviterOrInvitee][inviteeOrInviter] = previous;
        // update head pointer to the new node
        invitationLinkedList[inviterOrInvitee][SENTINEL] = inviteeOrInviter;
    }

    function _removeInvitation(address inviterOrInvitee, address inviteeOrInviter) internal {
        // load the element removing is linking to; if unset (zero), treat as removing element not in a list
        address previousElement = invitationLinkedList[inviterOrInvitee][inviteeOrInviter];
        if (previousElement == address(0)) {
            // means not in linked list, nothing to remove
            return;
        }

        address current = SENTINEL;
        address previous;

        while (current != inviteeOrInviter) {
            previous = current;
            current = invitationLinkedList[inviterOrInvitee][current];
        }

        // link the node previously linking to the removed to element the removed was linking to
        invitationLinkedList[inviterOrInvitee][previous] = previousElement;
        // remove link
        invitationLinkedList[inviterOrInvitee][inviteeOrInviter] = address(0);
    }

    function _getInviteesOrInviters(address inviterOrInvitee)
        internal
        view
        returns (address[] memory inviteesOrInviters)
    {
        address previous = invitationLinkedList[inviterOrInvitee][SENTINEL];
        if (previous == address(0) || previous == SENTINEL) return inviteesOrInviters;

        assembly {
            // calculate inviterOrInvitee storage slot
            mstore(0, inviterOrInvitee)
            mstore(0x20, invitationLinkedList.slot)
            let inviterOrInviteeSlot := keccak256(0, 0x40)
            // assign first element from solidity
            let inviteeOrInviter := previous
            // while inviteeOrInviter != SENTINEL
            for {} iszero(eq(inviteeOrInviter, 0x01)) {} {
                // extend memory size
                mstore(0x40, add(mload(0x40), 0x20))
                // increase array length
                mstore(inviteesOrInviters, add(mload(inviteesOrInviters), 0x01))
                // push new element to array
                mstore(add(inviteesOrInviters, mul(mload(inviteesOrInviters), 0x20)), inviteeOrInviter)

                // calculate slot for next element in linked list
                mstore(0, inviteeOrInviter)
                mstore(0x20, inviterOrInviteeSlot)
                let nextSlot := keccak256(0, 0x40)

                // move to next element in linked list
                inviteeOrInviter := sload(nextSlot)
            }
        }
    }
}
