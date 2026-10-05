// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {SoulboundHandler} from "./SoulboundHandler.t.sol";

/// @title dotNS Registrar Soulbound Invariant Suite
/// @notice Asserts that PoP-gateway (soulbound) names never change owner across any reachable
///         sequence of mints and transfer attempts, and that the campaign actually exercises
///         soulbound tokens rather than passing vacuously.
contract DotnsRegistrarSoulboundInvariantTest is BaseDotns {
    /// @notice Handler driving randomised soulbound mints and transfer attempts.
    SoulboundHandler public handler;

    /// @notice Deploys the handler against the registrar and the configured PoP controller, seeds
    ///         one soulbound token so the non-vacuity guard always has a target, and points the
    ///         fuzzer at the handler's selectors only.
    function setUp() public override {
        super.setUp();

        handler = new SoulboundHandler(
            dotnsRegistrar, address(dotnsPopController), protocolRegistry.tldNode()
        );
        handler.addActor(ed);
        handler.addActor(leonardo);
        handler.addActor(tiago);
        handler.mintSoulbound(0);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = handler.mintSoulbound.selector;
        selectors[1] = handler.attemptSoulboundTransfer.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        excludeContract(address(dotnsRegistrar));
        excludeContract(address(dotnsPopController));
        excludeContract(address(dotnsRegistrarController));
        excludeContract(address(dotnsRegistry));
        excludeContract(address(dotnsNameEscrow));
        excludeContract(address(protocolRegistry));
        excludeContract(address(storeFactory));
    }

    /// @notice The campaign must mint at least one soulbound token, otherwise the ownership
    /// invariant below would hold vacuously over an empty set.
    function invariant_soulbound_coverage_is_non_vacuous() public view {
        assertGt(handler.soulboundCount(), 0, "no soulbound token was ever minted");
    }

    /// @notice No transfer of a soulbound token may ever succeed. This is a fixture-independent
    /// signal: it trips on a wrongful success regardless of fees, receiver type, or escrow
    /// configuration, so it catches a removed or weakened gate even where ownership drift alone
    /// might be masked by an unrelated revert.
    function invariant_no_soulbound_transfer_succeeds() public view {
        assertFalse(handler.sawSuccessfulTransfer(), "a soulbound transfer succeeded");
    }

    /// @notice Every soulbound token keeps its mint-time owner and its soulbound flag no matter
    /// what transfer attempts the fuzzer interleaves.
    function invariant_soulbound_owner_never_changes() public view {
        uint256[] memory ids = handler.soulboundIdsList();
        for (uint256 i = 0; i < ids.length; i++) {
            assertTrue(dotnsRegistrar.isSoulbound(ids[i]), "token stopped being soulbound");
            assertEq(
                dotnsRegistrar.ownerOf(ids[i]),
                handler.soulboundOwner(ids[i]),
                "soulbound token owner moved"
            );
        }
    }
}
