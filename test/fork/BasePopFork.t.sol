// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseUpgradeFork} from "./BaseUpgradeFork.t.sol";
import {IDotnsPopController} from "../../contracts/registrars/IDotnsPopController.sol";
import {IDotnsPopControllerLegacy} from "../../contracts/registrars/IDotnsPopControllerLegacy.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {IPersonhood} from "../../contracts/external/personhood/IPersonhood.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {LabelUtils} from "../../contracts/utils/LabelUtils.sol";

/// @title BasePopFork
/// @notice Shared PoP issuance flow for the fork tests that swap the PoP resolver, controller and
///         lens: issues a device name and a personhood name linked to it through the legacy
///         entrypoints the gateway pallet calls.
/// @dev Paseo's PoP resolver holds no links yet, so there is no live link to read back across the
///      swap. Writing one through the upgraded pair and reading it back in both directions is
///      what proves the pair works together. The labels are chosen to be unregistered on Paseo;
///      `_requireUnregistered` turns a collision into a clear failure.
/// @custom:security-contact admin@parity.io
abstract contract BasePopFork is BaseUpgradeFork {
    /// @notice Device name issued by the flow, `stem.NN`.
    string internal constant DEVICE_LABEL = "zqxforkp.07";

    /// @notice Personhood name issued by the flow, linked to `DEVICE_LABEL`.
    string internal constant PERSONHOOD_LABEL = "zqxforkp";

    /// @notice Account the flow issues both names to.
    address internal popUser;

    function setUp() public virtual override {
        super.setUp();
        popUser = makeAddr("popUser");
    }

    /// @notice Issues `DEVICE_LABEL`, then `PERSONHOOD_LABEL` linked to it, under a Root origin.
    /// @dev Goes through `IDotnsPopControllerLegacy`, the selectors the frozen gateway pallet
    ///      dispatches, so the test covers the path live traffic takes.
    /// @param controller DotnsPopController proxy.
    /// @return personhoodNode Node of the issued personhood name.
    function _issueLinkedPair(address controller) internal returns (bytes32 personhoodNode) {
        _mockRootOrigin();
        _mockPersonhood(popUser, 2);

        personhoodNode = _nodeOf(PERSONHOOD_LABEL);
        _requireUnregistered(personhoodNode);

        IDotnsPopControllerLegacy(controller)
            .reserveLiteName(
                IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL, user: popUser, chatKey: _chatKey()
            })
            );
        IDotnsPopControllerLegacy(controller)
            .registerBaseName(
                IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL,
                user: popUser,
                link: IDotnsPopController.Link({
                kind: IDotnsPopController.LinkKind.DeviceName,
                deviceLabel: DEVICE_LABEL,
                chatKey: ""
            })
            })
            );
    }

    /// @notice Node of a name directly under the TLD.
    function _nodeOf(string memory label) internal view returns (bytes32 node) {
        bytes32 tldNode = IDotnsProtocolRegistry(_live("DotnsProtocolRegistry")).tldNode();
        node = LabelUtils.namehashUnder(tldNode, LabelUtils.labelhashMemory(label));
    }

    /// @notice A valid 65-byte uncompressed chat key.
    function _chatKey() internal pure returns (bytes memory key) {
        key = new bytes(65);
        key[0] = 0x04;
        for (uint256 i = 1; i < 65; ++i) {
            key[i] = 0x2a;
        }
    }

    /// @notice Makes the personhood precompile report `status` for `who` in the dotNS context.
    /// @dev The precompile is not part of forked state, so every read of it is mocked.
    function _mockPersonhood(address who, uint8 status) internal {
        vm.mockCall(
            DotnsConstants.PERSONHOOD,
            abi.encodeWithSelector(
                IPersonhood.personhoodStatus.selector, who, DotnsConstants.PERSONHOOD_CONTEXT
            ),
            abi.encode(
                IPersonhood.PersonhoodInfo({
                    status: status, contextAlias: keccak256(abi.encode(who, status))
                })
            )
        );
    }

    /// @notice Reverts unless `node` is unowned on the fork.
    function _requireUnregistered(bytes32 node) internal view {
        (bool ok, bytes memory data) =
            _live("DotnsRegistry").staticcall(abi.encodeWithSignature("owner(bytes32)", node));
        require(
            ok && abi.decode(data, (address)) == address(0),
            "fork: the PoP test label is already registered on this network"
        );
    }
}
