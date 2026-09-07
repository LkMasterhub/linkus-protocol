// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {NotIdentityHolder, InvalidTier, Unauthorized} from "./LksErrors.sol";

/**
 * @title LksModifiers
 * @notice Library de pré-conditions partagées entre les contrats V8.
 *
 * Pattern : fonctions `internal view` qui revert custom error si la
 * pré-condition n'est pas satisfaite. Les contrats consommateurs les
 * appellent dans leurs propres modifiers ou en début de fonction.
 *
 * Pourquoi pas des modifiers Solidity directs : les libraries Solidity ne
 * supportent pas `modifier` natif. Le pattern `requireXxx()` reste idiomatic,
 * audit-friendly (un seul appel à grep), et économise du bytecode (les
 * libraries `internal` sont inlinées par le compilateur).
 */
library LksModifiers {
    // ─────────────────────────────────────────────────────────────────────
    // Identity gating
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Revert si `account` ne possède pas un NFT LksIdentityV2.
    /// @dev Appelle `identityContract.balanceOf(account)`. View only.
    function requireIdentityHolder(address identityContract, address account) internal view {
        if (account == address(0)) revert NotIdentityHolder(account);
        // Interface minimaliste pour éviter d'importer LksIdentityV2 entier
        (bool ok, bytes memory data) = identityContract.staticcall(
            abi.encodeWithSignature("balanceOf(address)", account)
        );
        if (!ok || data.length < 32) revert NotIdentityHolder(account);
        uint256 balance = abi.decode(data, (uint256));
        if (balance == 0) revert NotIdentityHolder(account);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Tier gating
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Revert si `account` ne détient pas au moins le tier `minTier`.
    /// @dev Appelle `coreContract.getTier(account)`. View only.
    function requireMinTier(address coreContract, address account, uint8 minTier) internal view {
        (bool ok, bytes memory data) = coreContract.staticcall(
            abi.encodeWithSignature("getTier(address)", account)
        );
        if (!ok || data.length < 32) revert InvalidTier(0);
        uint8 actual = abi.decode(data, (uint8));
        if (actual < minTier) revert InvalidTier(actual);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Generic auth helper
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Revert si la condition est fausse, avec error `Unauthorized()`.
    /// @dev Sucre syntaxique pour les checks ad-hoc sans error dédiée.
    function requireAuthorized(bool condition) internal pure {
        if (!condition) revert Unauthorized();
    }
}
