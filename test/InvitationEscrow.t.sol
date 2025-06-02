// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {InvitationEscrow} from "src/InvitationEscrow.sol";

contract InvitationEscrowTest is Test {
    InvitationEscrow public invitationEscrow;

    function setUp() public {
        invitationEscrow = new InvitationEscrow();
    }
}
