// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LksCoreV8} from "./LksCoreV8.sol";
import {ZeroAddress, NotIdentityHolder} from "../shared/LksErrors.sol";

/// @dev Interface minimale ERC721 pour vérifier la possession du NFT identité.
interface IIdentityBalance {
    function balanceOf(address owner) external view returns (uint256);
}

/**
 * @title  LksCoreV8V2
 * @notice Extension UUPS de LksCoreV8 — ajoute le mapping `nodeIdOf` qui lie
 *         l'adresse Ethereum du wallet (owner du NFT `LksIdentityV2`) au
 *         `nodeId` (32 bytes BLAKE3 du pubkey WASM utilisé par lks-core).
 *
 *         Permet le lookup wallet ↔ nodeId pour :
 *         - chiffrer des blobs vers un nodeId target (ECDH off-chain)
 *         - tipper le bon auteur en résolvant son nodeId
 *         - audit forensique d'un nodeId malveillant
 *
 *         La vérification cryptographique (signature WASM key sur
 *         `(chainId, wallet, nodeId)`) reste **off-chain** — un DID Document
 *         IPFS attaché via `LksIdentityV2.didDocumentHash` fournit la preuve
 *         publique. Ce mapping n'est qu'un index lookup rapide.
 *
 * @dev Storage layout (preserves V1) :
 *      - V1 : `_userState` (0), `_registry` (1), `_repCap` (2),
 *             `treasury` (3), `__gap[45]` (4–48)
 *      - V2 : `_nodeIdOf` (49), `__gapV2[49]` (50–98) — réservé futur
 */
contract LksCoreV8V2 is LksCoreV8 {
    // ─────────────────────────────────────────────────────────────────
    // Storage V2 (append-only)
    // ─────────────────────────────────────────────────────────────────

    /// @dev wallet → nodeId BLAKE3 (32B). `bytes32(0)` = unbound.
    mapping(address => bytes32) internal _nodeIdOf;

    /// @dev Réservé pour upgrade futur V3 (UUPS storage gap V2).
    uint256[49] private __gapV2;

    // ─────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────

    event NodeIdBound(address indexed wallet, bytes32 indexed nodeId);
    event NodeIdUnbound(address indexed wallet, bytes32 indexed previousNodeId);

    // ─────────────────────────────────────────────────────────────────
    // Writes (user-callable)
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Lie le `nodeId` du caller à son adresse Ethereum.
     * @dev    Le caller DOIT posséder au moins 1 NFT `LksIdentityV2`. La
     *         verification est cross-call best-effort : si MODULE_IDENTITY
     *         n'est pas enregistré ou si `balanceOf` revert, on revert.
     *         Les rebind successifs sont autorisés (overwrite).
     * @param  nodeId  32 bytes BLAKE3 du pubkey WASM. `bytes32(0)` interdit.
     */
    function bindNodeId(bytes32 nodeId) external whenNotPaused {
        if (nodeId == bytes32(0)) revert ZeroAddress();
        address identity = _registry[MODULE_IDENTITY];
        if (identity == address(0)) revert NotIdentityHolder(msg.sender);
        uint256 bal = IIdentityBalance(identity).balanceOf(msg.sender);
        if (bal == 0) revert NotIdentityHolder(msg.sender);

        _nodeIdOf[msg.sender] = nodeId;
        emit NodeIdBound(msg.sender, nodeId);
    }

    /**
     * @notice Déconnecte le `nodeId` du caller (ex: rotation device).
     * @dev    No-op silencieux si déjà unbound (toujours emit avec
     *         `previousNodeId = 0`). N'exige pas la possession du NFT pour
     *         laisser un user qui a brûlé son identité nettoyer le mapping.
     */
    function unbindNodeId() external whenNotPaused {
        bytes32 prev = _nodeIdOf[msg.sender];
        delete _nodeIdOf[msg.sender];
        emit NodeIdUnbound(msg.sender, prev);
    }

    // ─────────────────────────────────────────────────────────────────
    // Reads
    // ─────────────────────────────────────────────────────────────────

    /// @notice Retourne le nodeId lié au wallet, ou `bytes32(0)` si non lié.
    function getNodeId(address wallet) external view returns (bytes32) {
        return _nodeIdOf[wallet];
    }

    /// @notice True si le wallet a un nodeId lié.
    function hasNodeId(address wallet) external view returns (bool) {
        return _nodeIdOf[wallet] != bytes32(0);
    }
}
