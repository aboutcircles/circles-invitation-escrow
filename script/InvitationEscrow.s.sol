// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {InvitationEscrow} from "src/InvitationEscrow.sol";

contract InvitationEscrowScript is Script {
    address deployer = address(0xb1B1A7BDf196d1eB45a652E948971C3E790C4Ae2);
    InvitationEscrow public invitationEscrow; // 0x3167D6c3F718A8CD68788538F39eD75f2A79C453

    function setUp() public {}

    function run() public {
        vm.startBroadcast(deployer);

        invitationEscrow = new InvitationEscrow();

        vm.stopBroadcast();
    }
}
