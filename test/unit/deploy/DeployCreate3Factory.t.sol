// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {Create3FactoryCode} from "../../../scripts/deploy/Create3FactoryCode.sol";
import {DeployCreate3Factory} from "../../../scripts/deploy/DeployCreate3Factory.s.sol";

/// @notice Covers the single-purpose-key guard on the standalone factory deploy
///         script. The factory address is nonce-derived, so the script must
///         only deploy from a pristine key to keep that address reproducible
///         across chain resets. The successful deploy path
///         (`Create3FactoryCode.deploy`) is exercised by the deterministic-deployment
///         suite; here the novel behaviour is the nonce-0 assertion, which cannot be
///         pranked and broadcast in one call, so only the guard is unit-tested. The
///         canonical factory code the script deploys is pinned here too.
contract DeployCreate3FactoryTest is Test {
    DeployCreate3Factory private script;

    function setUp() public {
        script = new DeployCreate3Factory();
    }

    function test_revertsWhenDeployerNonceNotZero() public {
        address deployer = makeAddr("reused-key");
        vm.setNonce(deployer, 5);

        vm.prank(deployer);
        vm.expectRevert(
            bytes(
                "DeployCreate3Factory: deployer nonce is not 0; use a single-purpose key so the factory address is reproducible across chain resets"
            )
        );
        script.run();
    }

    /// @notice The canonical init code deploys to the pinned codehash.
    function test_canonicalInitCodeDeploysToThePinnedCodehash() public {
        assertEq(Create3FactoryCode.deploy().codehash, Create3FactoryCode.RUNTIME_CODEHASH);
    }

    /// @notice The canonical runtime code is the `Create3Factory` build apart from its metadata,
    ///         so the source still describes the factory every network runs.
    /// @dev Coverage builds without the optimizer, so their code differs throughout. If a
    ///      compiler or settings change breaks this test, adapt the test: regenerating the
    ///      pinned code would make the deploy scripts reject the live factory.
    function test_canonicalRuntimeIsTheBuildApartFromMetadata() public {
        if (vm.isContext(VmSafe.ForgeContext.Coverage)) vm.skip(true);
        assertEq(
            _withoutMetadata(Create3FactoryCode.deploy().code),
            _withoutMetadata(vm.getDeployedCode("Create3Factory.sol:Create3Factory"))
        );
    }

    /// @notice The canonical init code's constructor is the `Create3Factory` build's, so the
    ///         pinned init code runs nothing beyond copying the runtime code into place.
    /// @dev Coverage builds without the optimizer, so their code differs throughout.
    function test_canonicalConstructorIsTheBuilds() public {
        if (vm.isContext(VmSafe.ForgeContext.Coverage)) vm.skip(true);
        bytes memory initCode = Create3FactoryCode.INIT_CODE;
        bytes memory built = vm.getCode("Create3Factory.sol:Create3Factory");
        uint256 constructorLength = initCode.length - Create3FactoryCode.deploy().code.length;
        assertEq(initCode.length, built.length, "init code length");
        assertEq(_prefix(initCode, constructorLength), _prefix(built, constructorLength));
    }

    /// @notice Strips the CBOR metadata solc appends to runtime code.
    /// @dev The last two bytes hold the metadata length. The metadata hashes the sources and the
    ///      compiler settings; every byte before it is compiled logic.
    function _withoutMetadata(bytes memory code) private pure returns (bytes memory) {
        uint256 metadataLength =
            ((uint256(uint8(code[code.length - 2])) << 8) | uint8(code[code.length - 1])) + 2;
        return _prefix(code, code.length - metadataLength);
    }

    /// @notice The first `length` bytes of `code`.
    function _prefix(bytes memory code, uint256 length) private pure returns (bytes memory head) {
        head = new bytes(length);
        for (uint256 i; i < length; ++i) {
            head[i] = code[i];
        }
    }
}
