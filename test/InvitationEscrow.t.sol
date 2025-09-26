// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {HubStorageWrites} from "test/helpers/HubStorageWrites.sol";
import {InvitationEscrow} from "src/InvitationEscrow.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {IERC20Lift, CirclesType} from "./interfaces/IERC20Lift.sol";
import {IDemurrageCircles, DiscountedBalance} from "./interfaces/IDemurrageCircles.sol";
import {MockReentrantReceiver} from "./mock/MockReentrantReceiver.sol";

/// @title InvitationEscrowTest
/// @notice Comprehensive test suite for InvitationEscrow contract
/// @dev Tests cover invitation creation, redemption, and revocation flows with edge cases
/// @dev Uncovered branches:
///      1. nonReentrant modifier: if tload(0) { revert(0, 0) }
///      2. _removeInvitation: if (previousElement == address(0)) {
contract InvitationEscrowTest is Test, HubStorageWrites {



    struct HubAndEscrowBalances {
        uint256 discountedBalance; // escrowBalance[inviter][invitee]
        uint64 lastUpdatedDay;
        uint256 hubEscrowBalance; // HUB_V2.balanceOf(escrow, id)
        uint256 hubAccountBalance; // HUB_V2.balanceOf(id, id)
    }

    /// @notice Fork ID for Gnosis chain testing
    uint256 internal gnosisFork;

    /// @notice The InvitationEscrow contract instance under test
    InvitationEscrow public invitationEscrow;

    /// @notice Circles Hub V2 contract on Gnosis chain
    IHub public constant HUB_V2 = IHub(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8);

    IERC20Lift public constant LIFTERC20 = IERC20Lift(0x5F99a795dD2743C36D63511f0D4bc667e6d3cDB5);

    /// @notice Sentinel address used in linked list operations
    address private constant SENTINEL = address(0x1);

    /// @notice Current day in Hub's time system
    uint64 internal TODAY;

    uint256 internal constant INVITATION_COST = 96 ether;

    /// @notice Refer to InvitationEscrowed event in InvitationEscrow.sol
    event InvitationEscrowed(address indexed inviter, address indexed invitee, uint256 indexed amount);

    /// @notice Refer to InvitationRedeemed event in InvitationEscrow.sol
    event InvitationRedeemed(address indexed inviter, address indexed invitee, uint256 indexed amount);

    event InvitationRefunded(address indexed inviter, address indexed invitee, uint256 indexed amount);

    /// @notice Refer to InvitationRevoked event in InvitationEscrow.sol
    event InvitationRevoked(address indexed inviter, address indexed invitee, uint256 indexed amount);

    error ERC1155InsufficientBalance(address sender, uint256 balance, uint256 needed, uint256 tokenId);
    /// @notice Sets up test environment with Gnosis fork and contract deployment
    /// @dev Creates a fork of Gnosis chain, deploys InvitationEscrow contract, and initializes test dependencies

    error ERC1155InvalidReceiver(address receiver);

    MockReentrantReceiver mockReentrantReceiver;

    function setUp() public {
        console.log(address(this));
        // Fork from Gnosis
        gnosisFork = vm.createFork(vm.envString("GNOSIS_RPC"));
        vm.selectFork(gnosisFork);

        invitationEscrow = new InvitationEscrow();

        TODAY = HUB_V2.day(block.timestamp);
        mockReentrantReceiver = new MockReentrantReceiver(address(invitationEscrow));
    }

    /// @notice Fuzz test for ERC1155 token reception and invitation creation
    /// @dev Tests comprehensive validation scenarios including access control, amount limits, encoding validation, and trust requirements
    /// @param inviterId The token ID representing the inviter's identity
    /// @param value The CRC amount to be escrowed for the invitation
    /// @param inviteeId The address ID of the intended invitation recipient
    function testFuzzERC1155Received(uint160 inviterId, uint192 value, uint160 inviteeId) public {
        address inviter = address(uint160(inviterId));
        address invitee = address(uint160(inviteeId));
        vm.assume(
            inviter != address(this) && invitee != address(this) && inviter != SENTINEL && invitee != SENTINEL
                && inviter != address(0) && inviter != address(HUB_V2) && invitee != address(HUB_V2)
        );

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

        if (inviter == invitee) {
            vm.prank(inviter);
            vm.expectRevert(InvitationEscrow.InviteeAlreadyRegistered.selector);

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

        HubAndEscrowBalances memory hubEscrowBalanceBefore;
        HubAndEscrowBalances memory hubEscrowBalanceAfter;
        address[] memory inviters;
        address[] memory invitees;
        {
            // trust first, then transfer
            vm.startPrank(inviter);
            HUB_V2.trust(invitee, type(uint96).max);
            assertTrue(HUB_V2.isTrusted(inviter, invitee));
            uint256 snapshot = vm.snapshot();
            hubEscrowBalanceBefore = _getHubEscrowBalance(inviter, invitee);

            HUB_V2.safeTransferFrom(inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee));

            hubEscrowBalanceAfter = _getHubEscrowBalance(inviter, invitee);
            inviters = invitationEscrow.getInviters(invitee);
            invitees = invitationEscrow.getInvitees(inviter);

            assertEq(hubEscrowBalanceAfter.hubEscrowBalance, hubEscrowBalanceBefore.hubEscrowBalance + value);
            assertEq(hubEscrowBalanceAfter.hubAccountBalance, hubEscrowBalanceBefore.hubAccountBalance - value);
            assertEq(hubEscrowBalanceAfter.discountedBalance, value);
            assertEq(hubEscrowBalanceAfter.lastUpdatedDay, 0);
            assertEq(invitees.length, 1);
            assertEq(invitees[0], invitee);
            assertEq(inviters.length, 1);
            assertEq(inviters[0], inviter);

            _setCRCBalance(uint256(inviterId), inviter, HUB_V2.day(block.timestamp), value);

            // transfer again
            vm.expectRevert(InvitationEscrow.InviteAlreadyEscrowed.selector);

            HUB_V2.safeTransferFrom(inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee));
            vm.stopPrank();

            // Ensure inviter is an EOA
            // invitee address can be invitationEscrow

            vm.assume(inviter.code.length == 0);

            vm.startPrank(invitee);

            invitationEscrow.redeemInvitation(inviter);
            if (invitee == address(invitationEscrow)) {
                vm.expectRevert(InvitationEscrow.OnlyInviter.selector);
                HUB_V2.registerHuman(inviter, bytes32(""));
                return;
            } else {
                HUB_V2.registerHuman(inviter, bytes32(""));
                assertTrue(HUB_V2.isHuman(invitee));
            }

            vm.stopPrank();

            _setCRCBalance(uint256(inviterId), inviter, HUB_V2.day(block.timestamp), value);

            vm.prank(inviter);
            vm.expectRevert(InvitationEscrow.InviteeAlreadyRegistered.selector);

            HUB_V2.safeTransferFrom(inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee));

            vm.revertTo(snapshot);
        }
        // Condition 5: inviter trusts invitee

        hubEscrowBalanceBefore = _getHubEscrowBalance(inviter, invitee);

        vm.prank(inviter);
        vm.expectEmit(address(invitationEscrow));

        emit InvitationEscrowed(inviter, invitee, value);

        HUB_V2.safeTransferFrom(inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee));

        hubEscrowBalanceAfter = _getHubEscrowBalance(inviter, invitee);
        inviters = invitationEscrow.getInviters(invitee);
        invitees = invitationEscrow.getInvitees(inviter);

        assertEq(hubEscrowBalanceAfter.hubEscrowBalance, hubEscrowBalanceBefore.hubEscrowBalance + value);
        assertEq(hubEscrowBalanceAfter.hubAccountBalance, hubEscrowBalanceBefore.hubAccountBalance - value);
        assertEq(hubEscrowBalanceAfter.discountedBalance, value);
        assertEq(hubEscrowBalanceAfter.lastUpdatedDay, 0);
        assertEq(invitees.length, 1);
        assertEq(invitees[0], invitee);
        assertEq(inviters.length, 1);
        assertEq(inviters[0], inviter);
    }

    /// @notice Fuzz test for invitation redemption functionality
    /// @dev Tests invitation redemption scenarios including trust expiration, multiple inviters, and reentrancy protection
    /// @param inviter1Id Token ID of the first inviter
    /// @param inviter2Id Token ID of the second inviter
    /// @param inviteeId Token ID of the invitation recipient
    /// @param _day1 First time period for trust expiration testing
    /// @param _day2 Second time period for trust expiration testing
    function testFuzz____RedeemInvitation(
        uint160 inviter1Id,
        uint160 inviter2Id,
        uint160 inviteeId,
        uint64 _day1,
        uint64 _day2
    ) public {
        address inviter1 = address(uint160(inviter1Id));
        address inviter2 = address(uint160(inviter2Id));
        address invitee = address(uint160(inviteeId));

        vm.assume(_day1 > 0 && _day2 > _day1 && _day2 < 100 * 365);

        vm.assume(
            invitee != SENTINEL && invitee != address(HUB_V2) && invitee != address(0) && inviter1 != inviter2
                && inviter1 != invitee && inviter2 != invitee
        );

        if (
            inviter1 == address(0) || inviter1 == address(HUB_V2) || inviter1 == SENTINEL || inviter2 == address(0)
                || inviter2 == address(HUB_V2) || inviter2 == SENTINEL || inviter1 == address(invitationEscrow)
                || inviter2 == address(invitationEscrow)
        ) {
            vm.prank(invitee);
            vm.expectRevert(InvitationEscrow.InvalidEscrow.selector);
            invitationEscrow.redeemInvitation(inviter1);

            vm.prank(invitee);
            vm.expectRevert(InvitationEscrow.InvalidEscrow.selector);
            invitationEscrow.redeemInvitation(inviter2);
            return;
        }

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
        address[] memory inviters;
        address[] memory invitees;
        {
            vm.startPrank(inviter1);
            HUB_V2.trust(invitee, _day1 * 1 days);
            assertTrue(HUB_V2.isTrusted(inviter1, invitee));
            HUB_V2.safeTransferFrom(inviter1, address(invitationEscrow), inviter1Id, value, abi.encode(invitee));
            vm.stopPrank();

            snapShot = vm.snapshot();
            inviters = invitationEscrow.getInviters(invitee);
            assertEq(inviters.length, 1);
            vm.warp(block.timestamp + _day2 * 1 days); // warp 1

            vm.prank(invitee);
            vm.expectRevert(InvitationEscrow.MissingOrExpiredTrust.selector);
            invitationEscrow.redeemInvitation(inviter1);
        }
        vm.revertTo(snapShot);
        snapShot = vm.snapshot();

        // Test reentrancy
        {
            vm.assume(address(mockReentrantReceiver) != address(invitationEscrow));
            // test reentrant
            _registerHuman(address(mockReentrantReceiver));
            _setCRCBalance(
                uint256(uint160(address(mockReentrantReceiver))),
                address(mockReentrantReceiver),
                HUB_V2.day(block.timestamp),
                value
            );

            vm.startPrank(address(mockReentrantReceiver));
            HUB_V2.trust(invitee, type(uint96).max);
            HUB_V2.safeTransferFrom(
                address(mockReentrantReceiver),
                address(invitationEscrow),
                uint256(uint160(address(mockReentrantReceiver))),
                value,
                abi.encode(invitee)
            );
            vm.stopPrank();

            vm.prank(invitee);
            vm.expectRevert(abi.encodeWithSelector(ERC1155InvalidReceiver.selector, address(mockReentrantReceiver)));
            invitationEscrow.redeemInvitation(address(mockReentrantReceiver));
        }

        vm.revertTo(snapShot);
        {
            // inviter1 and inviter2 trust invitee at the same day
            vm.startPrank(inviter2);

            HUB_V2.trust(invitee, type(uint96).max);
            // inviter 2 balance should eq value because it's the same day
            assertEq(HUB_V2.balanceOf(inviter2, inviter2Id), value);
            HUB_V2.safeTransferFrom(inviter2, address(invitationEscrow), inviter2Id, value, abi.encode(invitee));

            vm.stopPrank();

            vm.warp(block.timestamp + _day2 * 1 days); //warp 2
            //  inviter1's trust has expired
            HubAndEscrowBalances memory inviter1inviteeBefore = _getHubEscrowBalance(inviter1, invitee);
            HubAndEscrowBalances memory inviter2inviteeBefore = _getHubEscrowBalance(inviter2, invitee);

            // pre condition

            vm.prank(invitee);
            vm.expectEmit();
            emit InvitationRedeemed(inviter2, invitee, inviter2inviteeBefore.hubEscrowBalance);
            emit InvitationRefunded(inviter1, invitee, inviter1inviteeBefore.hubEscrowBalance);

            invitationEscrow.redeemInvitation(inviter2);

            address demurrageCircleInviter1 = LIFTERC20.erc20Circles(CirclesType.Demurrage, inviter1);
            DiscountedBalance memory discountedBalance =
                IDemurrageCircles(demurrageCircleInviter1).discountedBalances(inviter1);
            HubAndEscrowBalances memory inviter1inviteeAfter = _getHubEscrowBalance(inviter1, invitee);
            HubAndEscrowBalances memory inviter2inviteeAfter = _getHubEscrowBalance(inviter2, invitee);

            assertLe(
                inviter1inviteeAfter.hubEscrowBalance,
                inviter1inviteeBefore.hubEscrowBalance - inviter1inviteeBefore.discountedBalance
            );
            assertLe(
                inviter2inviteeAfter.hubEscrowBalance,
                inviter2inviteeBefore.hubEscrowBalance - inviter2inviteeBefore.discountedBalance
            );
            assertEq(inviter1inviteeAfter.hubAccountBalance, inviter1inviteeBefore.hubAccountBalance);
            assertLe(
                inviter2inviteeAfter.hubAccountBalance,
                inviter2inviteeBefore.hubAccountBalance + inviter2inviteeBefore.discountedBalance
            );
            assertLe(inviter1inviteeBefore.discountedBalance, uint256(discountedBalance.balance));

            inviters = invitationEscrow.getInviters(invitee);
            assertEq(inviters.length, 0);
            invitees = invitationEscrow.getInvitees(inviter2);
            assertEq(invitees.length, 0);
            assertEq(invitationEscrow.getInvitees(inviter1).length, 0);
            if (inviter2inviteeBefore.discountedBalance < INVITATION_COST) {
                vm.prank(invitee);
                vm.expectRevert();
                // vm.expectRevert(
                //     abi.encodeWithSelector(
                //         ERC1155InsufficientBalance.selector,
                //         inviter2,
                //         inviter2inviteeAfter.hubAccountBalance,
                //         INVITATION_COST,
                //         uint256(inviter2Id) // Stack too deep
                //     )
                // );
                HUB_V2.registerHuman(inviter2, bytes32(""));
            } else {
                vm.prank(invitee);
                HUB_V2.registerHuman(inviter2, bytes32(""));
                assertTrue(HUB_V2.isHuman(invitee));
            }
        }
    }

    /// @notice Fuzz test for single invitation revocation
    /// @dev Tests invitation revocation mechanics, linked list management, and demurrage calculations
    /// @dev Uncovered branch: if (previousElement == address(0)) returns
    /// @param inviter1Id Token ID of the inviter revoking the invitation
    /// @param inviteeId Token ID of the invitation recipient
    /// @param _days Number of days to simulate for demurrage testing
    function testFuzzRevokeInvitation(uint160 inviter1Id, uint160 inviteeId, uint256 _days) public {
        address inviter1 = address(uint160(inviter1Id));
        address invitee = address(uint160(inviteeId));

        vm.assume(_days < 100 * 365);
        vm.assume(
            inviter1 != SENTINEL && invitee != SENTINEL && inviter1 != address(HUB_V2) && inviter1 != address(0)
                && inviter1 != address(invitationEscrow)
        );

        if (invitee == address(0) || invitee == address(HUB_V2) || invitee == SENTINEL || inviter1 == invitee) {
            vm.prank(inviter1);
            vm.expectRevert(InvitationEscrow.InvalidEscrow.selector);
            invitationEscrow.revokeInvitation(invitee);
            return;
        }

        uint192 value = 100 ether;
        _registerHuman(inviter1);
        _setCRCBalance(inviter1Id, inviter1, HUB_V2.day(block.timestamp), value);

        vm.startPrank(inviter1);
        HUB_V2.trust(invitee, type(uint96).max);
        assertTrue(HUB_V2.isTrusted(inviter1, invitee));
        HUB_V2.safeTransferFrom(inviter1, address(invitationEscrow), uint256(inviter1Id), value, abi.encode(invitee));

        HubAndEscrowBalances memory inviter1inviteeBalance = _getHubEscrowBalance(inviter1, invitee);
        address[] memory inviters;
        address[] memory invitees;
        {
            assertEq(inviter1inviteeBalance.discountedBalance, value);
            assertEq(inviter1inviteeBalance.lastUpdatedDay, 0);
            assertEq(inviter1inviteeBalance.hubAccountBalance, 0);
            assertEq(inviter1inviteeBalance.hubEscrowBalance, value);

            inviters = invitationEscrow.getInviters(invitee);
            assertEq(inviters.length, 1);
            assertEq(inviters[0], inviter1);
            invitees = invitationEscrow.getInvitees(inviter1);
            assertEq(invitees.length, 1);
            assertEq(invitees[0], invitee);
        }

        vm.warp(block.timestamp + _days * 1 days);
        HubAndEscrowBalances memory inviter1inviteeAfter = _getHubEscrowBalance(inviter1, invitee);

        if (inviter1inviteeAfter.discountedBalance == 0) {
            vm.prank(inviter1);
            vm.expectRevert(InvitationEscrow.InvalidEscrow.selector);
            invitationEscrow.revokeInvitation(invitee);
        } else {
            vm.startPrank(inviter1);
            vm.expectEmit();
            emit InvitationRevoked(inviter1, invitee, inviter1inviteeAfter.discountedBalance);
            invitationEscrow.revokeInvitation(invitee);
            vm.expectRevert(InvitationEscrow.InvalidEscrow.selector);
            invitationEscrow.revokeInvitation(invitee);
            vm.stopPrank();
        }

        address demurrageCircleInviter1 = LIFTERC20.erc20Circles(CirclesType.Demurrage, inviter1);
        DiscountedBalance memory discountedBalanceERC20 =
            IDemurrageCircles(demurrageCircleInviter1).discountedBalances(inviter1);

        assertEq(inviter1inviteeAfter.discountedBalance, discountedBalanceERC20.balance);
        assertEq(inviter1inviteeAfter.hubEscrowBalance, discountedBalanceERC20.balance); // TODO: check why this is true, because escrow should be 0, and wrapper has the ERC1155, inviter has the wrapped ERC20
        assertEq(inviter1inviteeAfter.hubAccountBalance, 0);
        assertEq(inviter1inviteeAfter.lastUpdatedDay, _days);
        inviters = invitationEscrow.getInviters(invitee);
        assertEq(inviters.length, 0);
        invitees = invitationEscrow.getInvitees(inviter1);
        assertEq(invitees.length, 0);
    }

    /// @notice Fuzz test for bulk revocation of all invitations from a single inviter
    /// @dev Tests mass invitation revocation with time-based demurrage calculations and balance management
    /// @dev Uncovered branch: if (balance < revokedAmount) revokedAmount = balance;
    /// @param inviteeId Token ID of the first invitation recipient
    /// @param invitee2Id Token ID of the second invitation recipient
    /// @param _day1 First time period for staggered invitation creation
    /// @param _day2 Second time period for demurrage calculation testing
    function testFuzz___RevokeAllInvitation(uint160 inviteeId, uint160 invitee2Id, uint64 _day1, uint64 _day2) public {
        address inviter = makeAddr("inviter");
        address invitee = address(uint160(inviteeId));
        address invitee2 = address(uint160(invitee2Id));
        uint160 inviterId = uint160(inviter);

        address[] memory invitees;

        vm.assume(
            inviter != SENTINEL && invitee != SENTINEL && invitee2 != SENTINEL && inviter != address(HUB_V2)
                && invitee != address(HUB_V2) && invitee2 != address(HUB_V2) && inviter != address(0)
                && invitee != address(0) && invitee2 != address(0) && invitee != invitee2 && inviter != invitee
                && inviter != invitee2
        );
        vm.assume(_day1 < _day2 && _day1 > 0 && _day2 < 100 * 365);

        uint192 value = 100 ether;

        {
            _registerHuman(inviter);
            _setCRCBalance(inviterId, inviter, HUB_V2.day(block.timestamp), value);

            vm.startPrank(inviter);
            HUB_V2.trust(invitee, type(uint96).max);
            assertTrue(HUB_V2.isTrusted(inviter, invitee));
            vm.expectEmit();
            emit InvitationEscrowed(inviter, invitee, value);
            HUB_V2.safeTransferFrom(inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee));

            vm.warp(block.timestamp + _day1 * 1 days);
            _setCRCBalance(inviterId, inviter, HUB_V2.day(block.timestamp), value);

            HUB_V2.trust(invitee2, type(uint96).max);
            assertTrue(HUB_V2.isTrusted(inviter, invitee2));
            vm.expectEmit();
            emit InvitationEscrowed(inviter, invitee2, value);
            HUB_V2.safeTransferFrom(inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee2));

            vm.stopPrank();

            invitees = invitationEscrow.getInvitees(inviter);
            assertEq(invitees.length, 2);
            assertEq(invitees[0], invitee2);
            assertEq(invitees[1], invitee);
        }

        vm.warp(block.timestamp + _day2 * 1 days);  // warp 2

        // Check the pre condition

        HubAndEscrowBalances memory inviterinviteeBalanceBefore = _getHubEscrowBalance(inviter, invitee);
        HubAndEscrowBalances memory inviterinvitee2BalanceBefore = _getHubEscrowBalance(inviter, invitee2);

        assertEq(inviterinviteeBalanceBefore.hubEscrowBalance, inviterinvitee2BalanceBefore.hubEscrowBalance);
        assertApproxEqAbs(inviterinviteeBalanceBefore.hubEscrowBalance, inviterinviteeBalanceBefore.discountedBalance + inviterinvitee2BalanceBefore.discountedBalance, 8); // possible to be Ge or Le 
        assertEq(inviterinviteeBalanceBefore.lastUpdatedDay, _day1 + _day2);
        assertEq(inviterinvitee2BalanceBefore.lastUpdatedDay, _day2); 

        {
            vm.prank(inviter);
            invitationEscrow.revokeAllInvitations();


            invitees = invitationEscrow.getInvitees(inviter);
            address demurrageCircleInviter = LIFTERC20.erc20Circles(CirclesType.Demurrage, inviter);
            DiscountedBalance memory discountedBalance =
                IDemurrageCircles(demurrageCircleInviter).discountedBalances(inviter);
            HubAndEscrowBalances memory inviterinviteeBalanceAfter = _getHubEscrowBalance(inviter, invitee);
            HubAndEscrowBalances memory inviterinvitee2BalanceAfter = _getHubEscrowBalance(inviter, invitee2);

            assertEq(invitees.length, 0);
            assertLe(
                discountedBalance.balance, // actual amount of wrap Demurrage ERC20 
                inviterinviteeBalanceBefore.discountedBalance + inviterinvitee2BalanceBefore.discountedBalance
            ); // subject to _capToHubBalance
            assertGe(inviterinviteeBalanceAfter.hubEscrowBalance, 0); // subject to _capToHubBalance, the extra token is 'remained' in escrow contract, only in the escrowAmount[inviter][invitee], but is not the actual token
            assertEq(inviterinviteeBalanceAfter.discountedBalance, 0);
            assertEq(inviterinvitee2BalanceAfter.discountedBalance, 0);
            assertEq(inviterinviteeBalanceAfter.hubAccountBalance, 0);
            assertEq(inviterinviteeBalanceAfter.lastUpdatedDay, _day(block.timestamp));
            assertEq(inviterinvitee2BalanceAfter.lastUpdatedDay, _day(block.timestamp));

         
        }
    }

    /// @notice Retrieves comprehensive balance information for inviter-invitee pair
    /// @dev Fetches Hub balances and escrow-specific discounted balance data
    /// @param inviter The address of the invitation creator
    /// @param invitee The address of the invitation recipient
    /// @return balance Struct containing all relevant balance information
    function _getHubEscrowBalance(address inviter, address invitee)
        internal
        view
        returns (HubAndEscrowBalances memory balance)
    {
        balance.hubEscrowBalance = HUB_V2.balanceOf(address(invitationEscrow), uint160(inviter));
        balance.hubAccountBalance = HUB_V2.balanceOf(inviter, uint160(inviter));
        (balance.discountedBalance, balance.lastUpdatedDay) =
            invitationEscrow.getEscrowedAmountAndDays(inviter, invitee);
    }

    /// @notice Gets the Hub balance for a specific account and token ID
    /// @param account The account address to query
    /// @param id The token ID to query balance for
    /// @return balance The token balance
    function _getHubBalance(address account, uint256 id) internal view returns (uint256 balance) {
        balance = HUB_V2.balanceOf(account, id);
    }

    /// @notice Calculates the day number from a timestamp for demurrage calculations
    /// @dev Computes day index since inflation day zero, used for time-based token calculations
    /// @param _timestamp The timestamp to convert to day number
    /// @return Day number as uint64 (safely cast from uint256)
    function _day(uint256 _timestamp) internal pure returns (uint64) {
        uint256 INFLATION_DAY_ZERO = 1602720000;
        uint256 DEMURRAGE_WINDOW = 1 days;

        return uint64((_timestamp - INFLATION_DAY_ZERO) / DEMURRAGE_WINDOW);
    }
}
