// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IContent1155
 * @notice Content NFTs ERC1155 + ERC2981 royalties.
 *
 * tokenId = uint256(keccak256(abi.encodePacked(creator, contentCid))) — déterministe,
 * collision impossible si (creator, cid) unique.
 *
 * Patterns :
 * - registerContent : créateur déclare un contenu (tokenId calculé)
 * - purchase : msg.value split en creatorShare + platformFee, mint 1 token au buyer
 * - earnedAccess : signature EIP-712 backend permet d'accorder l'accès gratuit
 * - withdrawEarnings : pull pattern pour le créateur
 * - royaltyInfo : ERC2981 standard (marketplace pickup)
 *
 * Invariants :
 * - mintCount[tokenId] <= maxSupply[tokenId]
 * - sum(pendingEarnings[*]) <= address(this).balance
 * - royaltyBps <= 10000
 */
interface IContent1155 {
    // ─────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────

    struct ContentMeta {
        address creator;
        uint128 price; // wei par mint
        uint96 maxSupply; // 0 = unlimited
        uint16 royaltyBps; // pour ERC2981 secondary sales
        uint96 mintCount; // nombre déjà mint
        bytes32 contentCid; // CID off-chain (BLAKE3 ou IPFS)
        bool soulbound; // true ⇒ safeTransferFrom revert
    }

    // ─────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────

    event ContentRegistered(
        uint256 indexed tokenId,
        address indexed creator,
        bytes32 contentCid,
        uint128 price,
        uint96 maxSupply,
        uint16 royaltyBps,
        bool soulbound
    );

    event ContentPurchased(
        uint256 indexed tokenId,
        address indexed buyer,
        address indexed creator,
        uint256 creatorShare,
        uint256 platformFee
    );

    event AccessEarned(uint256 indexed tokenId, address indexed user, bytes32 nonce);
    event EarningsWithdrawn(address indexed creator, uint256 amount);
    event PlatformFeeBpsUpdated(uint16 oldBps, uint16 newBps);

    // ─────────────────────────────────────────────────────────────────
    // Reads
    // ─────────────────────────────────────────────────────────────────

    /// @notice Calcule le tokenId pour (creator, contentCid).
    function tokenIdOf(address creator, bytes32 contentCid) external pure returns (uint256);

    /// @notice Métadonnées d'un contenu enregistré.
    function contentMeta(uint256 tokenId) external view returns (ContentMeta memory);

    /// @notice Earnings en attente pour un créateur.
    function pendingEarnings(address creator) external view returns (uint256);

    /// @notice Taux de fee plateforme (bps).
    function platformFeeBps() external view returns (uint16);

    /// @notice Cap maximal du platformFeeBps (3000 = 30%).
    function MAX_PLATFORM_FEE_BPS() external view returns (uint16);

    /// @notice ERC2981 : retourne (recipient, royaltyAmount) pour une revente.
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address recipient, uint256 royaltyAmount);

    // ─────────────────────────────────────────────────────────────────
    // User flows
    // ─────────────────────────────────────────────────────────────────

    /// @notice Créateur enregistre son contenu. tokenId déterministe.
    function registerContent(
        bytes32 contentCid,
        uint128 price,
        uint96 maxSupply,
        uint16 royaltyBps,
        bool soulbound
    ) external returns (uint256 tokenId);

    /// @notice Acheter un mint pour ce content. msg.value >= price.
    function purchase(uint256 tokenId) external payable;

    /// @notice Accès gratuit via signature backend (EIP-712 nonce, anti-replay).
    function earnAccess(uint256 tokenId, bytes32 nonce, uint64 deadline, bytes calldata sig) external;

    /// @notice Créateur retire ses earnings (CEI pull).
    function withdrawEarnings() external;

    // ─────────────────────────────────────────────────────────────────
    // Admin (TIMELOCK)
    // ─────────────────────────────────────────────────────────────────

    function setPlatformFeeBps(uint16 newBps) external;
    function setEarnSigner(address newSigner) external;
    function pause() external;
    function unpause() external;
}
