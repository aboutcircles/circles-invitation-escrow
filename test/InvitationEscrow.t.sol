// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {HubStorageWrites} from "test/helpers/HubStorageWrites.sol";
import {InvitationEscrow} from "src/InvitationEscrow.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {MockReentrantReceiver} from "./mock/MockReentrantReceiver.sol";
import {CircleV2Setup} from "./helpers/CircleV2Setup.sol";

/// @title InvitationEscrowTest
/// @notice Comprehensive test suite for InvitationEscrow contract
/// @dev Tests cover invitation creation, redemption, and revocation flows with edge cases
/// @dev Uncovered branches:
///      1. nonReentrant modifier: if tload(0) { revert(0, 0) }
///      2. _removeInvitation: if (previousElement == address(0)) {
contract InvitationEscrowTest is Test, HubStorageWrites, CircleV2Setup {
    /// @notice Struct containing balance information for testing escrow and Hub interactions
    /// @dev Aggregates all relevant balance data for comprehensive testing scenarios
    struct HubAndEscrowBalances {
        /// @notice Discounted balance stored in escrow mapping escrowBalance[inviter][invitee]
        uint256 escrowedBalance;
        /// @notice Last day the balance was updated in Hub's time system
        uint64 lastUpdatedDay;
        /// @notice Hub balance of escrow contract for the inviter's token ID
        uint256 hubEscrowBalance;
        /// @notice Hub balance of inviter's own account for their token ID
        uint256 hubAccountBalance;
    }

    /// @notice Initial circle balance for inviter
    uint192 INITIAL_CIRCLE_VALUE = 100 ether;

    /// @notice The InvitationEscrow contract instance under test
    InvitationEscrow public invitationEscrow;

    /// @notice Current day in Hub's time system
    uint64 internal TODAY;

    /// @notice Standard invitation cost in CRC tokens (96 CRC)
    uint256 internal constant INVITATION_COST = 96 ether;

    /// @notice Refer to InvitationEscrowed event in InvitationEscrow.sol
    event InvitationEscrowed(address indexed inviter, address indexed invitee, uint256 indexed amount);

    /// @notice Refer to InvitationRedeemed event in InvitationEscrow.sol
    event InvitationRedeemed(address indexed inviter, address indexed invitee, uint256 indexed amount);

    /// @notice Refer to InvitationRefunded event in InvitationEscrow.sol
    event InvitationRefunded(address indexed inviter, address indexed invitee, uint256 indexed amount);

    /// @notice Refer to InvitationRevoked event in InvitationEscrow.sol
    event InvitationRevoked(address indexed inviter, address indexed invitee, uint256 indexed amount);

    /// @notice Refer to RegisterHuman event in Hub.sol
    event RegisterHuman(address indexed avatar, address indexed inviter);

    /// @notice Refer to ERC1155InsufficientBalance error in IERC20Errors
    error ERC1155InsufficientBalance(address sender, uint256 balance, uint256 needed, uint256 tokenId);

    /// @notice Refer to ERC1155InvalidReceiver error in IERC20Errors
    error ERC1155InvalidReceiver(address receiver);

    /// @notice Mock contract for testing reentrancy protection
    MockReentrantReceiver mockReentrantReceiver;

    /// @notice Sets up test environment with Gnosis fork and contract deployment
    /// @dev Setup the CircleV2 environment, start from INFLATION_DAY_ZERO, deploys contracts
    function setUp() public override {
        super.setUp();
        vm.warp(INVITATION_ONLY_TIME + 1 days);

        invitationEscrow = new InvitationEscrow();

        TODAY = HUB_V2.day(block.timestamp);
        mockReentrantReceiver = new MockReentrantReceiver(address(invitationEscrow));
    }

    /*//////////////////////////////////////////////////////////////
                         External function
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test for ERC1155 token reception and invitation creation
    /// @dev Tests comprehensive validation scenarios including access control, amount limits, encoding validation, and trust requirements
    /// @param inviterId The token ID representing the inviter's identity
    /// @param value The CRC amount to be escrowed for the invitation
    /// @param inviteeId The address ID of the intended invitation recipient
    function testFuzz_onERC1155Received(uint160 inviterId, uint192 value, uint160 inviteeId) public {
        address inviter = address(uint160(inviterId));
        address invitee = address(uint160(inviteeId));
        vm.assume(
            inviter != address(this) && invitee != address(this) && inviter != address(0) && inviter != address(HUB_V2)
                && invitee != address(HUB_V2) && inviter != address(invitationEscrow)
                && invitee != address(invitationEscrow)
        );

        _setCRCBalance(uint256(inviterId), inviter, TODAY, value);

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
        _setCRCBalance(uint256(uint160(inviter)), inviter, TODAY, value);

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

            HUB_V2.safeTransferFrom(inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee));
            return;
        }

        // Condition 4: inviter != invitee

        if (invitee == address(0)) {
            vm.prank(inviter);
            vm.expectRevert(InvitationEscrow.InvalidInvitee.selector);
            HUB_V2.safeTransferFrom(inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee));
            return;
        }

        // Condition 5: invitee is not address(0)

        {
            if (invitee == SENTINEL) {
                vm.prank(inviter);
                vm.expectRevert(InvitationEscrow.InviteeAlreadyRegistered.selector);

                HUB_V2.safeTransferFrom(
                    inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee)
                );
                return;
            } else {
                vm.prank(inviter);
                vm.expectRevert(InvitationEscrow.MissingOrExpiredTrust.selector);

                HUB_V2.safeTransferFrom(
                    inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee)
                );
            }
        }
        // Conditon 6: invitee is not SENTINEL

        HubAndEscrowBalances memory hubEscrowBalanceBefore = _getHubEscrowBalance(inviter, invitee);
        HubAndEscrowBalances memory hubEscrowBalanceAfter;
        address[] memory inviters;
        address[] memory invitees;
        {
            // trust first, then transfer
            vm.startPrank(inviter);
            HUB_V2.trust(invitee, type(uint96).max);
            assertTrue(HUB_V2.isTrusted(inviter, invitee));

            vm.expectEmit(address(invitationEscrow));

            emit InvitationEscrowed(inviter, invitee, value);

            HUB_V2.safeTransferFrom(inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee));

            hubEscrowBalanceAfter = _getHubEscrowBalance(inviter, invitee);

            inviters = invitationEscrow.getInviters(invitee);
            invitees = invitationEscrow.getInvitees(inviter);

            assertEq(hubEscrowBalanceAfter.hubEscrowBalance, hubEscrowBalanceBefore.hubEscrowBalance + value); //Escrow balance for inviter increase
            assertEq(hubEscrowBalanceAfter.hubAccountBalance, hubEscrowBalanceBefore.hubAccountBalance - value); // inviter self balance decrease
            assertEq(hubEscrowBalanceAfter.escrowedBalance, value); // escrowedAmount in escrow contract is value
            assertEq(hubEscrowBalanceAfter.lastUpdatedDay, 0); // same day as invitation escrow onERC1155Received

            if (inviter == SENTINEL) {
                // Inviter could not be SENTINEL because it is not possible to have SENTINEL as invitee and register as human (check Condition 6)
                // This case is only valid because we hardcode inviter as human using _registerHuman helper fn without going through the actual invitation esrow process
                assertEq(invitees.length, 1);
                assertEq(invitees[0], invitee);
                assertEq(inviters.length, 0);
                return;
            } else {
                assertEq(invitees.length, 1);
                assertEq(invitees[0], invitee);
                assertEq(inviters.length, 1);
                assertEq(inviters[0], inviter);
            }

            // Condition 7: inviter is not SENTINEL

            _setCRCBalance(uint256(inviterId), inviter, TODAY, value);

            // transfer again with the same invitee will revert
            vm.expectRevert(InvitationEscrow.InviteAlreadyEscrowed.selector);
            HUB_V2.safeTransferFrom(inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee));
            vm.stopPrank();

            // In production, the invitee and inviter are mostly Safe contract, hence code.length > 0
            // For testing in a fork + fuzz environment, we want to avoid the complexity where the fuzzed address is a contract on fork environment but don't have ERC1155 interface inherited
            // Hence, we assume here inviter and invitee are only EOA
            // Dev: this can be remove when using the CircleV2Setup instead of fork test
            vm.assume(inviter.code.length == 0 && invitee.code.length == 0);

            vm.startPrank(invitee);

            invitationEscrow.redeemInvitation(inviter);

            HubAndEscrowBalances memory hubEscrowBalanceAfterRedeem = _getHubEscrowBalance(inviter, invitee);
            assertEq(hubEscrowBalanceAfterRedeem.hubEscrowBalance, hubEscrowBalanceAfter.hubEscrowBalance - value); //Escrow balance for inviter increase
            assertEq(hubEscrowBalanceAfterRedeem.hubAccountBalance, hubEscrowBalanceBefore.hubAccountBalance + value); // inviter self balance decrease
            assertEq(hubEscrowBalanceAfterRedeem.escrowedBalance, 0); // escrowedAmount in escrow contract is 0
            assertEq(hubEscrowBalanceAfterRedeem.lastUpdatedDay, TODAY); // TODAY - 0

            HUB_V2.registerHuman(inviter, bytes32(""));

            assertTrue(HUB_V2.isHuman(invitee));

            vm.stopPrank();

            // Check if we could invite the same invitee again
            _setCRCBalance(uint256(inviterId), inviter, TODAY, value);

            vm.prank(inviter);
            vm.expectRevert(InvitationEscrow.InviteeAlreadyRegistered.selector);
            HUB_V2.safeTransferFrom(inviter, address(invitationEscrow), uint256(inviterId), value, abi.encode(invitee));
        }
    }

    /// @notice Fuzz test for invitation redemption functionality
    /// @dev Tests invitation redemption scenarios including trust expiration, multiple inviters, and reentrancy protection
    /// @param inviter1Id Token ID of the first inviter
    /// @param inviter2Id Token ID of the second inviter
    /// @param inviteeId Token ID of the invitation recipient
    /// @param _day1 First time period for trust expiration testing
    /// @param _day2 Second time period for trust expiration testing
    function testFuzz_RedeemInvitation(
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

        // In either cases of invalid addresses, should revert InvalidEscrow because onERC1155Received will revert
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

        _registerHuman(inviter1);
        _registerHuman(inviter2);
        _setCRCBalance(inviter1Id, inviter1, TODAY, INITIAL_CIRCLE_VALUE);
        _setCRCBalance(inviter2Id, inviter2, TODAY, INITIAL_CIRCLE_VALUE);

        {
            vm.prank(invitee);
            vm.expectRevert(InvitationEscrow.InvalidEscrow.selector);
            invitationEscrow.redeemInvitation(inviter1);
        }

        uint256 snapShot;

        {
            vm.startPrank(inviter1);
            HUB_V2.trust(invitee, _day1 * 1 days);
            assertTrue(HUB_V2.isTrusted(inviter1, invitee));
            HUB_V2.safeTransferFrom(
                inviter1, address(invitationEscrow), inviter1Id, INITIAL_CIRCLE_VALUE, abi.encode(invitee)
            );
            vm.stopPrank();

            snapShot = vm.snapshot();

            // ================ warp =====================
            vm.warp(block.timestamp + _day2 * 1 days);

            vm.prank(invitee);
            vm.expectRevert(InvitationEscrow.MissingOrExpiredTrust.selector);
            invitationEscrow.redeemInvitation(inviter1);
        }
        vm.revertTo(snapShot);
        snapShot = vm.snapshot();

        // Test reentrancy
        {
            _registerHuman(address(mockReentrantReceiver));
            _setCRCBalance(
                uint256(uint160(address(mockReentrantReceiver))),
                address(mockReentrantReceiver),
                TODAY,
                INITIAL_CIRCLE_VALUE
            );

            vm.startPrank(address(mockReentrantReceiver));
            HUB_V2.trust(invitee, type(uint96).max);
            HUB_V2.safeTransferFrom(
                address(mockReentrantReceiver),
                address(invitationEscrow),
                uint256(uint160(address(mockReentrantReceiver))),
                INITIAL_CIRCLE_VALUE,
                abi.encode(invitee)
            );
            vm.stopPrank();
            // Should revert because mockReentrantReceiver tries to call redeenInvitation within the same call and lead to revert from nonReentrant modifier
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
            assertEq(HUB_V2.balanceOf(inviter2, inviter2Id), INITIAL_CIRCLE_VALUE);
            HUB_V2.safeTransferFrom(
                inviter2, address(invitationEscrow), inviter2Id, INITIAL_CIRCLE_VALUE, abi.encode(invitee)
            );

            vm.stopPrank();

            // ================ warp =====================
            vm.warp(block.timestamp + _day2 * 1 days);

            //  inviter1's trust has expired
            HubAndEscrowBalances memory inviter1inviteeBefore = _getHubEscrowBalance(inviter1, invitee);
            HubAndEscrowBalances memory inviter2inviteeBefore = _getHubEscrowBalance(inviter2, invitee);

            vm.prank(invitee);
            vm.expectEmit();
            emit InvitationRedeemed(inviter2, invitee, inviter2inviteeBefore.hubEscrowBalance);
            vm.expectEmit();
            emit InvitationRefunded(inviter1, invitee, inviter1inviteeBefore.hubEscrowBalance);

            invitationEscrow.redeemInvitation(inviter2);

            address demurrageCircleInviter1 = ERC20LIFT.erc20Circles(uint8(0), inviter1);
            uint256 demurrageCircleDiscountedBalance =
                IERC20(demurrageCircleInviter1).balanceOf(inviter1);
            HubAndEscrowBalances memory inviter1inviteeAfter = _getHubEscrowBalance(inviter1, invitee);
            HubAndEscrowBalances memory inviter2inviteeAfter = _getHubEscrowBalance(inviter2, invitee);

            // In case where these 2 conditions are valid, the hubEscrowBalance for inviter in HUB will match escrowedAmount[inviter][invitee] in invitationEscrow,
            //    i. 1-to-1 [inviter][invitee] pair in invitationEscrow
            //    ii. No update on hubEscrowBalance in HUB for inviter
            // Because both value has the same lastUpdatedDay and update frequency
            // The mismatch will only happens when it's 1-to-many and [inviter][invitee] pairs, please check in revokeAllInvitation test
            assertEq(
                inviter1inviteeAfter.hubEscrowBalance,
                0 // inviter1inviteeBefore.hubEscrowBalance - inviter1inviteeBefore.escrowedBalance
            );
            assertEq(
                inviter2inviteeAfter.hubEscrowBalance,
                0 //inviter2inviteeBefore.hubEscrowBalance - inviter2inviteeBefore.escrowedBalance
            );
            assertEq(inviter1inviteeAfter.hubAccountBalance, 0); // inviter1's self balance(ERC1155) is the same and get demurrage ERC20 in return (inviter1inviteeBefore.hubAccountBalance + 0)

            assertEq(
                inviter2inviteeAfter.hubAccountBalance,
                inviter2inviteeBefore.hubAccountBalance + inviter2inviteeBefore.escrowedBalance
            ); // inviter2's self balance(ERC1155) increase, the amount is subject to _capToHubBalance
            assertEq(inviter1inviteeBefore.escrowedBalance, demurrageCircleDiscountedBalance); // inviter1 gets demurrage ERC20

            if (inviter2inviteeAfter.hubAccountBalance < INVITATION_COST) {
                vm.prank(invitee);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        ERC1155InsufficientBalance.selector,
                        inviter2,
                        inviter2inviteeAfter.hubAccountBalance,
                        INVITATION_COST,
                        uint256(uint160(inviter2))
                    )
                );

                HUB_V2.registerHuman(inviter2, bytes32(""));
            } else {
                vm.prank(invitee);
                HUB_V2.registerHuman(inviter2, bytes32(""));
                assertTrue(HUB_V2.isHuman(invitee));
                assertEq(HUB_V2.balanceOf(invitee, uint160(invitee)), WELCOME_BONUS);
            }
        }
    }

    /// @notice Fuzz test for single invitation revocation
    /// @dev Tests invitation revocation mechanics, linked list management, and demurrage calculations
    /// @dev Uncovered branch: if (previousElement == address(0)) returns
    /// @param inviterId Token ID of the inviter revoking the invitation
    /// @param inviteeId Token ID of the invitation recipient
    /// @param _days Number of days to simulate for demurrage testing
    function testFuzz_RevokeInvitation(uint160 inviterId, uint160 inviteeId, uint256 _days) public {
        address inviter = address(uint160(inviterId));
        address invitee = address(uint160(inviteeId));

        vm.assume(_days < 100 * 365);
        vm.assume(
            inviter != SENTINEL && invitee != SENTINEL && inviter != address(HUB_V2) && inviter != address(0)
                && inviter != address(invitationEscrow)
        );

        if (invitee == address(0) || invitee == address(HUB_V2) || invitee == SENTINEL || inviter == invitee) {
            vm.prank(inviter);
            vm.expectRevert(InvitationEscrow.InvalidEscrow.selector);
            invitationEscrow.revokeInvitation(invitee);
            return;
        }

        _registerHuman(inviter);
        _setCRCBalance(inviterId, inviter, TODAY, INITIAL_CIRCLE_VALUE);

        vm.startPrank(inviter);
        HUB_V2.trust(invitee, type(uint96).max);
        assertTrue(HUB_V2.isTrusted(inviter, invitee));
        HUB_V2.safeTransferFrom(
            inviter, address(invitationEscrow), uint256(inviterId), INITIAL_CIRCLE_VALUE, abi.encode(invitee)
        );

        HubAndEscrowBalances memory inviter1inviteeBalance = _getHubEscrowBalance(inviter, invitee);
        address[] memory inviters;
        address[] memory invitees;

        assertEq(inviter1inviteeBalance.escrowedBalance, INITIAL_CIRCLE_VALUE);
        assertEq(inviter1inviteeBalance.lastUpdatedDay, 0);
        assertEq(inviter1inviteeBalance.hubAccountBalance, 0);
        assertEq(inviter1inviteeBalance.hubEscrowBalance, INITIAL_CIRCLE_VALUE);

        inviters = invitationEscrow.getInviters(invitee);
        assertEq(inviters.length, 1);
        assertEq(inviters[0], inviter);
        invitees = invitationEscrow.getInvitees(inviter);
        assertEq(invitees.length, 1);
        assertEq(invitees[0], invitee);

        // ================ warp =====================
        vm.warp(block.timestamp + _days * 1 days);

        HubAndEscrowBalances memory inviter1inviteeAfter = _getHubEscrowBalance(inviter, invitee);

        if (inviter1inviteeAfter.escrowedBalance == 0) {
            vm.prank(inviter);
            vm.expectRevert(InvitationEscrow.InvalidEscrow.selector);
            invitationEscrow.revokeInvitation(invitee);
        } else {
            vm.startPrank(inviter);
            vm.expectEmit();
            emit InvitationRevoked(inviter, invitee, inviter1inviteeAfter.escrowedBalance);
            invitationEscrow.revokeInvitation(invitee);

            // Should revert when revoke twice
            vm.expectRevert(InvitationEscrow.InvalidEscrow.selector);
            invitationEscrow.revokeInvitation(invitee);
            vm.stopPrank();
        }

        address demurrageCircleInviter1 = ERC20LIFT.erc20Circles(uint8(0), inviter);
        uint256 demurrageCircleDiscountedBalance =
            IERC20(demurrageCircleInviter1).balanceOf(inviter);

        assertEq(inviter1inviteeAfter.escrowedBalance, demurrageCircleDiscountedBalance);
        assertEq(inviter1inviteeAfter.hubEscrowBalance, demurrageCircleDiscountedBalance);
        assertEq(inviter1inviteeAfter.hubAccountBalance, 0);
        assertEq(inviter1inviteeAfter.lastUpdatedDay, _days);
        inviters = invitationEscrow.getInviters(invitee);
        assertEq(inviters.length, 0);
        invitees = invitationEscrow.getInvitees(inviter);
        assertEq(invitees.length, 0);
    }

    /// @notice Fuzz test for bulk revocation of all invitations from a single inviter
    /// @dev Tests mass invitation revocation with time-based demurrage calculations and balance management
    /// @param inviteeId Token ID of the first invitation recipient
    /// @param invitee2Id Token ID of the second invitation recipient
    /// @param _day1 First time period for staggered invitation creation
    /// @param _day2 Second time period for demurrage calculation testing
    function testFuzz_RevokeAllInvitation(uint160 inviteeId, uint160 invitee2Id, uint64 _day1, uint64 _day2) public {
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
        vm.assume(_day1 > 0 && _day1 < _day2 && _day2 < 100 * 365);

        {
            _registerHuman(inviter);
            _setCRCBalance(inviterId, inviter, TODAY, INITIAL_CIRCLE_VALUE);

            vm.startPrank(inviter);
            HUB_V2.trust(invitee, type(uint96).max);
            assertTrue(HUB_V2.isTrusted(inviter, invitee));
            vm.expectEmit();
            emit InvitationEscrowed(inviter, invitee, INITIAL_CIRCLE_VALUE);
            HUB_V2.safeTransferFrom(
                inviter, address(invitationEscrow), uint256(inviterId), INITIAL_CIRCLE_VALUE, abi.encode(invitee)
            );

            // ================ warp =====================
            vm.warp(block.timestamp + _day1 * 1 days);
            TODAY = HUB_V2.day(block.timestamp);

            _setCRCBalance(inviterId, inviter, TODAY, INITIAL_CIRCLE_VALUE);

            HUB_V2.trust(invitee2, type(uint96).max);
            assertTrue(HUB_V2.isTrusted(inviter, invitee2));
            vm.expectEmit();
            emit InvitationEscrowed(inviter, invitee2, INITIAL_CIRCLE_VALUE);
            HUB_V2.safeTransferFrom(
                inviter, address(invitationEscrow), uint256(inviterId), INITIAL_CIRCLE_VALUE, abi.encode(invitee2)
            );

            vm.stopPrank();

            invitees = invitationEscrow.getInvitees(inviter);
            assertEq(invitees.length, 2);
            assertEq(invitees[0], invitee2);
            assertEq(invitees[1], invitee);
        }

        // ================ warp =====================
        vm.warp(block.timestamp + _day2 * 1 days);
        TODAY = HUB_V2.day(block.timestamp);

        // Check the pre condition

        HubAndEscrowBalances memory inviterinviteeBalanceBefore = _getHubEscrowBalance(inviter, invitee);
        HubAndEscrowBalances memory inviterinvitee2BalanceBefore = _getHubEscrowBalance(inviter, invitee2);

        assertEq(inviterinviteeBalanceBefore.hubEscrowBalance, inviterinvitee2BalanceBefore.hubEscrowBalance); // from HUB's POV, escrow's balance for inviter is the same regardless of which invitee
        assertApproxEqAbs(
            inviterinviteeBalanceBefore.hubEscrowBalance,
            inviterinviteeBalanceBefore.escrowedBalance + inviterinvitee2BalanceBefore.escrowedBalance,
            10
        ); // possible to be Ge or Le, the value 8 here is an estimation based on the runs of several test, it is possible to have discrepancy of more than 10
        assertEq(inviterinviteeBalanceBefore.lastUpdatedDay, _day1 + _day2);
        assertEq(inviterinvitee2BalanceBefore.lastUpdatedDay, _day2);

        {
            vm.prank(inviter);
            invitationEscrow.revokeAllInvitations();

            // Check the post condition
            invitees = invitationEscrow.getInvitees(inviter);
            address demurrageCircleInviter = ERC20LIFT.erc20Circles(uint8(0), inviter);
            uint256 demurrageCircleDiscountedBalance =
                IERC20(demurrageCircleInviter).balanceOf(inviter);
            HubAndEscrowBalances memory inviterinviteeBalanceAfter = _getHubEscrowBalance(inviter, invitee);
            HubAndEscrowBalances memory inviterinvitee2BalanceAfter = _getHubEscrowBalance(inviter, invitee2);

            assertEq(invitees.length, 0);
            assertLe(
                demurrageCircleDiscountedBalance, // actual amount of wrap Demurrage ERC20
                inviterinviteeBalanceBefore.escrowedBalance + inviterinvitee2BalanceBefore.escrowedBalance
            ); // subject to _capToHubBalance. The actual wrapped Demurrage ERC20 received by inviter should be not more than the available balance in HUB
            assertGe(inviterinviteeBalanceAfter.hubEscrowBalance, 0); //subject to _capToHubBalance, the extra token is 'remained' in escrow contract, if revokedAmount < balance
            assertEq(inviterinviteeBalanceAfter.escrowedBalance, 0); // Should be 0 because escrowedAmount[inviter][invitee] is deleted
            assertEq(inviterinvitee2BalanceAfter.escrowedBalance, 0); // Should be 0 because escrowedAmount[inviter][invitee2] is deleted
            assertEq(inviterinviteeBalanceAfter.hubAccountBalance, 0); // Should be 0 because inviter's balance is wrapped into Demurrage ERC20
            assertEq(inviterinviteeBalanceAfter.lastUpdatedDay, TODAY);
            assertEq(inviterinvitee2BalanceAfter.lastUpdatedDay, TODAY);
        }
    }

    /*//////////////////////////////////////////////////////////////
                         View function
    //////////////////////////////////////////////////////////////*/
    /// @dev View function test can be improved by fuzzing array length and address, i.e. https://github.com/aboutcircles/circles-groups/blob/develop/test/base-group/helpers/FlowMatrixGenerator.sol#L54-L66

    /// @notice Fuzz test for retrieving list of inviters for a given invitee
    /// @dev Tests linked list management and ordering of inviters
    /// @param invitee The address of the invitation recipient
    /// @param inviter1 First inviter address
    /// @param inviter2 Second inviter address
    /// @param inviter3 Third inviter address
    /// @param inviter4 Fourth inviter address
    /// @param inviter5 Fifth inviter address
    function testFuzz_getInviters(
        address invitee,
        address inviter1,
        address inviter2,
        address inviter3,
        address inviter4,
        address inviter5
    ) public {
        // Invitation must be created before testing getInviters

        vm.assume(
            invitee != address(0) && inviter1 != address(0) && inviter2 != address(0) && inviter3 != address(0)
                && inviter4 != address(0) && inviter5 != address(0) && inviter1 != address(HUB_V2)
                && inviter2 != address(HUB_V2) && inviter3 != address(HUB_V2) && inviter4 != address(HUB_V2)
                && inviter5 != address(HUB_V2) && invitee != SENTINEL && inviter1 != SENTINEL && inviter2 != SENTINEL
                && inviter3 != SENTINEL && inviter4 != SENTINEL && inviter5 != SENTINEL
        );
        if (
            inviter1 == inviter2 || inviter1 == inviter3 || inviter1 == inviter4 || inviter1 == inviter5
                || inviter2 == inviter3 || inviter2 == inviter4 || inviter2 == inviter5 || inviter3 == inviter4
                || inviter3 == inviter5 || inviter4 == inviter5 || invitee == inviter1 || invitee == inviter2
                || invitee == inviter3 || invitee == inviter4 || invitee == inviter5
        ) {
            return;
        }

        _registerHuman(inviter1);
        _registerHuman(inviter2);
        _registerHuman(inviter3);
        _registerHuman(inviter4);
        _registerHuman(inviter5);
        _setCRCBalance(uint256(uint160(inviter1)), inviter1, TODAY, INITIAL_CIRCLE_VALUE);
        _setCRCBalance(uint256(uint160(inviter2)), inviter2, TODAY, INITIAL_CIRCLE_VALUE);
        _setCRCBalance(uint256(uint160(inviter3)), inviter3, TODAY, INITIAL_CIRCLE_VALUE);
        _setCRCBalance(uint256(uint160(inviter4)), inviter4, TODAY, INITIAL_CIRCLE_VALUE);
        _setCRCBalance(uint256(uint160(inviter5)), inviter5, TODAY, INITIAL_CIRCLE_VALUE);

        address[] memory inviters = invitationEscrow.getInviters(invitee);
        assertEq(inviters.length, 0);

        vm.startPrank(inviter1);
        HUB_V2.trust(invitee, type(uint96).max);
        HUB_V2.safeTransferFrom(
            inviter1, address(invitationEscrow), uint256(uint160(inviter1)), INITIAL_CIRCLE_VALUE, abi.encode(invitee)
        );
        vm.stopPrank();

        inviters = invitationEscrow.getInviters(invitee);
        assertEq(inviters.length, 1);
        assertEq(inviters[0], inviter1);

        vm.startPrank(inviter2);
        HUB_V2.trust(invitee, type(uint96).max);
        HUB_V2.safeTransferFrom(
            inviter2, address(invitationEscrow), uint256(uint160(inviter2)), INITIAL_CIRCLE_VALUE, abi.encode(invitee)
        );
        vm.stopPrank();

        inviters = invitationEscrow.getInviters(invitee);
        assertEq(inviters.length, 2);
        assertEq(inviters[0], inviter2);
        assertEq(inviters[1], inviter1);

        vm.startPrank(inviter3);
        HUB_V2.trust(invitee, type(uint96).max);
        HUB_V2.safeTransferFrom(
            inviter3, address(invitationEscrow), uint256(uint160(inviter3)), INITIAL_CIRCLE_VALUE, abi.encode(invitee)
        );
        vm.stopPrank();

        inviters = invitationEscrow.getInviters(invitee);
        assertEq(inviters.length, 3);
        assertEq(inviters[0], inviter3);
        assertEq(inviters[1], inviter2);
        assertEq(inviters[2], inviter1);

        vm.startPrank(inviter4);
        HUB_V2.trust(invitee, type(uint96).max);
        HUB_V2.safeTransferFrom(
            inviter4, address(invitationEscrow), uint256(uint160(inviter4)), INITIAL_CIRCLE_VALUE, abi.encode(invitee)
        );
        vm.stopPrank();

        inviters = invitationEscrow.getInviters(invitee);
        assertEq(inviters.length, 4);
        assertEq(inviters[0], inviter4);
        assertEq(inviters[1], inviter3);
        assertEq(inviters[2], inviter2);
        assertEq(inviters[3], inviter1);

        vm.startPrank(inviter5);
        HUB_V2.trust(invitee, type(uint96).max);
        HUB_V2.safeTransferFrom(
            inviter5, address(invitationEscrow), uint256(uint160(inviter5)), INITIAL_CIRCLE_VALUE, abi.encode(invitee)
        );
        vm.stopPrank();

        inviters = invitationEscrow.getInviters(invitee);
        assertEq(inviters.length, 5);
        assertEq(inviters[0], inviter5);
        assertEq(inviters[1], inviter4);
        assertEq(inviters[2], inviter3);
        assertEq(inviters[3], inviter2);
        assertEq(inviters[4], inviter1);
    }

    /// @notice Fuzz test for retrieving list of invitees for a given inviter
    /// @dev Tests linked list management and ordering of invitees
    /// @param inviter The address of the invitation creator
    /// @param invitee1 First invitee address
    /// @param invitee2 Second invitee address
    /// @param invitee3 Third invitee address
    /// @param invitee4 Fourth invitee address
    /// @param invitee5 Fifth invitee address
    function testFuzz_getInvitees(
        address inviter,
        address invitee1,
        address invitee2,
        address invitee3,
        address invitee4,
        address invitee5
    ) public {
        vm.assume(
            inviter != address(0) && invitee1 != address(0) && invitee2 != address(0) && invitee3 != address(0)
                && invitee4 != address(0) && invitee5 != address(0) && invitee1 != address(HUB_V2)
                && invitee2 != address(HUB_V2) && invitee3 != address(HUB_V2) && invitee4 != address(HUB_V2)
                && invitee5 != address(HUB_V2) && inviter != SENTINEL && invitee1 != SENTINEL && invitee2 != SENTINEL
                && invitee3 != SENTINEL && invitee4 != SENTINEL && invitee5 != SENTINEL
        );
        if (
            invitee1 == invitee2 || invitee1 == invitee3 || invitee1 == invitee4 || invitee1 == invitee5
                || invitee2 == invitee3 || invitee2 == invitee4 || invitee2 == invitee5 || invitee3 == invitee4
                || invitee3 == invitee5 || invitee4 == invitee5 || inviter == invitee1 || inviter == invitee2
                || inviter == invitee3 || inviter == invitee4 || inviter == invitee5
        ) {
            return;
        }

        _registerHuman(inviter);
        _setCRCBalance(uint256(uint160(inviter)), inviter, TODAY, INITIAL_CIRCLE_VALUE * 5);
        address[] memory invitees = invitationEscrow.getInvitees(inviter);
        assertEq(invitees.length, 0);

        vm.startPrank(inviter);

        HUB_V2.trust(invitee1, type(uint96).max);
        HUB_V2.safeTransferFrom(
            inviter, address(invitationEscrow), uint256(uint160(inviter)), INITIAL_CIRCLE_VALUE, abi.encode(invitee1)
        );

        invitees = invitationEscrow.getInvitees(inviter);
        assertEq(invitees.length, 1);
        assertEq(invitees[0], invitee1);

        HUB_V2.trust(invitee2, type(uint96).max);
        HUB_V2.safeTransferFrom(
            inviter, address(invitationEscrow), uint256(uint160(inviter)), INITIAL_CIRCLE_VALUE, abi.encode(invitee2)
        );

        invitees = invitationEscrow.getInvitees(inviter);

        assertEq(invitees.length, 2);
        assertEq(invitees[0], invitee2);
        assertEq(invitees[1], invitee1);

        HUB_V2.trust(invitee3, type(uint96).max);
        HUB_V2.safeTransferFrom(
            inviter, address(invitationEscrow), uint256(uint160(inviter)), INITIAL_CIRCLE_VALUE, abi.encode(invitee3)
        );

        invitees = invitationEscrow.getInvitees(inviter);

        assertEq(invitees.length, 3);
        assertEq(invitees[0], invitee3);
        assertEq(invitees[1], invitee2);
        assertEq(invitees[2], invitee1);

        HUB_V2.trust(invitee4, type(uint96).max);
        HUB_V2.safeTransferFrom(
            inviter, address(invitationEscrow), uint256(uint160(inviter)), INITIAL_CIRCLE_VALUE, abi.encode(invitee4)
        );

        invitees = invitationEscrow.getInvitees(inviter);

        assertEq(invitees.length, 4);
        assertEq(invitees[0], invitee4);
        assertEq(invitees[1], invitee3);
        assertEq(invitees[2], invitee2);
        assertEq(invitees[3], invitee1);

        HUB_V2.trust(invitee5, type(uint96).max);
        HUB_V2.safeTransferFrom(
            inviter, address(invitationEscrow), uint256(uint160(inviter)), INITIAL_CIRCLE_VALUE, abi.encode(invitee5)
        );

        invitees = invitationEscrow.getInvitees(inviter);

        assertEq(invitees.length, 5);
        assertEq(invitees[0], invitee5);
        assertEq(invitees[1], invitee4);
        assertEq(invitees[2], invitee3);
        assertEq(invitees[3], invitee2);
        assertEq(invitees[4], invitee1);

        vm.stopPrank();
    }

    /// @notice Fuzz test for retrieving escrowed amount and time-based calculations
    /// @dev Tests demurrage calculations and time-based balance updates
    /// @param inviter The address of the invitation creator
    /// @param invitee The address of the invitation recipient
    /// @param _day1 First time interval for testing
    /// @param _day2 Second time interval for testing
    /// @param _day3 Third time interval for testing
    function testFuzz_getEscrowedAmountAndDays(
        address inviter,
        address invitee,
        uint64 _day1,
        uint64 _day2,
        uint64 _day3
    ) public {
        vm.assume(
            inviter != address(0) && invitee != address(0) && inviter != address(HUB_V2) && invitee != address(HUB_V2)
        );
        vm.assume(
            _day1 > 0 && _day2 > _day1 && _day3 > _day2 && _day3 < 100 * 365
                && _day1 + _day2 + _day3 <= type(uint64).max
        );

        _registerHuman(inviter);
        _setCRCBalance(uint256(uint160(inviter)), inviter, TODAY, INITIAL_CIRCLE_VALUE);

        vm.startPrank(inviter);

        HUB_V2.trust(invitee, type(uint96).max);
        HUB_V2.safeTransferFrom(
            inviter, address(invitationEscrow), uint256(uint160(inviter)), INITIAL_CIRCLE_VALUE, abi.encode(invitee)
        );

        (uint256 escrowAmount, uint64 lastUpdatedDay) = invitationEscrow.getEscrowedAmountAndDays(inviter, invitee);
        assertEq(escrowAmount, INITIAL_CIRCLE_VALUE);
        assertEq(lastUpdatedDay, 0);

        vm.stopPrank();

        vm.warp(block.timestamp + _day1 * 1 days);
        (escrowAmount, lastUpdatedDay) = invitationEscrow.getEscrowedAmountAndDays(inviter, invitee);
        assertEq(escrowAmount, HUB_V2.balanceOf(address(invitationEscrow), uint256(uint160(inviter))));
        assertEq(lastUpdatedDay, _day1);

        vm.warp(block.timestamp + _day2 * 1 days);
        (escrowAmount, lastUpdatedDay) = invitationEscrow.getEscrowedAmountAndDays(inviter, invitee);
        assertEq(escrowAmount, HUB_V2.balanceOf(address(invitationEscrow), uint256(uint160(inviter))));
        assertEq(lastUpdatedDay, _day2 + _day1);

        vm.warp(block.timestamp + _day3 * 1 days);
        (escrowAmount, lastUpdatedDay) = invitationEscrow.getEscrowedAmountAndDays(inviter, invitee);
        assertEq(escrowAmount, HUB_V2.balanceOf(address(invitationEscrow), uint256(uint160(inviter))));
        assertEq(lastUpdatedDay, _day3 + _day2 + _day1);
    }

    /*//////////////////////////////////////////////////////////////
                         Internal helper function
    //////////////////////////////////////////////////////////////*/

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
        (balance.escrowedBalance, balance.lastUpdatedDay) = invitationEscrow.getEscrowedAmountAndDays(inviter, invitee);
    }
}
