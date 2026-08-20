// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {DotnsProtocolRegistry} from "../../../contracts/registry/DotnsProtocolRegistry.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";
import {LabelUtils} from "../../../contracts/utils/LabelUtils.sol";

/// @title DotnsProtocolRegistryTldTests
/// @notice Unit coverage for the protocol registry as the per-network TLD authority: a registry
///         initialised with a different TLD label derives a different node and token id for the
///         same second-level label, so two networks never collide on one another's names.
contract DotnsProtocolRegistryTldTests is BaseDotns {
    /// @notice Deploys a protocol registry initialised with @custom:param tldLabel behind a UUPS
    ///         proxy, mirroring the fixture's own registry deployment.
    /// @param tldLabel Bare TLD label without the leading dot.
    /// @return registry The initialised registry.
    function _deployRegistry(string memory tldLabel)
        private
        returns (IDotnsProtocolRegistry registry)
    {
        address proxy = Upgrades.deployUUPSProxy(
            "DotnsProtocolRegistry.sol:DotnsProtocolRegistry",
            abi.encodeCall(DotnsProtocolRegistry.initialize, (tldLabel))
        );
        registry = IDotnsProtocolRegistry(proxy);
    }

    /// @notice The same second-level label resolves to a distinct node and token id under two
    ///         registries whose TLDs differ, and the two TLD authorities never coincide.
    /// @dev The fixture's `protocolRegistry` already runs under @custom:constant TLD_LABEL (`dot`),
    ///      so it stands up a second authority under a different TLD and compares derivations.
    function test_same_label_derives_distinct_node_and_token_id_per_tld() public {
        IDotnsProtocolRegistry dotRegistry = IDotnsProtocolRegistry(address(protocolRegistry));
        IDotnsProtocolRegistry ethRegistry = _deployRegistry("eth");

        // Distinct TLDs must not share a TLD node or suffix.
        assertTrue(dotRegistry.tldNode() != ethRegistry.tldNode());
        assertEq(dotRegistry.tld(), ".dot");
        assertEq(ethRegistry.tld(), ".eth");

        bytes32 labelHash = LabelUtils.labelhashMemory("alice");
        bytes32 dotNodeOfLabel = LabelUtils.namehashUnder(dotRegistry.tldNode(), labelHash);
        bytes32 ethNodeOfLabel = LabelUtils.namehashUnder(ethRegistry.tldNode(), labelHash);

        // Same label under a different TLD yields a different node, and therefore a different
        // token id (the token id is the node cast to uint256).
        assertTrue(dotNodeOfLabel != ethNodeOfLabel);
        assertTrue(uint256(dotNodeOfLabel) != uint256(ethNodeOfLabel));
    }
}
