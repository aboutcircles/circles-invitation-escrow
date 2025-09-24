// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {HubStorageWrites} from "test/helpers/HubStorageWrites.sol";
import {InvitationEscrow} from "src/InvitationEscrow.sol";
import {IHub} from "src/interfaces/IHub.sol";

/// @title InvitationEscrowTest
/// @dev Tests cover invitation creation, redemption, and revocation flows with edge cases
/// @dev Not covered branches:
///      1. nonReentranct: if tload(0) { revert(0, 0) }
///      2. _removeInvitation  if (previousElement == address(0)) {
///      3. revokeAllInviations if (balance < revokedAmount)
contract InvitationEscrowTest is Test, HubStorageWrites {
    /// @notice Structure representing a discounted balance with timestamp
    /// @dev Used for testing balance tracking over time
    struct DiscountedBalance {
        uint192 balance;
        uint64 lastUpdatedDay;
    }

    /// @notice Fork ID for Gnosis chain testing
    uint256 internal gnosisFork;

    /// @notice The InvitationEscrow contract instance under test
    InvitationEscrow public invitationEscrow;

    /// @notice Circles Hub V2 contract on Gnosis chain
    IHub public constant HUB_V2 = IHub(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8);

    /// @notice Sentinel address used in linked list operations
    address private constant SENTINEL = address(0x1);

    /// @notice Current day in Hub's time system
    uint64 internal TODAY;

    /// @notice Refer to InvitationEscrowed event in InvitationEscrow.sol
    event InvitationEscrowed(address indexed inviter, address indexed invitee, uint256 indexed amount);

    /// @notice Refer to InvitationRedeemed event in InvitationEscrow.sol
    event InvitationRedeemed(address indexed inviter, address indexed invitee, uint256 indexed amount);

    /// @notice Refer to InvitationRevoked event in InvitationEscrow.sol
    event InvitationRevoked(address indexed inviter, address indexed invitee, uint256 indexed amount);

    /// @notice Set up test environment with Gnosis fork and contract deployment
    /// @dev Creates a fork of Gnosis chain and deploys InvitationEscrow contract
    function setUp() public {
        console.log(address(this));
        // Fork from Gnosis
        gnosisFork = vm.createFork(vm.envString("GNOSIS_RPC"));
        vm.selectFork(gnosisFork);

        invitationEscrow = new InvitationEscrow();

        TODAY = HUB_V2.day(block.timestamp);
    }

    /// @notice Fuzz test for ERC1155 token reception and invitation creation
    /// @dev Tests various edge cases including access control, validation, and error conditions
    /// @param inviterId The inviter Id
    /// @param value The CRC amount to escrow
    /// @param inviteeId The invitee Id
    function testFuzzERC1155Received(uint160 inviterId, uint192 value, uint160 inviteeId) public {
        address inviter = address(uint160(inviterId));
        address invitee = address(uint160(inviteeId));
        if (
            inviter == address(this) || invitee == address(this) || inviter == SENTINEL || invitee == SENTINEL
                || inviter == address(0) || inviter == address(HUB_V2) || invitee == address(HUB_V2) || inviter == invitee
        ) return;

        _setCRCBalance(uint256(inviterId), inviter, HUB_V2.day(block.timestamp), value);

        vm.prank(inviter);
        vm.expectRevert(InvitationEscrow.OnlyHub.selector);
        invitationEscrow.onERC1155Received(inviter, inviter, inviterId, value, abi.encode(invitee));

        vm.prank(inviter);
        vm.expectRevert(InvitationEscrow.OnlyHumanAvatarsAreInviters.selector);
        HUB_V2.safeTransferFrom(inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee));

        _registerHuman(inviter);

        // Condition 1: inviter is human
        // Condition 2: inviter has enough CRC

        {
            address operator = makeAddr("operator");
            vm.assume(operator != inviter);

            vm.prank(inviter);
            HUB_V2.setApprovalForAll(operator, true);

            vm.prank(operator);
            vm.expectRevert(InvitationEscrow.OnlyInviter.selector);
            HUB_V2.safeTransferFrom(inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee));
        }

        if (uint256(value) < invitationEscrow.MIN_CRC_AMOUNT() || uint256(value) > invitationEscrow.MAX_CRC_AMOUNT()) {
            vm.prank(inviter);
            vm.expectRevert(
                abi.encodeWithSelector(InvitationEscrow.EscrowedCRCAmountOutOfRange.selector, uint256(value))
            );

            HUB_V2.safeTransferFrom(inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee));
        }

        value = 100 ether;
        _setCRCBalance(uint256(uint160(inviter)), inviter, HUB_V2.day(block.timestamp), value);

        // Condition 3: CRC value is correct
        {
            vm.prank(inviter);
            vm.expectRevert(InvitationEscrow.InvalidEncoding.selector);

            HUB_V2.safeTransferFrom(
                inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee, invitee)
            );
        }
        if (invitee == address(0)) {
            vm.prank(inviter);
            vm.expectRevert(InvitationEscrow.InvalidInvitee.selector);

            HUB_V2.safeTransferFrom(inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee));
            return;
        }

        // Condition 4: invitee is not address(0)

        {
            // transfer first
            vm.prank(inviter);
            vm.expectRevert(InvitationEscrow.MissingOrExpiredTrust.selector);

            HUB_V2.safeTransferFrom(inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee));
        }
        {
            // trust first, then transfer
            vm.startPrank(inviter);
            HUB_V2.trust(invitee, type(uint96).max);
            uint256 snapshot = vm.snapshot();

            HUB_V2.safeTransferFrom(inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee));

            _setCRCBalance(uint256(inviterId), inviter, HUB_V2.day(block.timestamp), value);

            // transfer again
            vm.expectRevert(InvitationEscrow.InviteAlreadyEscrowed.selector);

            HUB_V2.safeTransferFrom(inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee));
            vm.stopPrank();

            // Ensure invitee is an EOA
            vm.assume(invitee.code.length == 0);
            vm.startPrank(invitee);
            invitationEscrow.redeemInvitation(inviter);
            HUB_V2.registerHuman(inviter, bytes32(""));

            vm.stopPrank();

            _setCRCBalance(uint256(inviterId), inviter, HUB_V2.day(block.timestamp), value);

            vm.prank(inviter);
            vm.expectRevert(InvitationEscrow.InviteeAlreadyRegistered.selector);

            HUB_V2.safeTransferFrom(inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee));

            vm.revertTo(snapshot);
        }
        // Condition 5: inviter trusts invitee

        vm.prank(inviter);
        vm.expectEmit(address(invitationEscrow));
        emit InvitationEscrowed(inviter, invitee, value);
        HUB_V2.safeTransferFrom(inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee));
    }

    /// @notice Fuzz test for invitation redemption functionality
    /// @dev Tests invitation redemption with trust expiration and multiple inviters
    /// @param inviter1Id First inviter Id
    /// @param inviter2Id Second inviter Id
    /// @param inviteeId Invitee Id
    function testFuzzRedeemInvitation(uint160 inviter1Id, uint160 inviter2Id, uint160 inviteeId) public {
        address inviter1 = address(uint160(inviter1Id));
        address inviter2 = address(uint160(inviter2Id));
        address invitee = address(uint160(inviteeId));

        if (
            inviter1 == SENTINEL || inviter2 == SENTINEL || invitee == SENTINEL || inviter1 == address(HUB_V2)
                || inviter2 == address(HUB_V2) || invitee == address(HUB_V2) || inviter1 == address(0)
                || inviter2 == address(0) || invitee == address(0) || inviter1 == inviter2 || inviter1 == invitee
                || inviter2 == invitee
        ) return;

        vm.assume(HUB_V2.avatars(invitee) == address(0));

        uint192 value = 100 ether;
        _registerHuman(inviter1);
        _registerHuman(inviter2);
        _setCRCBalance(inviter1Id, inviter1, HUB_V2.day(block.timestamp), value);
        _setCRCBalance(inviter2Id, inviter2, HUB_V2.day(block.timestamp), value);

        {
            vm.prank(invitee);
            vm.expectRevert(InvitationEscrow.InvalidEscrow.selector);
            invitationEscrow.redeemInvitation(inviter1);
        }

        uint256 snapShot;
        {
            vm.startPrank(inviter1);
            HUB_V2.trust(invitee, 1 days);
            HUB_V2.safeTransferFrom(inviter1, address(invitationEscrow), inviter1Id, value, abi.encode(invitee));

            vm.stopPrank();

            snapShot = vm.snapshot();
            address[] memory inviters = invitationEscrow.getInviters(invitee);
            assertEq(inviters.length, 1);
            vm.warp(block.timestamp + 2 days);

            vm.prank(invitee);
            vm.expectRevert(InvitationEscrow.MissingOrExpiredTrust.selector);
            invitationEscrow.redeemInvitation(inviter1);
        }
        vm.revertTo(snapShot);

        vm.startPrank(inviter2);

        HUB_V2.trust(invitee, type(uint96).max);
        // inviter 2 balance should eq value because it's the same day
        assertEq(HUB_V2.balanceOf(inviter2, inviter2Id), value);
        HUB_V2.safeTransferFrom(inviter2, address(invitationEscrow), inviter2Id, value, abi.encode(invitee));

        vm.stopPrank();

        vm.prank(invitee);
        vm.expectEmit();
        emit InvitationRedeemed(inviter2, invitee, value);
        invitationEscrow.redeemInvitation(inviter2);
        address[] memory inviters = invitationEscrow.getInviters(invitee);
        assertEq(inviters.length, 0);
    }

    /// @notice Fuzz test for single invitation revocation
    /// @dev Tests invitation revocation and linked list management
    /// @dev Not covered branch: if (previousElement == address(0)) returns
    /// @param inviter1Id First inviter Id
    /// @param inviteeId Invitee Id
    function testFuzzRevokeInvitation(uint160 inviter1Id, uint160 inviteeId) public {
        address inviter1 = address(uint160(inviter1Id));
        address invitee = address(uint160(inviteeId));

        if (
            inviter1 == SENTINEL || invitee == SENTINEL || inviter1 == address(HUB_V2) || invitee == address(HUB_V2)
                || inviter1 == address(0) || invitee == address(0) || inviter1 == invitee
        ) return;

        vm.assume(HUB_V2.avatars(invitee) == address(0) && !HUB_V2.isHuman(invitee));

        uint192 value = 100 ether;
        _registerHuman(inviter1);
        _setCRCBalance(inviter1Id, inviter1, HUB_V2.day(block.timestamp), value);

        vm.startPrank(inviter1);
        HUB_V2.trust(invitee, type(uint96).max);
        HUB_V2.safeTransferFrom(inviter1, address(invitationEscrow), uint256(inviter1Id), value, abi.encode(invitee));

        {
            address[] memory inviters = invitationEscrow.getInviters(invitee);
            assertEq(inviters.length, 1);
            address[] memory invitees = invitationEscrow.getInvitees(inviter1);
            assertEq(invitees.length, 1);
        }

        vm.expectEmit();
        emit InvitationRevoked(inviter1, invitee, value);
        invitationEscrow.revokeInvitation(invitee);
        vm.expectRevert(InvitationEscrow.InvalidEscrow.selector);
        invitationEscrow.revokeInvitation(invitee);
        vm.stopPrank();

        address[] memory inviters = invitationEscrow.getInviters(invitee);
        assertEq(inviters.length, 0);
    }

    /// @notice Fuzz test for revoking all invitations from an inviter
    /// @dev Tests bulk revocation of invitations including time-based discount calculations
    /// @dev Not covered branch: if (balance < revokedAmount) revokedAmount = balance;
    /// @param inviteeId First invitee address as uint160
    /// @param invitee2Id Second invitee address as uint160
    function testFuzz_RevokeAllInvitation(uint160 inviteeId, uint160 invitee2Id) public {
        address inviter = makeAddr("inviter");
        address invitee = address(uint160(inviteeId));
        address invitee2 = address(uint160(invitee2Id));
        uint160 inviterId = uint160(inviter);
        if (
            inviter == SENTINEL || invitee == SENTINEL || invitee2 == SENTINEL || inviter == address(HUB_V2)
                || invitee == address(HUB_V2) || invitee2 == address(HUB_V2) || inviter == address(0)
                || invitee == address(0) || invitee2 == address(0) || invitee == invitee2 || inviter == invitee
                || inviter == invitee2
        ) return;

        uint192 value = 100 ether;
        _registerHuman(inviter);
        _setCRCBalance(inviterId, inviter, HUB_V2.day(block.timestamp), value * 5);

        vm.startPrank(inviter);
        HUB_V2.trust(invitee, type(uint96).max);
        HUB_V2.safeTransferFrom(inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee));

        vm.warp(block.timestamp + 1 days);
        HUB_V2.trust(invitee2, type(uint96).max);
        HUB_V2.safeTransferFrom(inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee2));

        vm.stopPrank();
        (uint256 escrowedAmount, uint64 days_) = invitationEscrow.getEscrowedAmountAndDays(inviter, invitee);
        assertEq(days_, 1);
        assertGt(value, escrowedAmount);

        vm.warp(block.timestamp + 365 * 2 days); // attempt to cover branch if (balance < revokedAmount) , but fail
        vm.assume(invitee.code.length == 0); // Ensure invitee is EOA

        vm.startPrank(invitee);
        invitationEscrow.redeemInvitation(inviter);
        HUB_V2.registerHuman(inviter, bytes32(""));
        vm.stopPrank();

        vm.startPrank(inviter);
        invitationEscrow.revokeAllInvitations();
        invitationEscrow.revokeAllInvitations(); // cover branch: if (prevInvitee == address(0) || prevInvitee == SENTINEL)
        vm.stopPrank();
    }
}
