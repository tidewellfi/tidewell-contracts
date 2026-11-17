// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ReferralRegistry} from "../src/ReferralRegistry.sol";

contract NoVaults {
    mapping(address => mapping(uint8 => address)) public vaultOf;

    function set(address user) external {
        vaultOf[user][0] = address(1);
    }
}

contract ReferralTest is Test {
    NoVaults factory = new NoVaults();
    ReferralRegistry reg = new ReferralRegistry(address(factory));
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);

    function test_inviteCode_linksWithoutShowingTheAddress() public {
        vm.prank(alice);
        reg.registerCode(bytes8("tide2k9x"));
        assertEq(reg.ownerOfCode(bytes8("tide2k9x")), alice);
        assertEq(reg.codeOf(alice), bytes8("tide2k9x"));

        vm.prank(bob);
        reg.setReferrerByCode(bytes8("tide2k9x"));
        assertEq(reg.referrerOf(bob), alice);
        assertEq(reg.discountBps(bob), 1000);
    }

    function test_inviteCode_rules() public {
        vm.startPrank(alice);
        vm.expectRevert(ReferralRegistry.BadCode.selector);
        reg.registerCode(bytes8("Tide2k9x")); // capital letter
        vm.expectRevert(ReferralRegistry.BadCode.selector);
        reg.registerCode(bytes8("tide1k9x")); // 1 looks like l
        vm.expectRevert(ReferralRegistry.BadCode.selector);
        reg.registerCode(bytes8("tide")); // too short: padded with zero bytes
        reg.registerCode(bytes8("abcdefgh"));
        vm.expectRevert(ReferralRegistry.HasCode.selector);
        reg.registerCode(bytes8("hgfedcba"));
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(ReferralRegistry.CodeTaken.selector);
        reg.registerCode(bytes8("abcdefgh"));

        vm.prank(bob);
        vm.expectRevert(ReferralRegistry.UnknownCode.selector);
        reg.setReferrerByCode(bytes8("zzzzzzzz"));

        // Own code, and after the first vault: refused as before.
        vm.prank(alice);
        vm.expectRevert(ReferralRegistry.InvalidReferrer.selector);
        reg.setReferrerByCode(bytes8("abcdefgh"));
        factory.set(carol);
        vm.prank(carol);
        vm.expectRevert(ReferralRegistry.NotNewUser.selector);
        reg.setReferrerByCode(bytes8("abcdefgh"));
    }
}
