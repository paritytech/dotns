// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {ISystem} from "../../contracts/external/revive/ISystem.sol";

/// @title BaseUpgradeFork
/// @notice Shared setup for the fork tests that pair with the upgrade scripts: forks the live
///         network through the ETH-RPC adapter, resolves the deployed addresses from the manifest,
///         and hands subclasses the owner they need to impersonate.
/// @dev Every fork test in this directory upgrades a proxy that real users have state in, so what
///      they assert is that the state is still there and still works afterwards, read through the
///      upgraded implementation. Fixtures are deliberately absent: seeding a contract to prove the
///      upgrade preserves the seed proves less than reading what the network already holds, and
///      the reads below are what make the assertions about live data rather than about a fixture.
///
///      These are scoped to the upgrade, but on this branch they are not deleted afterwards. The
///      branch is never merged to master (see `CONTRIBUTING.md`), so the artefacts stay as the
///      record of what was deployed and the starting point for the next round.
/// @custom:security-contact admin@parity.io
abstract contract BaseUpgradeFork is Test {
    /// @notice Manifest recording the live deployment addresses this fork resolves against.
    /// @dev The folder is Paseo Asset Hub Next, reached at `https://eth-rpc-paseo-next.polkadot.io`
    ///      in production. Chain id 420420417 is shared with other Paseo-style environments, so an
    ///      adapter pointed at the wrong one resolves this manifest and finds no code; the address
    ///      assertions in `setUp` are what turn that into a clear failure.
    string internal constant MANIFEST_PATH = "deployments/paseo-assethub/420420417.json";

    /// @notice Raw manifest contents, for subclasses resolving addresses beyond the common set.
    string internal manifest;

    function setUp() public virtual {
        vm.createSelectFork(_forkUrl());
        manifest = vm.readFile(MANIFEST_PATH);
    }

    /// @notice The endpoint these tests fork from.
    /// @dev Defaults to the `paseo_local` alias, which is the ETH-RPC adapter `fork-tests.sh`
    ///      brings up under Docker. `PASEO_FORK_RPC` overrides it, because requiring Docker is
    ///      why this suite went unrun for as long as it did: the adapter only translates for the
    ///      same node the hosted endpoint already fronts, so a run against that endpoint
    ///      exercises the same state. Keep the default local, so CI and anyone mid-deployment
    ///      are not silently pointed at a public gateway.
    /// @return url Endpoint to fork from.
    function _forkUrl() internal view returns (string memory url) {
        url = vm.envOr("PASEO_FORK_RPC", string(""));
        if (bytes(url).length == 0) url = vm.rpcUrl("paseo_local");
    }

    /// @notice Resolves `label` from the manifest and asserts something is deployed there.
    /// @dev The assertion is the useful half. A fork pointed at a network that never ran this
    ///      deployment resolves every address and finds them all empty, and without this the
    ///      failure surfaces much later as an unrelated revert inside a call.
    /// @param label Manifest key, for example `DotnsRegistry`.
    /// @return addr The deployed address.
    function _live(string memory label) internal view returns (address addr) {
        addr = vm.parseJsonAddress(manifest, string.concat(".", label));
        require(addr.code.length != 0, string.concat("fork: no code at ", label));
    }

    /// @notice The owner of `proxy`, which every upgrade script requires as its broadcaster.
    /// @param proxy Proxy whose owner is needed.
    /// @return owner The account `_authorizeUpgrade` will accept.
    function _ownerOf(address proxy) internal view returns (address owner) {
        owner = OwnableUpgradeable(proxy).owner();
    }

    /// @notice Makes `ISystem.originIsRoot` answer true for the rest of the test.
    /// @dev The revive precompile is not part of forked state, so any entrypoint gated on a Root
    ///      origin reverts on a fork unless it is mocked. Contracts gated this way say so on the
    ///      entrypoint; the mock changes nothing about what the upgrade does to storage.
    function _mockRootOrigin() internal {
        vm.mockCall(
            DotnsConstants.REVIVE_SYSTEM,
            abi.encodeWithSelector(ISystem.originIsRoot.selector),
            abi.encode(true)
        );
    }

    /// @notice Reads the implementation behind an ERC1967 proxy.
    /// @dev Used to assert a swap actually happened. Without it an upgrade that silently did
    ///      nothing would pass every state-preservation assertion in this directory, since state
    ///      surviving is exactly what doing nothing achieves.
    /// @param proxy Proxy to read.
    /// @return implementation Current implementation address.
    function _implementationOf(address proxy) internal view returns (address implementation) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        implementation = address(uint160(uint256(vm.load(proxy, slot))));
    }
}
