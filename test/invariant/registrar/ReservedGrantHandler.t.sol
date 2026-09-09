// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {
    IDotnsRegistrarController,
    DotnsRegistrarController
} from "../../../contracts/registrars/DotnsRegistrarController.sol";
import {IDotnsNameWhitelist} from "../../../contracts/whitelist/IDotnsNameWhitelist.sol";
import {IDotnsReverseResolver} from "../../../contracts/resolvers/IDotnsReverseResolver.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {DotnsRegistrar} from "../../../contracts/registrars/DotnsRegistrar.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";
import {ISystem} from "../../../contracts/external/revive/ISystem.sol";

/// @title ReservedGrantHandler
/// @notice Bounded random-action handler for the grant-gated reserved registration path.
/// @dev Drives three actions the fuzzer interleaves freely: granting a label, minting a granted
///      label from an arbitrary submitter, and attempting a mint with no grant at all. Ghost state
///      records what was granted to whom so the suite can assert the gate, single use, and the
///      reverse-record silence without re-deriving them from the contracts under test.
contract ReservedGrantHandler is Test {
    DotnsRegistrarController public immutable CONTROLLER;
    IDotnsNameWhitelist public immutable WHITELIST;
    DotnsRegistrar public immutable REGISTRAR;
    IDotnsReverseResolver public immutable REVERSE;
    IPopRules public immutable POP_RULES;

    /// @notice Actor pool used as beneficiaries and as submitters.
    address[] internal actors;

    /// @notice Labels granted but not yet minted, and the address each is bound to.
    string[] internal pendingLabels;
    mapping(string label => address beneficiary) public grantedTo;

    /// @notice Labels successfully minted through the reserved path, with their beneficiary.
    string[] internal mintedLabels;
    mapping(string label => address beneficiary) public mintedTo;

    /// @notice Every address that has only ever received names through the reserved path.
    address[] internal beneficiaries;
    mapping(address account => bool seen) internal isBeneficiary;

    /// @notice Trips true if a mint ever succeeds without a grant naming its owner. A correct gate
    /// keeps this false for the whole campaign.
    bool public sawUngrantedMint;

    /// @notice Trips true if a mint ever lands on an address other than the granted beneficiary.
    bool public sawWrongOwner;

    /// @notice Trips true if a spent grant is ever accepted a second time.
    bool public sawDoubleSpend;

    /// @notice Trips true if a grant is still live immediately after the mint that should have
    /// spent it. Direct evidence that `consume` ran, independent of any later revert.
    bool public sawGrantSurviveMint;

    /// @notice Trips true if a mint succeeds for an address the label was not granted to.
    bool public sawGrantOwnerMismatch;

    /// @notice Counters exposed so the suite can prove the campaign was not vacuous.
    uint256 public grantCount;
    uint256 public mintCount;
    uint256 public ungrantedAttemptCount;

    uint64 internal nonce;

    constructor(
        DotnsRegistrarController controller,
        IDotnsNameWhitelist whitelist,
        DotnsRegistrar registrar,
        IDotnsReverseResolver reverseResolver,
        IPopRules popRules
    ) {
        CONTROLLER = controller;
        WHITELIST = whitelist;
        REGISTRAR = registrar;
        REVERSE = reverseResolver;
        POP_RULES = popRules;
    }

    function addActor(address actor) external {
        actors.push(actor);
    }

    /// @notice Grants a fresh label to a pool actor.
    function grantName(uint256 actorSeed) public {
        if (actors.length == 0) return;
        address beneficiary = actors[actorSeed % actors.length];
        string memory label = _freshLabel();

        // The whitelist is Root-only. Restore the default afterwards: `registerReserved` reads
        // `originIsRoot` too, and a sticky `true` would skip the grant check and the consume.
        _mockOriginIsRoot(true);
        WHITELIST.grantName(label, beneficiary);
        _mockOriginIsRoot(false);

        pendingLabels.push(label);
        grantedTo[label] = beneficiary;
        _rememberBeneficiary(beneficiary);
        ++grantCount;
    }

    /// @notice Mints a granted label, submitted by an arbitrary actor rather than the beneficiary.
    function mintGranted(uint256 labelSeed, uint256 submitterSeed) external {
        uint256 count = pendingLabels.length;
        if (count == 0) return;

        uint256 index = labelSeed % count;
        string memory label = pendingLabels[index];
        address beneficiary = grantedTo[label];
        address submitter = actors[submitterSeed % actors.length];

        _reveal(label, beneficiary, submitter);

        if (REGISTRAR.ownerOf(_tokenId(label)) != beneficiary) sawWrongOwner = true;
        // Read the grant back rather than inferring consumption from a later failure: the grant
        // check precedes the availability check, so a grant left live would surface as
        // `NameNotAvailable` and be indistinguishable from a correctly spent one.
        if (WHITELIST.isGrantedTo(label, beneficiary)) sawGrantSurviveMint = true;

        pendingLabels[index] = pendingLabels[count - 1];
        pendingLabels.pop();
        mintedLabels.push(label);
        mintedTo[label] = beneficiary;
        ++mintCount;
    }

    /// @notice Attempts a mint of a granted label for someone other than its beneficiary. The gate
    /// pairs label and owner, so this must fail even though the label does carry a live grant.
    function attemptGrantOwnerMismatch(uint256 labelSeed, uint256 submitterSeed) external {
        uint256 count = pendingLabels.length;
        if (count == 0 || actors.length < 2) return;

        string memory label = pendingLabels[labelSeed % count];
        address beneficiary = grantedTo[label];
        uint256 pick = submitterSeed % actors.length;
        address impostor = actors[pick];
        if (impostor == beneficiary) impostor = actors[(pick + 1) % actors.length];
        if (impostor == beneficiary) return;

        try this.reveal(label, impostor, impostor) {
            sawGrantOwnerMismatch = true;
        } catch {}
    }

    /// @notice Attempts a reserved mint for a label with no grant. Must never succeed.
    function attemptUngranted(uint256 ownerSeed, uint256 submitterSeed) external {
        if (actors.length == 0) return;
        address beneficiary = actors[ownerSeed % actors.length];
        address submitter = actors[submitterSeed % actors.length];
        string memory label = _freshLabel();

        ++ungrantedAttemptCount;
        try this.reveal(label, beneficiary, submitter) {
            sawUngrantedMint = true;
        } catch {}
    }

    /// @notice Attempts to re-mint an already spent grant. Must never succeed.
    function attemptDoubleSpend(uint256 labelSeed, uint256 submitterSeed) external {
        uint256 count = mintedLabels.length;
        if (count == 0) return;

        string memory label = mintedLabels[labelSeed % count];
        address submitter = actors[submitterSeed % actors.length];

        try this.reveal(label, mintedTo[label], submitter) {
            sawDoubleSpend = true;
        } catch {}
    }

    /// @notice External wrapper so the attempt paths can `try`/`catch` a whole commit-reveal.
    function reveal(string calldata label, address beneficiary, address submitter) external {
        require(msg.sender == address(this), "internal");
        _reveal(label, beneficiary, submitter);
    }

    function pendingLabelCount() external view returns (uint256 count) {
        count = pendingLabels.length;
    }

    function mintedLabelsList() external view returns (string[] memory labels) {
        labels = mintedLabels;
    }

    function beneficiaryList() external view returns (address[] memory list) {
        list = beneficiaries;
    }

    function tokenIdOf(string calldata label) external view returns (uint256 tokenId) {
        tokenId = _tokenId(label);
    }

    function _reveal(string memory label, address beneficiary, address submitter) internal {
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label,
                owner: beneficiary,
                secret: keccak256(abi.encodePacked(label, beneficiary, submitter)),
                reserved: true,
                maxPrice: type(uint256).max,
                pricingVersion: POP_RULES.pricingVersion()
            });

        vm.startPrank(submitter);
        CONTROLLER.commit(CONTROLLER.makeCommitment(registration));
        vm.warp(block.timestamp + CONTROLLER.minCommitmentAge() + 1);
        CONTROLLER.registerReserved(registration);
        vm.stopPrank();
    }

    function _rememberBeneficiary(address account) internal {
        if (isBeneficiary[account]) return;
        isBeneficiary[account] = true;
        beneficiaries.push(account);
    }

    /// @notice Mocks the revive `originIsRoot()` query for the next call.
    function _mockOriginIsRoot(bool returnValue) internal {
        vm.mockCall(
            DotnsConstants.REVIVE_SYSTEM,
            abi.encodeWithSelector(ISystem.originIsRoot.selector),
            abi.encode(returnValue)
        );
    }

    function _freshLabel() internal returns (string memory label) {
        ++nonce;
        label = string.concat("grantinv", vm.toString(nonce));
    }

    function _tokenId(string memory label) internal view returns (uint256 tokenId) {
        tokenId = uint256(
            keccak256(
                abi.encodePacked(REGISTRAR.protocolRegistry().tldNode(), keccak256(bytes(label)))
            )
        );
    }
}
