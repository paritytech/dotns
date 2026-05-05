// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {
    DotnsPopController,
    IDotnsPopController
} from "../../contracts/registrars/DotnsPopController.sol";
import {DotnsPopControllerOld} from "../../contracts/registrars/DotnsPopControllerOld.sol";
import {
    DotnsProtocolRegistry,
    IDotnsProtocolRegistry
} from "../../contracts/registry/DotnsProtocolRegistry.sol";
import {IPopRules} from "../../contracts/pop/IPopRules.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {UpgradeDotnsPopController} from "../../scripts/deploy/UpgradeDotnsPopController.s.sol";

contract DotnsPopControllerUpgradeFork is Test {
    using stdStorage for StdStorage;

    StdStorage internal stdstorage;

    uint256 internal constant PASEO_CHAIN_ID = 420420417;

    // ERC-7201 location of `OwnableUpgradeable._owner`. Derivation:
    // `keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Ownable")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 internal constant OWNABLE_STORAGE_LOCATION =
        0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;

    address internal user = address(0xA11CE);
    address internal gatewayOnFork = address(0xCA7E);
    address internal proxy;

    struct PreUpgradeState {
        address ownerAddress;
        address protocolRegistryAddress;
        uint64 reservationDuration;
    }

    PreUpgradeState internal preState;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("paseo"));

        proxy = (new UpgradeDotnsPopController()).readPopControllerAddress();
        require(proxy != address(0), "fork: DotnsPopController address missing");

        DotnsPopControllerOld old = DotnsPopControllerOld(proxy);
        preState = PreUpgradeState({
            ownerAddress: old.owner(),
            protocolRegistryAddress: address(old.protocolRegistry()),
            reservationDuration: old.reservationDuration()
        });
    }

    function test_upgrade_preserves_storage_layout_and_state() public {
        // The owner override `_runUpgrade` writes IS the storage marker we
        // read back: if the OZ Ownable slot moved or got overwritten by the
        // new layout, this read would diverge.
        _runUpgrade();

        DotnsPopController upgraded = DotnsPopController(proxy);
        assertEq(upgraded.owner(), address(this), "Ownable._owner slot did not survive upgrade");
        assertEq(
            address(upgraded.protocolRegistry()),
            preState.protocolRegistryAddress,
            "protocolRegistry drifted"
        );
        assertEq(
            uint256(upgraded.reservationDuration()),
            uint256(preState.reservationDuration),
            "reservationDuration drifted"
        );
    }

    function test_upgrade_typed_and_bytes_overloads_are_equivalent() public {
        _runUpgrade();
        _wireForkGatewayAndPopFull();

        string memory liteLabel = "alicefork01";
        bytes memory chatKey = _validChatKey(0xaa);
        IDotnsPopController.LiteRegistration memory params = IDotnsPopController.LiteRegistration({
            liteLabel: liteLabel, user: user, chatKey: chatKey
        });

        DotnsPopController upgraded = DotnsPopController(proxy);
        bytes32 liteNode = _liteNodeOf(liteLabel);
        uint256 baseline = vm.snapshotState();

        vm.recordLogs();
        vm.prank(gatewayOnFork);
        upgraded.reserveLiteName(params);
        Vm.Log[] memory typedLogs = vm.getRecordedLogs();
        IDotnsProtocolRegistry registry = upgraded.protocolRegistry();
        address registrar = registry.get(DotnsConstants.REGISTRAR);
        address typedOwner = IERC721(registrar).ownerOf(uint256(liteNode));

        vm.revertToState(baseline);

        vm.recordLogs();
        vm.prank(gatewayOnFork);
        upgraded.reserveLiteName(abi.encode(params));
        Vm.Log[] memory bytesLogs = vm.getRecordedLogs();
        address bytesOwner = IERC721(registrar).ownerOf(uint256(liteNode));

        assertEq(bytesOwner, typedOwner, "bytes overload diverged from typed on fork");
        assertEq(typedLogs.length, bytesLogs.length, "log count mismatch on fork");
        for (uint256 i = 0; i < typedLogs.length; ++i) {
            assertEq(typedLogs[i].emitter, bytesLogs[i].emitter, "log emitter mismatch");
            assertEq(
                typedLogs[i].topics.length, bytesLogs[i].topics.length, "log topic count mismatch"
            );
            for (uint256 t = 0; t < typedLogs[i].topics.length; ++t) {
                assertEq(typedLogs[i].topics[t], bytesLogs[i].topics[t], "log topic mismatch");
            }
            assertEq(
                keccak256(typedLogs[i].data), keccak256(bytesLogs[i].data), "log data mismatch"
            );
        }
    }

    function _runUpgrade() internal {
        // The script uses `vm.startBroadcast(msg.sender)` internally, which
        // foundry refuses to nest under `vm.prank`. Take ownership of the
        // proxy on the fork by overriding the OZ Ownable owner slot to this
        // contract; the script then broadcasts as `msg.sender == address(this)`
        // and the upgrade goes through the same `_authorizeUpgrade` path.
        vm.store(proxy, OWNABLE_STORAGE_LOCATION, bytes32(uint256(uint160(address(this)))));
        UpgradeDotnsPopController script = new UpgradeDotnsPopController();
        script.run();
    }

    function _wireForkGatewayAndPopFull() internal {
        DotnsPopController upgraded = DotnsPopController(proxy);
        IDotnsProtocolRegistry registry = upgraded.protocolRegistry();
        address registryOwner = DotnsProtocolRegistry(address(registry)).owner();
        vm.prank(registryOwner);
        registry.set(DotnsConstants.POP_GATEWAY, gatewayOnFork);

        address popRules = registry.get(DotnsConstants.POP_RULES);
        stdstorage.target(popRules).sig("userPopStatus(address)").with_key(user)
            .checked_write(uint256(IPopRules.PopStatus.PopFull));
    }

    function _liteNodeOf(string memory label) internal pure returns (bytes32 node) {
        bytes32 labelhash = keccak256(bytes(label));
        node = keccak256(abi.encodePacked(DotnsConstants.DOT_NODE, labelhash));
    }

    function _validChatKey(bytes1 seed) internal pure returns (bytes memory key) {
        key = new bytes(65);
        for (uint256 i = 0; i < 65; ++i) {
            key[i] = seed;
        }
    }
}
