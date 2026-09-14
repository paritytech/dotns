// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";
import {BaseDeployer} from "./BaseDeployer.s.sol";

import {DotnsRegistrarController} from "../../contracts/registrars/DotnsRegistrarController.sol";
import {DotnsNameEscrow} from "../../contracts/escrow/DotnsNameEscrow.sol";
import {DotnsNameWhitelist} from "../../contracts/whitelist/DotnsNameWhitelist.sol";
import {DotnsRootGateway} from "../../contracts/governance/DotnsRootGateway.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";

/// @title DeployPolicy
/// @notice Third stage. Deploys the name escrow, the pre-launch name whitelist, the
///         commit-reveal controller, and the Root gateway, all of which bind to the protocol
///         registry populated by `DeployCore`.
/// @dev The gateway is the only contract in this stage that is NOT a UUPS proxy. See
///      `_deployRootGateway`.
/// @custom:security-contact admin@parity.io
contract DeployPolicy is BaseDeployer {
    uint64 public constant MIN_COMMITMENT_AGE = 6 seconds;
    uint64 public constant MAX_COMMITMENT_AGE = 1 days;

    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        initDeployment(networkFolder(), vm.toString(block.chainid));

        address protocolRegistry = _readAddress("DotnsProtocolRegistry");
        _deployNameEscrow(owner, protocolRegistry);
        _deployNameWhitelist(owner, protocolRegistry);
        _deployRegistrarController(owner, protocolRegistry);
        _deployRootGateway(owner, protocolRegistry);

        saveDeployments();

        console.log("=== DeployPolicy complete ===");
    }

    function _deployRegistrarController(
        address owner,
        address protocolRegistry
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsRegistrarController.sol:DotnsRegistrarController",
            abi.encodeCall(
                DotnsRegistrarController.initialize,
                (
                    owner,
                    IDotnsProtocolRegistry(protocolRegistry),
                    MIN_COMMITMENT_AGE,
                    MAX_COMMITMENT_AGE
                )
            ),
            "DotnsRegistrarController"
        );
    }

    function _deployNameEscrow(
        address owner,
        address protocolRegistry
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsNameEscrow.sol:DotnsNameEscrow",
            abi.encodeCall(
                DotnsNameEscrow.initialize,
                (
                    owner,
                    IDotnsProtocolRegistry(protocolRegistry),
                    DotnsConstants.ESCROW_COOLDOWN,
                    DotnsConstants.ESCROW_REDEEM_WINDOW
                )
            ),
            "DotnsNameEscrow"
        );
    }

    function _deployNameWhitelist(
        address owner,
        address protocolRegistry
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsNameWhitelist.sol:DotnsNameWhitelist",
            abi.encodeCall(
                DotnsNameWhitelist.initialize, (owner, IDotnsProtocolRegistry(protocolRegistry))
            ),
            "DotnsNameWhitelist"
        );
    }

    /// @notice Deploys the non-upgradeable Root gateway.
    /// @dev Deliberately `_broadcastDeployCreate3`, not `_broadcastDeployUups`.
    ///      `ISystem.callerIsRoot` resolves the caller two frames below the precompile and a
    ///      delegatecall occupies a frame of its own, so behind a proxy the check reads false even
    ///      on a direct Root dispatch. Deploying this as a UUPS proxy would compile, deploy, and
    ///      silently brick every governance entry point in the protocol.
    ///
    ///      The gateway has no initialiser: it holds the registry in an `immutable` set by its
    ///      constructor, and no other state at all. That is the one sanctioned exception to the
    ///      "no immutable peer addresses" rule in CONTRIBUTING.md, because the immutable is the
    ///      registry itself and this contract cannot be upgraded to rewire it.
    /// @param owner Broadcasting account. The gateway itself has no owner.
    /// @param protocolRegistry Registry the gateway validates forwarding targets against.
    /// @return deployed Address of the deployed gateway.
    function _deployRootGateway(
        address owner,
        address protocolRegistry
    )
        internal
        returns (address deployed)
    {
        deployed = _broadcastDeployCreate3(
            owner,
            "DotnsRootGateway.sol:DotnsRootGateway",
            abi.encode(IDotnsProtocolRegistry(protocolRegistry)),
            "DotnsRootGateway"
        );
    }
}
