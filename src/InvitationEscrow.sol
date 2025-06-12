// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Demurrage} from "src/Demurrage.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title InvitationEscrow
 * @notice Manages invitation escrows of CRC tokens between inviters and invitees,
 *         applying demurrage over time and allowing redemption or revocation of invitations.
 * @dev Inherits Demurrage to calculate time‐discounted balances. Only the registered humans in Hub V2 can transfer
 *      CRC tokens into this contract. Inviters must be “human” avatars and invitees must be unregistered.
 */
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

    /// @notice Thrown when calldata encoding for the invitee address is invalid.
    error InvalidEncoding();

    /// @notice Thrown when the invitee is already registered in the Hub.
    error InviteeAlreadyRegistered();

    /// @notice Thrown when the invitee address is zero.
    error InvalidInvitee();

    /// @notice Thrown when attempting to escrow for an invitee that already has an active escrow from this inviter.
    error InviteAlreadyEscrowed();

    /// @notice Thrown when attempting to redeem or revoke an invitation that does not exist.
    error InvalidEscrow();

    /// @notice Thrown when trust from inviter to invitee is not present.
    error MissingOrExpiredTrust();

    /*//////////////////////////////////////////////////////////////
                             Events
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when an invitation for `invitee` is escrowed by `inviter`.
     * @param inviter The address that locked tokens into escrow for the invitee.
     * @param invitee The address designated to use the escrowed tokens upon accepting the invitation.
     * @param amount  The amount of tokens that were placed into escrow.
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

    /// @dev A non-zero “null” pointer used to mark the start/end of the linked list.
    address private constant SENTINEL = address(0x1);

    /// @notice Circles Hub v2 contract address.
    IHub public constant HUB_V2 = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));

    /// @notice Minimum amount of Circles (ERC1155) to escrow for one invitation (52 days of demurrage).
    uint256 public constant MIN_CRC_AMOUNT = 97 ether;

    /// @notice Maximum amount of Circles (ERC1155) to escrow for one invitation (205 days of demurrage).
    uint256 public constant MAX_CRC_AMOUNT = 100 ether;

    /*//////////////////////////////////////////////////////////////
                            Storage
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Bidirectional linked list connecting inviters to their invitees and invitees to their inviters.
     * @dev When accessed as invitationLinkedList[inviter], this mapping links each invitee (or sentinel)
     *      to the next invitee in that inviter’s list. When accessed as invitationLinkedList[invitee],
     *      it links each inviter (or sentinel) to the next inviter in that invitee’s list.
     *      A sentinel address is used as the head of each list (SENTINEL).
     */
    mapping(address inviterOrInvitee => mapping(address => address) inviteesOrInviters) internal invitationLinkedList;

    /// @notice Mapping from inviter to invitee to the discounted balance (CRC amount).
    mapping(address inviter => mapping(address invitee => DiscountedBalance)) internal escrowedAmounts;

    /*//////////////////////////////////////////////////////////////
                            Modifiers
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev A minimal non-reentrancy guard using transient storage.
     *      Prevents nested (reentrant) calls within any function marked `nonReentrant`.
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

    /**
     * @notice Redeems the invitation escrow from `inviter` for the calling `msg.sender` (invitee).
     * @dev  Iterates through all inviters linked to `msg.sender`, revokes each invitation,
     *       refunds any other inviters’ escrowed amounts, and finally transfers the ERC1155 CRC
     *       tokens back to the original inviter who matches the provided `inviter` address.
     * @param inviter The address of the inviter whose escrowed invitation is being redeemed by `msg.sender`.
     * Reverts If `msg.sender` has no valid escrow from `inviter` (`InvalidEscrow`).
     */
    function redeemInvitation(address inviter) external nonReentrant {
        DiscountedBalance memory discountedBalance = escrowedAmounts[inviter][msg.sender];

        if (discountedBalance.balance == 0) revert InvalidEscrow();

        if (!HUB_V2.isTrusted(inviter, msg.sender)) revert MissingOrExpiredTrust();

        address prevInviter = invitationLinkedList[msg.sender][SENTINEL];

        while (prevInviter != SENTINEL) {
            address currInviter = prevInviter;
            // next inviter
            prevInviter = invitationLinkedList[msg.sender][prevInviter];

            uint256 amount = _revokeInvitation(currInviter, msg.sender);
            if (currInviter != inviter) {
                // Transfer wrapped ERC20 (demurrage) back to other inviters
                _wrapAndTransfer(currInviter, amount);

                emit InvitationRefunded(currInviter, msg.sender, amount);
            } else {
                // Transfer the original ERC1155 CRC back to the matched inviter
                HUB_V2.safeTransferFrom(address(this), currInviter, uint256(uint160(currInviter)), amount, "");

                emit InvitationRedeemed(currInviter, msg.sender, amount);
            }
        }
    }

    /**
     * @notice Revokes a single invitation escrow created by `msg.sender` for a given `invitee`.
     * @dev  Deletes the escrowed balance, removes the inviter‐invitee links, wraps remaining demurrage
     *       amount into the ERC20 equivalent, and transfers it back to `msg.sender`.
     * @param invitee The address of the invitee whose escrow is being revoked.
     * Reverts If there is no active escrow between `msg.sender` and `invitee` (`InvalidEscrow`).
     */
    function revokeInvitation(address invitee) external {
        uint256 amount = _revokeInvitation(msg.sender, invitee);
        // Wrap and transfer the demurrage amount in ERC20 form back to the inviter
        _wrapAndTransfer(msg.sender, amount);

        emit InvitationRevoked(msg.sender, invitee, amount);
    }

    /**
     * @notice Revokes all active invitation escrows created by `msg.sender`.
     * @dev  Iterates through the entire invitee linked list for `msg.sender`, revokes each escrow,
     *       accumulates the total demurrage CRC amount, wraps it into ERC20 tokens,
     *       and transfers the entire sum back to `msg.sender`. Emits `InvitationRevoked` for each invitee.
     */
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

        // Transfer the total wrapped ERC20 to the inviter
        _wrapAndTransfer(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                           Callback
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice ERC1155 token callback invoked when HubV2 transfers CRC tokens to this contract for an invitation.
     * @dev  Verifies that the caller is `HUB_V2`, that the `inviter` avatar is human and is the `operator`,
     *       that `value` is within [MIN_CRC_AMOUNT, MAX_CRC_AMOUNT], and that `data` encodes a valid,
     *       unregistered `invitee` address. Then records the escrow, inserts bidirectional links,
     *       and emits `InvitationEscrowed`.
     * @param operator The address that initiated the transfer (must equal `from` and be the avatar).
     * @param from     The inviter’s address (avatar) which sent CRC tokens.
     * @param id       The CRC token ID, equal to the numeric representation of the inviter’s avatar address.
     * @param value    The amount of CRC tokens being transferred into escrow.
     * @param data     Calldata containing the 32‐byte encoded invitee address.
     * @return         The function selector (`this.onERC1155Received.selector`) to confirm receipt.
     * Reverts If caller is not HUB_V2 (`OnlyHub`), inviter is not a human avatar (`OnlyHumanAvatarsAreInviters`),
     *         operator/from mismatch (`OnlyInviter`), `value` out of allowed range (`EscrowedCRCAmountOutOfRange`),
     *         `data` length invalid (`InvalidEncoding`), invitee is already registered (`InviteeAlreadyRegistered`),
     *         invitee is zero address (`InvalidInvitee`), or there is already an escrow for this pair (`InviteAlreadyEscrowed`).
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

        // Decode the invitee address from `data`
        address invitee = abi.decode(data, (address));

        // Ensure invitee is not already registered as an avatar
        if (HUB_V2.avatars(invitee) != address(0)) revert InviteeAlreadyRegistered();

        if (invitee == address(0)) revert InvalidInvitee();

        // Ensure no existing escrow between inviter and invitee
        if (escrowedAmounts[inviter][invitee].balance != 0) revert InviteAlreadyEscrowed();

        if (!HUB_V2.isTrusted(inviter, invitee)) revert MissingOrExpiredTrust();

        // Record the escrowed DiscountedBalance with current day
        uint64 day = day(block.timestamp);
        escrowedAmounts[inviter][invitee] = DiscountedBalance({balance: uint192(value), lastUpdatedDay: day});

        // Insert into both inviter→invitee and invitee→inviter linked lists
        _insertInvitation(inviter, invitee);
        _insertInvitation(invitee, inviter);

        emit InvitationEscrowed(inviter, invitee, value);

        return this.onERC1155Received.selector;
    }

    /*//////////////////////////////////////////////////////////////
                           View functions
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns all active inviters for a given `invitee`.
     * @param invitee The address whose inviter list is requested.
     * @return inviters An array of inviter addresses linked to the given `invitee`.
     */
    function getInviters(address invitee) external view returns (address[] memory inviters) {
        inviters = _getInviteesOrInviters(invitee);
    }

    /**
     * @notice Returns all active invitees for a given `inviter`.
     * @param inviter The address whose invitee list is requested.
     * @return invitees An array of invitee addresses linked to the given `inviter`.
     */
    function getInvitees(address inviter) external view returns (address[] memory invitees) {
        invitees = _getInviteesOrInviters(inviter);
    }

    /**
     * @notice Returns the current escrowed amount (after demurrage) and days since last update
     *         for a given `inviter`‐`invitee` pair.
     * @param inviter The address of the inviter in the pair.
     * @param invitee The address of the invitee in the pair.
     * @return escrowedAmount The CRC token amount after applying demurrage up to the current block timestamp.
     * @return days_          The number of days passed since the balance was last updated.
     */
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

    /**
     * @notice Internal helper to revoke a single invitation escrow between `inviter` and `invitee`.
     * @dev  Deletes the escrowed `DiscountedBalance`, removes both directions of the linked list entries,
     *       and computes the demurrage amount to return. Does not perform any token transfers.
     * @param inviter The address of the inviter whose escrow is being revoked.
     * @param invitee The address of the invitee for which the escrow is being revoked.
     * @return amount   The CRC token amount after applying demurrage from lastUpdatedDay to now.
     * Reverts If there is no active escrow (`InvalidEscrow`).
     */
    function _revokeInvitation(address inviter, address invitee) internal returns (uint256 amount) {
        DiscountedBalance memory discountedBalance = escrowedAmounts[inviter][invitee];

        if (discountedBalance.balance == 0) revert InvalidEscrow();
        // Remove escrow record
        delete escrowedAmounts[inviter][invitee];

        // Remove both directions of the linked list entries
        _removeInvitation(inviter, invitee);
        _removeInvitation(invitee, inviter);

        // Calculate demurrage‐adjusted balance
        amount = _calculateDiscountedBalance(
            discountedBalance.balance, day(block.timestamp) - discountedBalance.lastUpdatedDay
        );
    }

    /**
     * @notice Internal helper to wrap a demurrage‐adjusted CRC amount into ERC20 form and transfer to `avatar`.
     * @param avatar The address to receive the wrapped ERC20 tokens.
     * @param amount The CRC token amount to convert and transfer.
     */
    function _wrapAndTransfer(address avatar, uint256 amount) internal {
        address demurrageERC20 = HUB_V2.wrap(avatar, amount, uint8(0));
        IERC20(demurrageERC20).transfer(avatar, amount);
    }

    /**
     * @notice Internal helper to insert `inviteeOrInviter` into `inviterOrInvitee`’s linked list after the current head.
     * @dev  If the list is empty (no head), sets the head to SENTINEL and links accordingly.
     * @param inviterOrInvitee   The list owner, acting as inviter (linking an invitee) or invitee (linking an inviter).
     * @param inviteeOrInviter   The node being inserted (invitee if owner is inviter, or inviter if owner is invitee).
     */
    function _insertInvitation(address inviterOrInvitee, address inviteeOrInviter) internal {
        // Load the current head; if unset (zero), treat as empty and point to SENTINEL
        address previous = invitationLinkedList[inviterOrInvitee][SENTINEL];
        if (previous == address(0)) {
            previous = SENTINEL;
        }

        // Link the new node to the old head
        invitationLinkedList[inviterOrInvitee][inviteeOrInviter] = previous;
        // Update head pointer to the new node
        invitationLinkedList[inviterOrInvitee][SENTINEL] = inviteeOrInviter;
    }

    /**
     * @notice Internal helper to remove `inviteeOrInviter` from `inviterOrInvitee`’s linked list.
     * @dev  Traverses the linked list starting from SENTINEL until finding the node,
     *       then patches the pointers to unlink it. If not found, does nothing.
     * @param inviterOrInvitee   The list owner, acting as inviter (removing an invitee) or invitee (removing an inviter).
     * @param inviteeOrInviter   The node to remove (invitee if owner is inviter, or inviter if owner is invitee).
     */
    function _removeInvitation(address inviterOrInvitee, address inviteeOrInviter) internal {
        // Load the “next” pointer for inviteeOrInviter; if zero, not in list, return early
        address previousElement = invitationLinkedList[inviterOrInvitee][inviteeOrInviter];
        if (previousElement == address(0)) {
            return;
        }

        address current = SENTINEL;
        address previous;

        // Traverse until current == inviteeOrInviter
        while (current != inviteeOrInviter) {
            previous = current;
            current = invitationLinkedList[inviterOrInvitee][current];
        }

        // Link the node that pointed to inviteeOrInviter to whatever inviteeOrInviter pointed to
        invitationLinkedList[inviterOrInvitee][previous] = previousElement;
        // Clear the removed node’s pointer
        invitationLinkedList[inviterOrInvitee][inviteeOrInviter] = address(0);
    }

    /**
     * @notice Internal view helper to return a dynamic array of either invitees or inviters for a given `inviterOrInvitee`.
     * @dev  Traverses the linked list starting from SENTINEL, appending each node to an array, until reaching SENTINEL again.
     *      Uses inline assembly to read storage and build the array efficiently.
     * @param inviterOrInvitee The list owner whose invitee‐or‐inviter nodes are being collected.
     * @return inviteesOrInviters An array of addresses linked to `inviterOrInvitee`.
     */
    function _getInviteesOrInviters(address inviterOrInvitee)
        internal
        view
        returns (address[] memory inviteesOrInviters)
    {
        address previous = invitationLinkedList[inviterOrInvitee][SENTINEL];
        if (previous == address(0) || previous == SENTINEL) return inviteesOrInviters;

        assembly {
            // Calculate and store the storage slot for invitationLinkedList[inviterOrInvitee]
            mstore(0, inviterOrInvitee)
            mstore(0x20, invitationLinkedList.slot)
            mstore(0x20, keccak256(0, 0x40))
            // Store the array at the free memory location
            inviteesOrInviters := mload(0x40)
            // Update free memory pointer
            mstore(0x40, add(mload(0x40), 0x20))
            // Start with the first node from solidity
            let inviteeOrInviter := previous
            // While inviteeOrInviter != SENTINEL
            for {} iszero(eq(inviteeOrInviter, 0x01)) {} {
                // Increase free memory pointer by 0x20 for the new element
                mstore(0x40, add(mload(0x40), 0x20))
                // Increment array length
                mstore(inviteesOrInviters, add(mload(inviteesOrInviters), 0x01))
                // Store the new element in array
                mstore(add(inviteesOrInviters, mul(mload(inviteesOrInviters), 0x20)), inviteeOrInviter)

                // Compute the storage slot of invitationLinkedList[inviterOrInvitee][inviteeOrInviter]
                mstore(0, inviteeOrInviter)
                let nextSlot := keccak256(0, 0x40)

                // Move to next node
                inviteeOrInviter := sload(nextSlot)
            }
        }
    }
}
