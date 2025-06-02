// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {InvitationEscrow} from "src/InvitationEscrow.sol";

contract InvitationEscrowScript is Script {
    InvitationEscrow public invitationEscrow;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        invitationEscrow = new InvitationEscrow();

        vm.stopBroadcast();
    }
}
