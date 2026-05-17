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

    // ISO 3166-1 numeric: 840 = United States
    uint16 internal constant COUNTRY_US = 840;

    function setUp() public {
        mock   = new MockTRex();
        bridge = new IdentityBridge(IERC3643Bridge(address(mock)), owner);
    }

    /* -------------------- Disabled bridge -------------------- */

    function test_disabledBridge_returnsFalse() public {
        IdentityBridge disabled = new IdentityBridge(IERC3643Bridge(address(0)), owner);
        assertFalse(disabled.isCompliant(user, bytes2(0)));
    }

    /* -------------------- Verified / unverified -------------- */

    function test_isCompliant_unverifiedUser_returnsFalse() public {
        mock.setVerified(user, false);
        assertFalse(bridge.isCompliant(user, bytes2(0)));
    }

    function test_isCompliant_verifiedUser_allowedJurisdiction_returnsTrue() public {
        mock.setVerified(user, true);
        mock.setCountry(user, COUNTRY_US);
        // US is NOT on the blocklist — should return true.
        assertTrue(bridge.isCompliant(user, bytes2(0)));
    }

    /* -------------------- Jurisdiction blocking -------------- */

    function test_isCompliant_verifiedUser_blockedJurisdiction_returnsFalse() public {
        mock.setVerified(user, true);
        mock.setCountry(user, COUNTRY_US);

        // Block US via the bridge's own blocklist.
        vm.prank(owner);
        bridge.setJurisdictionBlocked(COUNTRY_US, true);

        assertFalse(bridge.isCompliant(user, bytes2(0)));
    }

    function test_isCompliant_jurisdictionHint_overridesRegistryCountry() public {
        mock.setVerified(user, true);
        // Registry says user is from country 1 (not blocked).
        mock.setCountry(user, 1);

        // Caller hints that user is from COUNTRY_US.
        // COUNTRY_US (840 = 0x0348) encoded as bytes2: big-endian → 0x0348.
        bytes2 hint = bytes2(uint16(COUNTRY_US));

        // Block the hinted country.
        vm.prank(owner);
        bridge.setJurisdictionBlocked(COUNTRY_US, true);

        // The hint takes priority over the registry country → blocked.
        assertFalse(bridge.isCompliant(user, hint));
    }

    function test_isCompliant_jurisdictionHint_nonZero_allowedCountry_returnsTrue() public {
        mock.setVerified(user, true);
        bytes2 hint = bytes2(uint16(COUNTRY_US));
        // US is not blocked.
        assertTrue(bridge.isCompliant(user, hint));
    }

    /* -------------------- Access control --------------------- */

    function test_setJurisdictionBlocked_onlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(IdentityBridge.NotOwner.selector);
        bridge.setJurisdictionBlocked(COUNTRY_US, true);
    }

    function test_setJurisdictionBlocked_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit IdentityBridge.JurisdictionBlocked(COUNTRY_US, true);

        vm.prank(owner);
        bridge.setJurisdictionBlocked(COUNTRY_US, true);

        assertTrue(bridge.isJurisdictionBlocked(COUNTRY_US));
    }
}
