// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {InvitationEscrow} from "src/InvitationEscrow.sol";
import {IHub} from "src/interfaces/IHub.sol";

contract InvitationEscrowTest is Test {
    // Gnosis fork ID
    uint256 internal gnosisFork;

    InvitationEscrow public invitationEscrow;

    IHub public constant HUB_V2 = IHub(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8);

    // Storage slots
    address private constant SENTINEL = address(0x1);
    uint256 public constant ORDER_FILLED_SLOT = 2;
    uint256 public constant DISCOUNTED_BALANCES_SLOT = 17;
    uint256 public constant MINT_TIMES_SLOT = 21;

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
        _setMintTime(INVITER_1);
        _setMintTime(INVITER_2);
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
        HUB_V2.safeTransferFrom(INVITER_1, address(invitationEscrow), uint256(uint160(INVITER_1)), 100 ether, data);

        inviters = invitationEscrow.getInviters(INVITEE_1);
        console.log(inviters.length);
        invitees = invitationEscrow.getInvitees(INVITER_1);
        console.log(invitees.length);
    }

    // -------------------------------------------------------------------------
    // Hub-Related Helpers
    // -------------------------------------------------------------------------

    /**
     * @notice Sets Hub mint times for account
     * @param account The account to set mint time for
     */
    function _setMintTime(address account) internal {
        bytes32 accountSlot = keccak256(abi.encodePacked(uint256(uint160(account)), MINT_TIMES_SLOT));
        uint256 mintTime = block.timestamp << 160;
        vm.store(address(HUB_V2), accountSlot, bytes32(mintTime));
    }

    /**
     * @notice Sets Hub ERC1155 balance of id for account
     * @param id The token ID
     * @param account The account to set balance for
     * @param lastUpdatedDay The last updated day
     * @param balance The balance to set
     */
    function _setCRCBalance(uint256 id, address account, uint64 lastUpdatedDay, uint192 balance) internal {
        bytes32 idSlot = keccak256(abi.encodePacked(id, DISCOUNTED_BALANCES_SLOT));
        bytes32 accountSlot = keccak256(abi.encodePacked(uint256(uint160(account)), idSlot));
        uint256 discountedBalance = (uint256(lastUpdatedDay) << 192) + balance;
        vm.store(address(HUB_V2), accountSlot, bytes32(discountedBalance));
    }
}
