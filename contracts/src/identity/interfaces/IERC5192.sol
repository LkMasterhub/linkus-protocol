// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.28;

/**
 * @title IERC5192 - Minimal Soulbound NFTs
 * @notice Interface for Soulbound Tokens (non-transferable NFTs)
 * @dev See https://eips.ethereum.org/EIPS/eip-5192
 *
 * A Soulbound Token is a non-transferable NFT bound to a single account.
 * This standard extends ERC-721 with minimal changes to indicate that a token is "locked"
 * and cannot be transferred.
 *
 * RATIONALE:
 * - Minimal interface (1 function, 2 events)
 * - Compatible with existing ERC-721 infrastructure
 * - Clear on-chain indicator of non-transferability
 * - Supports use cases: Academic credentials, Reputation systems, Identity tokens
 *
 * SECURITY CONSIDERATIONS:
 * - Tokens MUST NOT be transferable when locked() returns true
 * - Locked status SHOULD be immutable for most use cases
 * - Unlocking (if supported) MUST emit Unlocked event
 */
interface IERC5192 {
    /**
     * @notice Emitted when the locking status is changed to locked.
     * @dev If a token is minted and the status is locked, this event SHOULD be emitted.
     * @param tokenId The identifier for a token.
     */
    event Locked(uint256 tokenId);

    /**
     * @notice Emitted when the locking status is changed to unlocked.
     * @dev If a token is minted and the status is unlocked, this event SHOULD NOT be emitted.
     * @param tokenId The identifier for a token.
     */
    event Unlocked(uint256 tokenId);

    /**
     * @notice Returns the locking status of a Soulbound Token
     * @dev SBTs assigned to zero address are considered invalid, and queries
     * about them do throw.
     * @param tokenId The identifier for an SBT.
     * @return bool True if the token is locked (Soulbound), false otherwise.
     *
     * IMPLEMENTATION NOTES:
     * - MUST revert if tokenId does not exist
     * - SHOULD return true for permanently locked tokens
     * - MAY return false if unlocking mechanism exists
     */
    function locked(uint256 tokenId) external view returns (bool);
}
