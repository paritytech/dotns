// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";

import {BaseDeployer} from "./BaseDeployer.s.sol";

/// @notice The one slice of Ownable this script needs, so it works identically on the UUPS
///         proxies and on the plain contracts without importing either hierarchy.
interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

/// @title RotateOwnership
/// @notice Transfers ownership of every DotNS contract to a fresh key. Step 0 of the upgrade
///         runbook, and the step that exists because key custody, not code, is the current risk:
///         copies of the deployment key have spread across sources the project does not control,
///         so it is treated as leaked.
/// @dev Addresses do not move. Ownership is a storage field on each contract, so consumers,
///      hosts, manifests and the codehash declarations are all untouched; the only thing that
///      changes is which key the `onlyOwner` gates answer to. This is the property that makes
///      rotation sufficient and a redeploy unnecessary.
///
///      Broadcast by the current owner, its last act. Everything that follows in the runbook is
///      broadcast by the new key, so after this lands, the CI environment secret is replaced and
///      the old secret deleted, wherever copies exist. Rotation does nothing retroactive: until
///      it executes, the old key can do everything, and afterwards it can do nothing but be
///      recognised.
///
///      The inventory is checked from both ends, because a rotation that silently misses a
///      contract leaves a door open behind a report that says all doors are closed. Contracts
///      that must be owned by the broadcaster hard-fail on any surprise, contracts known to
///      carry no owner or someone else's are named as such, and every remaining manifest entry
///      is probed: one that answers `owner()` with the broadcaster fails the run, because it
///      belongs on a list and is not there.
///
///      Re-runnable after a partial failure: a contract already answering to the new owner is
///      skipped, so the old key can finish what an interrupted run started. Once every contract
///      has moved, the old key can no longer run this at all, which is the point.
///
///      The old account's balance moves in the same run, once every owner has. Rotation strips
///      `onlyOwner` powers and cannot strip the right to spend a balance, and a leaked key's
///      balance is exactly as leaked as its authority was, so leaving the sweep for a later
///      manual step is a race offered to whoever else holds the key. It is also what funds the
///      new owner: nobody can extract the old key to sign a transfer by hand, so the gated run
///      is the one signer the balance has.
///
///      One thing this deliberately does not cover: `Create3Factory` is left alone. Its owner is
///      the factory deployer, a different account, and its deploy surface is permissionless
///      anyway, so there is nothing an owner rotation would protect.
/// @custom:security-contact admin@parity.io
contract RotateOwnership is BaseDeployer {
    /// @notice Reads the new owner, resolves the inventory, and rotates as `msg.sender`.
    /// @dev `DOTNS_NEW_OWNER` is the fresh key's address. Refused when zero or when equal to the
    ///      broadcaster, because rotating to the compromised key is the one outcome worse than
    ///      not rotating.
    function run() external {
        address current = msg.sender;
        vm.label(current, "CURRENT_OWNER");

        initDeployment(networkFolder(), vm.toString(block.chainid));

        address newOwner = vm.envAddress("DOTNS_NEW_OWNER");
        require(newOwner != address(0), "RotateOwnership: DOTNS_NEW_OWNER is unset or zero");
        require(
            newOwner != current,
            "RotateOwnership: new owner equals the current one; nothing would rotate"
        );

        _rotateEverything(current, newOwner);
        _sweep(current, newOwner);

        console.log("=== RotateOwnership complete ===");
    }

    /// @notice Labels whose owner MUST be the broadcaster. Any surprise here aborts the run.
    /// @dev Everything the live chain answers `owner()` for with the deployment key, probed on
    ///      2026-09-21: the twelve owned proxies, the cost-model registry, and the store factory
    ///      the manifest names. Before the store migration that label is the deployed plain
    ///      factory; after it, the replacement proxy, with the outgoing factory recorded as
    ///      `StoreFactoryLegacy` and picked up by the conditional below.
    function _mustRotate() internal pure returns (string[14] memory labels) {
        labels = [
            "DotnsProtocolRegistry",
            "DotnsRegistry",
            "DotnsRegistrar",
            "DotnsRegistrarController",
            "DotnsPopController",
            "PopRules",
            "DotnsNameEscrow",
            "DotnsNameWhitelist",
            "DotnsResolver",
            "DotnsReverseResolver",
            "DotnsContentResolver",
            "DotnsPopResolver",
            "DotnsCostModelRegistry",
            "StoreFactory"
        ];
    }

    /// @notice Labels that are expected to answer to someone else, or to no one.
    /// @dev `Create3Factory` answers to the factory deployer, a different key. `Multicall3`,
    ///      the lens and the pricing helper expose no `owner()` in the deployed release, and
    ///      `_seed` is a manifest placeholder. Named so the completeness scan can insist that
    ///      everything else is accounted for explicitly, and so a later release that gives one
    ///      of these an owner fails the scan instead of slipping through.
    function _leaveAlone() internal pure returns (string[5] memory labels) {
        labels = ["Create3Factory", "Multicall3", "_seed", "DotnsPopLens", "DotnsFlatPricing"];
    }

    /// @notice Rotates the inventory and then proves the manifest holds nothing unaccounted for.
    /// @param current The broadcaster, owner of everything being rotated.
    /// @param newOwner The fresh key taking over.
    function _rotateEverything(address current, address newOwner) internal {
        string memory manifest = vm.readFile(
            string.concat("deployments/", networkFolder(), "/", vm.toString(block.chainid), ".json")
        );

        string[14] memory must = _mustRotate();
        for (uint256 i; i < must.length; ++i) {
            // Parsed from the file read above, not through the deployer's manifest field: that
            // field is only populated by `initDeployment`, and this internal is also driven by
            // the fork harness, which calls it directly. Ambient state is how the migration's
            // deploy leg was unreachable from its own test; not again.
            _rotateOne(
                must[i],
                vm.parseJsonAddress(manifest, string.concat(".", must[i])),
                current,
                newOwner,
                true
            );
        }

        // The outgoing factory exists in the manifest only once the store migration has run.
        // It keeps answering to the owner because it is the only contract able to rotate the
        // beacons behind the pre-migration stores, so it moves with everything else.
        if (vm.keyExistsJson(manifest, ".StoreFactoryLegacy")) {
            _rotateOne(
                "StoreFactoryLegacy",
                vm.parseJsonAddress(manifest, ".StoreFactoryLegacy"),
                current,
                newOwner,
                true
            );
        }

        _requireNothingLeftBehind(manifest, current);
    }

    /// @notice Rotates one contract, or explains precisely why it did not.
    /// @dev A contract already answering to `newOwner` is a completed step of an earlier run and
    ///      is skipped, which is what makes the script re-runnable after a partial failure. The
    ///      readback after the transfer is not decoration: `transferOwnership` here is the
    ///      one-step variant, so a wrong destination is permanent, and the require is the last
    ///      moment a mistake is a revert instead of a fact.
    /// @param label Manifest name, for the logs and the failure messages.
    /// @param target The contract.
    /// @param current The broadcaster.
    /// @param newOwner The fresh key.
    /// @param mustOwn Whether a surprise owner aborts the run.
    function _rotateOne(
        string memory label,
        address target,
        address current,
        address newOwner,
        bool mustOwn
    )
        internal
    {
        (bool answers, address owner) = _tryOwner(target);

        if (!answers) {
            require(!mustOwn, string.concat("RotateOwnership: ", label, " does not answer owner()"));
            console.log("  skipped (no owner surface)", label, target);
            return;
        }
        if (owner == newOwner) {
            console.log("  already rotated", label, target);
            return;
        }
        if (owner != current) {
            require(
                !mustOwn,
                string.concat("RotateOwnership: ", label, " is owned by neither key involved")
            );
            console.log("  skipped (owned elsewhere)", label, target);
            return;
        }

        vm.broadcast(current);
        IOwnable(target).transferOwnership(newOwner);

        require(
            IOwnable(target).owner() == newOwner,
            string.concat("RotateOwnership: ", label, " readback does not show the new owner")
        );
        console.log("  rotated", label, target);
    }

    /// @notice Sends the old account's balance to the new owner, keeping a gas buffer.
    /// @dev Last, after every transfer has been verified, so a sweep failure never strands a
    ///      half-rotated deployment: ownership is already across, and re-running retries only
    ///      this. The buffer exists because this same account just paid for fifteen broadcasts
    ///      and a re-run must not die on fees; whatever the buffer leaves behind is dust on a
    ///      powerless account, priced accordingly.
    /// @param current The old owner, whose balance moves.
    /// @param newOwner Where it goes, the same address every contract now answers to.
    function _sweep(address current, address newOwner) internal {
        uint256 keep = 2 ether;
        uint256 balance = current.balance;
        if (balance <= keep) {
            console.log("  sweep skipped, balance is within the gas buffer", balance);
            return;
        }

        uint256 amount = balance - keep;
        vm.broadcast(current);
        (bool ok,) = payable(newOwner).call{value: amount}("");
        require(ok, "RotateOwnership: sweep transfer failed");
        require(
            newOwner.balance >= amount, "RotateOwnership: sweep readback shows less than was sent"
        );
        console.log("  swept to the new owner", amount);
    }

    /// @notice Fails the run if any manifest entry outside the three lists answers to the owner.
    /// @dev The lists above are a claim about the deployment's shape. This is the check that the
    ///      claim is complete: a contract added to the manifest by a later release, owned by the
    ///      deployment key and missing from the lists, stops the rotation here instead of
    ///      surviving it silently.
    /// @param manifest Raw manifest JSON.
    /// @param current The broadcaster.
    function _requireNothingLeftBehind(string memory manifest, address current) internal view {
        string[] memory names = vm.parseJsonKeys(manifest, "$");
        for (uint256 i; i < names.length; ++i) {
            if (_handled(names[i])) continue;

            (bool answers, address owner) =
                _tryOwner(vm.parseJsonAddress(manifest, string.concat(".", names[i])));
            require(
                !answers || owner != current,
                string.concat(
                    "RotateOwnership: ",
                    names[i],
                    " is owned by the key being rotated away from but is in no inventory list"
                )
            );
        }
    }

    /// @notice Whether `name` is covered by one of the three lists.
    function _handled(string memory name) internal pure returns (bool covered) {
        bytes32 h = keccak256(bytes(name));
        string[14] memory must = _mustRotate();
        for (uint256 i; i < must.length; ++i) {
            if (keccak256(bytes(must[i])) == h) return true;
        }
        string[5] memory alone = _leaveAlone();
        for (uint256 i; i < alone.length; ++i) {
            if (keccak256(bytes(alone[i])) == h) return true;
        }
        if (h == keccak256(bytes("StoreFactoryLegacy"))) return true;
        if (h == keccak256(bytes("LabelStoreBeacon")) || h == keccak256(bytes("UserStoreBeacon"))) {
            // Owned by their factory, which rotates above; a beacon answering to an EOA would be
            // drift, and the factory checks in the deploy pipeline are where that is caught.
            return true;
        }
        if (
            h == keccak256(bytes("LabelStoreBeaconLegacy"))
                || h == keccak256(bytes("UserStoreBeaconLegacy"))
        ) return true;
    }

    /// @notice `owner()` as a probe that cannot revert the caller.
    /// @param target Contract to ask.
    /// @return answers Whether the call returned a decodable address.
    /// @return owner The owner when it did.
    function _tryOwner(address target) internal view returns (bool answers, address owner) {
        (bool ok, bytes memory data) =
            target.staticcall(abi.encodeWithSelector(IOwnable.owner.selector));
        if (!ok || data.length != 32) return (false, address(0));
        owner = abi.decode(data, (address));
        answers = true;
    }
}
