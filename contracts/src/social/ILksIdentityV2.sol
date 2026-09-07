// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ILksIdentityV2
 * @notice Interface minimale pour LksIdentityV2 utilisée par LksSocial
 * @dev Interface pour vérification Identity NFT ownership
 */
interface ILksIdentityV2 {
    /**
     * @notice Get token ID owned by address
     * @param owner Address to check
     * @return uint256 Token ID (0 if none)
     */
    function getTokenIdByOwner(address owner) external view returns (uint256);

    /**
     * @notice Get balance of address (ERC721 standard)
     * @param owner Address to check
     * @return uint256 Balance (0 or 1 for Soulbound)
     */
    function balanceOf(address owner) external view returns (uint256);
}
