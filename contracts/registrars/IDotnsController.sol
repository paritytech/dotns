// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IDotnsController
/// @notice Baseline interface implemented by every controller authorised on
///         `DotnsRegistrar`.
/// @dev Marker interface that types `DotnsRegistrar.controllers` so every
///      authorised caller (public commit-reveal, PoP gateway, any future
///      privileged flow) fits the same mapping and the same `addController` /
///      `removeController` signatures without forcing a common call surface.
///      Extending {IERC165} lets the registrar (or any observer) runtime-check
///      which concrete controller interface a given address implements.
/// @custom:security-contact admin@parity.io
interface IDotnsController is IERC165 {}
