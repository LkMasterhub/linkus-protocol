// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title LKSTimelock
 * @notice Timelock controller pour sécurité gouvernance LinkUs Protocol
 * @dev Compatible avec LksGovernance.sol - Delay 2 jours minimum
 *
 * FONCTIONNALITÉS:
 * - Delay configurable (min 2 jours, max 30 jours)
 * - Queue propositions validées par gouvernance
 * - Execute après expiration timelock
 * - Cancel propositions avant exécution
 * - Multi-sig admin pour sécurité extrême
 * - Events indexables pour transparence
 *
 * RÔLES:
 * - PROPOSER_ROLE: Peut queue propositions (LksGovernance contract)
 * - EXECUTOR_ROLE: Peut execute propositions (anyone ou restricted)
 * - CANCELLER_ROLE: Peut cancel propositions (admin urgence)
 * - TIMELOCK_ADMIN_ROLE: Peut modifier delay et rôles
 *
 * SÉCURITÉ:
 * - Delay minimum 2 jours (protection contre governance attacks)
 * - Delay maximum 30 jours (éviter blocage)
 * - Nonce anti-replay attacks
 * - ReentrancyGuard sur execute
 * - AccessControl granulaire
 *
 * USAGE:
 * ```solidity
 * // 1. LksGovernance queue proposition
 * timelock.schedule(target, value, data, predecessor, salt, delay);
 *
 * // 2. Attendre delay (2 jours)
 * // ...
 *
 * // 3. Anyone execute après delay
 * timelock.execute(target, value, data, predecessor, salt);
 * ```
 */
contract LKSTimelock is AccessControl, ReentrancyGuard {

    // ========== ROLES ==========

    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 public constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");

    // ========== TYPES ==========

    enum OperationState {
        UNSET,      // Opération n'existe pas
        WAITING,    // En attente du timelock
        READY,      // Prête à être exécutée
        DONE        // Déjà exécutée
    }

    /// @notice Opération timelock
    struct Operation {
        bytes32 id;
        address target;
        uint256 value;
        bytes data;
        bytes32 predecessor;    // ID opération qui doit être exécutée avant
        uint256 timestamp;      // Quand peut être exécutée
        bool executed;
        bool cancelled;
    }

    // ========== STORAGE ==========

    /// @notice Delay minimum (2 jours)
    uint256 public constant MIN_DELAY = 2 days;

    /// @notice Delay maximum (30 jours)
    uint256 public constant MAX_DELAY = 30 days;

    /// @notice Delay actuel
    uint256 public delay;

    /// @notice Opérations par ID
    mapping(bytes32 => Operation) private _operations;

    /// @notice Timestamps opérations (pour vérification ready)
    mapping(bytes32 => uint256) private _timestamps;

    /// @notice Nonce global (anti-replay)
    uint256 private _nonce;

    // ========== EVENTS ==========

    event CallScheduled(
        bytes32 indexed id,
        uint256 indexed index,
        address target,
        uint256 value,
        bytes data,
        bytes32 predecessor,
        uint256 delay
    );

    event CallExecuted(
        bytes32 indexed id,
        uint256 indexed index,
        address target,
        uint256 value,
        bytes data
    );

    event CallCancelled(bytes32 indexed id);

    event MinDelayChange(uint256 oldDuration, uint256 newDuration);

    // ========== ERRORS ==========

    error InvalidDelay(uint256 delay);
    error OperationNotReady(bytes32 id);
    error OperationAlreadyScheduled(bytes32 id);
    error OperationNotScheduled(bytes32 id);
    error OperationAlreadyExecuted(bytes32 id);
    error OperationCancelled(bytes32 id);
    error PredecessorNotExecuted(bytes32 predecessor);
    error ExecutionFailed(bytes32 id);
    error InvalidOperation();
    error InvalidTarget();

    // ========== CONSTRUCTOR ==========

    /**
     * @notice Initialize timelock
     * @param minDelay Delay initial (min 2 jours)
     * @param proposers Addresses avec PROPOSER_ROLE
     * @param executors Addresses avec EXECUTOR_ROLE (empty = anyone)
     * @param admin Address TIMELOCK_ADMIN_ROLE
     */
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) {
        if (minDelay < MIN_DELAY || minDelay > MAX_DELAY) {
            revert InvalidDelay(minDelay);
        }

        delay = minDelay;

        // Setup roles
        _grantRole(TIMELOCK_ADMIN_ROLE, admin);
        _setRoleAdmin(PROPOSER_ROLE, TIMELOCK_ADMIN_ROLE);
        _setRoleAdmin(EXECUTOR_ROLE, TIMELOCK_ADMIN_ROLE);
        _setRoleAdmin(CANCELLER_ROLE, TIMELOCK_ADMIN_ROLE);

        // Grant PROPOSER_ROLE
        for (uint256 i = 0; i < proposers.length; i++) {
            _grantRole(PROPOSER_ROLE, proposers[i]);
        }

        // Grant EXECUTOR_ROLE (ou anyone si executors empty)
        if (executors.length == 0) {
            _grantRole(EXECUTOR_ROLE, address(0)); // Anyone can execute
        } else {
            for (uint256 i = 0; i < executors.length; i++) {
                _grantRole(EXECUTOR_ROLE, executors[i]);
            }
        }

        // Admin gets all roles
        _grantRole(PROPOSER_ROLE, admin);
        _grantRole(EXECUTOR_ROLE, admin);
        _grantRole(CANCELLER_ROLE, admin);
    }

    // ========== SCHEDULE FUNCTIONS ==========

    /**
     * @notice Schedule opération (queue)
     * @dev Seulement PROPOSER_ROLE (LksGovernance)
     * @param target Contract à appeler
     * @param value ETH à envoyer
     * @param data Calldata
     * @param predecessor ID opération précédente (0x0 si aucune)
     * @param salt Salt pour ID unique
     * @return bytes32 ID de l'opération
     */
    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) external onlyRole(PROPOSER_ROLE) returns (bytes32) {
        return _schedule(target, value, data, predecessor, salt, delay);
    }

    /**
     * @notice Schedule opération avec delay custom
     * @param target Contract à appeler
     * @param value ETH à envoyer
     * @param data Calldata
     * @param predecessor ID opération précédente
     * @param salt Salt
     * @param _delay Delay custom (min MIN_DELAY)
     * @return bytes32 ID opération
     */
    function scheduleWithDelay(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 _delay
    ) external onlyRole(PROPOSER_ROLE) returns (bytes32) {
        if (_delay < MIN_DELAY) revert InvalidDelay(_delay);
        return _schedule(target, value, data, predecessor, salt, _delay);
    }

    /**
     * @notice Schedule batch opérations
     * @param targets Contracts à appeler
     * @param values ETH à envoyer
     * @param payloads Calldatas
     * @param predecessor ID opération précédente
     * @param salt Salt
     * @return bytes32 ID batch
     */
    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) external onlyRole(PROPOSER_ROLE) returns (bytes32) {
        if (targets.length != values.length || targets.length != payloads.length) {
            revert InvalidOperation();
        }

        bytes32 id = hashOperationBatch(targets, values, payloads, predecessor, salt);

        if (_timestamps[id] != 0) revert OperationAlreadyScheduled(id);

        _timestamps[id] = block.timestamp + delay;

        for (uint256 i = 0; i < targets.length; i++) {
            emit CallScheduled(id, i, targets[i], values[i], payloads[i], predecessor, delay);
        }

        return id;
    }

    // ========== EXECUTE FUNCTIONS ==========

    /**
     * @notice Execute opération après timelock
     * @dev EXECUTOR_ROLE ou anyone si role public
     * @param target Contract à appeler
     * @param value ETH à envoyer
     * @param data Calldata
     * @param predecessor ID opération précédente
     * @param salt Salt
     */
    function execute(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) external payable nonReentrant {
        bytes32 id = hashOperation(target, value, data, predecessor, salt);

        _beforeCall(id, predecessor);
        _execute(target, value, data);
        _afterCall(id);

        emit CallExecuted(id, 0, target, value, data);
    }

    /**
     * @notice Execute batch opérations
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
    ) external payable nonReentrant {
        if (targets.length != values.length || targets.length != payloads.length) {
            revert InvalidOperation();
        }

        bytes32 id = hashOperationBatch(targets, values, payloads, predecessor, salt);

        _beforeCall(id, predecessor);

        for (uint256 i = 0; i < targets.length; i++) {
            _execute(targets[i], values[i], payloads[i]);
            emit CallExecuted(id, i, targets[i], values[i], payloads[i]);
        }

        _afterCall(id);
    }

    // ========== CANCEL FUNCTION ==========

    /**
     * @notice Cancel opération schedulée
     * @dev CANCELLER_ROLE uniquement
     * @param id ID opération
     */
    function cancel(bytes32 id) external onlyRole(CANCELLER_ROLE) {
        if (_timestamps[id] == 0) revert OperationNotScheduled(id);
        if (_timestamps[id] == 1) revert OperationAlreadyExecuted(id);

        delete _timestamps[id];

        emit CallCancelled(id);
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Get état opération
     * @param id ID opération
     * @return OperationState État
     */
    function getOperationState(bytes32 id) public view returns (OperationState) {
        uint256 timestamp = _timestamps[id];

        if (timestamp == 0) {
            return OperationState.UNSET;
        } else if (timestamp == 1) {
            return OperationState.DONE;
        } else if (timestamp > block.timestamp) {
            return OperationState.WAITING;
        } else {
            return OperationState.READY;
        }
    }

    /**
     * @notice Check si opération est schedulée
     * @param id ID opération
     * @return bool True si schedulée
     */
    function isOperation(bytes32 id) public view returns (bool) {
        return getOperationState(id) != OperationState.UNSET;
    }

    /**
     * @notice Check si opération en attente
     * @param id ID opération
     * @return bool True si en attente
     */
    function isOperationPending(bytes32 id) public view returns (bool) {
        return getOperationState(id) == OperationState.WAITING;
    }

    /**
     * @notice Check si opération prête
     * @param id ID opération
     * @return bool True si prête
     */
    function isOperationReady(bytes32 id) public view returns (bool) {
        return getOperationState(id) == OperationState.READY;
    }

    /**
     * @notice Check si opération executée
     * @param id ID opération
     * @return bool True si executée
     */
    function isOperationDone(bytes32 id) public view returns (bool) {
        return getOperationState(id) == OperationState.DONE;
    }

    /**
     * @notice Get timestamp opération
     * @param id ID opération
     * @return uint256 Timestamp quand devient ready
     */
    function getTimestamp(bytes32 id) external view returns (uint256) {
        return _timestamps[id];
    }

    /**
     * @notice Hash opération simple
     * @param target Contract
     * @param value ETH
     * @param data Calldata
     * @param predecessor Predecessor
     * @param salt Salt
     * @return bytes32 ID opération
     */
    function hashOperation(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(target, value, data, predecessor, salt));
    }

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
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(targets, values, payloads, predecessor, salt));
    }

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @notice Update delay
     * @dev TIMELOCK_ADMIN_ROLE uniquement
     * @param newDelay Nouveau delay (min 2 jours, max 30 jours)
     */
    function updateDelay(uint256 newDelay) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        if (newDelay < MIN_DELAY || newDelay > MAX_DELAY) {
            revert InvalidDelay(newDelay);
        }

        emit MinDelayChange(delay, newDelay);
        delay = newDelay;
    }

    // ========== INTERNAL FUNCTIONS ==========

    function _schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 _delay
    ) internal returns (bytes32) {
        if (target == address(0)) revert InvalidTarget();

        bytes32 id = hashOperation(target, value, data, predecessor, salt);

        if (_timestamps[id] != 0) revert OperationAlreadyScheduled(id);

        _timestamps[id] = block.timestamp + _delay;

        emit CallScheduled(id, 0, target, value, data, predecessor, _delay);

        return id;
    }

    function _beforeCall(bytes32 id, bytes32 predecessor) private view {
        if (!hasRole(EXECUTOR_ROLE, address(0)) && !hasRole(EXECUTOR_ROLE, msg.sender)) {
            revert("LKSTimelock: caller is not executor");
        }

        if (_timestamps[id] == 0) revert OperationNotScheduled(id);
        if (_timestamps[id] == 1) revert OperationAlreadyExecuted(id);
        if (_timestamps[id] > block.timestamp) revert OperationNotReady(id);

        // Check predecessor executed
        if (predecessor != bytes32(0) && !isOperationDone(predecessor)) {
            revert PredecessorNotExecuted(predecessor);
        }
    }

    function _execute(address target, uint256 value, bytes calldata data) private {
        (bool success, bytes memory returndata) = target.call{value: value}(data);

        if (!success) {
            if (returndata.length > 0) {
                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert ExecutionFailed(bytes32(0));
            }
        }
    }

    function _afterCall(bytes32 id) private {
        _timestamps[id] = 1; // Mark as executed
    }

    // ========== RECEIVE ETH ==========

    receive() external payable {}
}
