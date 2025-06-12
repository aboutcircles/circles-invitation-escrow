// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {HubStorageWrites} from "test/helpers/HubStorageWrites.sol";
import {InvitationEscrow} from "src/InvitationEscrow.sol";
import {IHub} from "src/interfaces/IHub.sol";

contract InvitationEscrowTest is Test, HubStorageWrites {
    // Gnosis fork ID
    uint256 internal gnosisFork;

    InvitationEscrow public invitationEscrow;

    IHub public constant HUB_V2 = IHub(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8);

    address internal INVITER_1 = makeAddr("alice");
    address internal INVITER_2 = makeAddr("bob");

    address internal INVITEE_1 = makeAddr("carol");
    address internal INVITEE_2 = makeAddr("dave");

    uint64 internal TODAY;

    function setUp() public {
        // Fork from Gnosis
        gnosisFork = vm.createFork(vm.envString("GNOSIS_RPC"));
        vm.selectFork(gnosisFork);

        invitationEscrow = new InvitationEscrow();

        TODAY = HUB_V2.day(block.timestamp);

        // Initialize inviter accounts with CRC balances
        _registerHuman(INVITER_1);
        _registerHuman(INVITER_2);
        _setCRCBalance(uint256(uint160(INVITER_1)), INVITER_1, HUB_V2.day(block.timestamp), 500 ether);
        _setCRCBalance(uint256(uint160(INVITER_2)), INVITER_2, HUB_V2.day(block.timestamp), 1000 ether);
    }

    function test_Default() public {
        address[] memory inviters = invitationEscrow.getInviters(INVITEE_1);
        console.log(inviters.length);
        address[] memory invitees = invitationEscrow.getInvitees(INVITER_1);
        console.log(invitees.length);
        bytes memory data = abi.encode(INVITEE_1);
        vm.prank(INVITER_1);
        HUB_V2.trust(INVITEE_1, type(uint96).max);
        vm.prank(INVITER_1);
        HUB_V2.safeTransferFrom(INVITER_1, address(invitationEscrow), uint256(uint160(INVITER_1)), 100 ether, data);

        inviters = invitationEscrow.getInviters(INVITEE_1);
        console.log(inviters.length);
        invitees = invitationEscrow.getInvitees(INVITER_1);
        console.log(invitees.length);

        vm.prank(INVITER_2);
        HUB_V2.trust(INVITEE_1, type(uint96).max);
        vm.prank(INVITER_2);
        HUB_V2.safeTransferFrom(INVITER_2, address(invitationEscrow), uint256(uint160(INVITER_2)), 100 ether, data);

        inviters = invitationEscrow.getInviters(INVITEE_1);
        console.log(inviters.length);
        invitees = invitationEscrow.getInvitees(INVITER_1);
        console.log(invitees.length);
        invitees = invitationEscrow.getInvitees(INVITER_2);
        console.log(invitees.length);

        vm.prank(INVITEE_1);
        invitationEscrow.redeemInvitation(INVITER_2);
        vm.prank(INVITEE_1);
        HUB_V2.registerHuman(INVITER_2, bytes32(0));

        inviters = invitationEscrow.getInviters(INVITEE_1);
        console.log(inviters.length);
        invitees = invitationEscrow.getInvitees(INVITER_1);
        console.log(invitees.length);
        invitees = invitationEscrow.getInvitees(INVITER_2);
        console.log(invitees.length);
    }
}
