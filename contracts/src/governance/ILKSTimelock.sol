// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ILKSTimelock
 * @notice Interface minimale pour LKSTimelock utilisée par LksGovernance
 * @dev Interface pour interactions governance <-> timelock
 */
interface ILKSTimelock {
    /**
     * @notice Schedule batch opérations
     * @param targets Contracts à appeler
     * @param values ETH à envoyer
     * @param payloads Calldatas
     * @param predecessor ID opération précédente
     * @param salt Salt pour unicité
     * @return bytes32 ID batch operation
     */
    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) external returns (bytes32);

    /**
     * @notice Execute batch opérations après timelock
     * @param targets Contracts
     * @param values Values
     * @param payloads Calldatas
     * @param predecessor Predecessor
     * @param salt Salt
     */
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) external payable;

    /**
     * @notice Cancel opération
     * @param id ID opération
     */
    function cancel(bytes32 id) external;

    /**
     * @notice Get timestamp opération
     * @param id ID opération
     * @return uint256 Timestamp ready
     */
    function getTimestamp(bytes32 id) external view returns (uint256);

    /**
     * @notice Check si opération est ready
     * @param id ID opération
     * @return bool True si ready
     */
    function isOperationReady(bytes32 id) external view returns (bool);

    /**
     * @notice Hash opération batch
     * @param targets Contracts
     * @param values Values
     * @param payloads Calldatas
     * @param predecessor Predecessor
     * @param salt Salt
     * @return bytes32 ID batch
     */
    function hashOperationBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) external pure returns (bytes32);
}
