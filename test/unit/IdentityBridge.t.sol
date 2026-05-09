// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { IdentityBridge } from "../../src/IdentityBridge.sol";
import { IERC3643Bridge } from "../../src/interfaces/IERC3643Bridge.sol";

/// @notice Mock T-REX IdentityRegistry for bridge tests.
contract MockTRex is IERC3643Bridge {
    mapping(address => bool) public verified;
    mapping(address => uint16) public country;

    function setVerified(address a, bool v) external { verified[a] = v; }
    function setCountry(address a, uint16 c) external { country[a] = c; }

    function isVerified(address a) external view returns (bool) { return verified[a]; }
    function investorCountry(address a) external view returns (uint16) { return country[a]; }
}

contract IdentityBridgeTest is Test {
    IdentityBridge internal bridge;
    MockTRex       internal mock;
    address        internal owner = address(0xAAA);
    address        internal user  = address(0xBEEF);

    function setUp() public {
        mock = new MockTRex();
        bridge = new IdentityBridge(IERC3643Bridge(address(mock)), owner);
    }

    function test_disabledBridge_returnsFalse() public {
        IdentityBridge disabled = new IdentityBridge(IERC3643Bridge(address(0)), owner);
        // TODO: implement — assert disabled.isCompliant(user, bytes2(0)) == false
    }

    function test_isCompliant_unverifiedUser_returnsFalse() public {
        // TODO: implement — mock.verified[user] = false; assert bridge.isCompliant returns false
    }

    function test_isCompliant_verifiedUser_blockedJurisdiction_returnsFalse() public {
        // TODO: implement
    }

    function test_isCompliant_verifiedUser_allowedJurisdiction_returnsTrue() public {
        // TODO: implement
    }

    function test_setJurisdictionBlocked_onlyOwner() public {
        // TODO: implement — vm.expectRevert(IdentityBridge.NotOwner.selector)
    }
}
