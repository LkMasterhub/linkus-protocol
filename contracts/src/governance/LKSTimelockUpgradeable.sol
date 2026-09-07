// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title LKSTimelockUpgradeable
 * @notice Timelock controller pour sécurité gouvernance LinkUs Protocol (UUPS Upgradeable)
 * @dev Compatible avec LksGovernance.sol - Delay 2 jours minimum
 */
contract LKSTimelockUpgradeable is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // ========== ROLES ==========

    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 public constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ========== TYPES ==========

    enum OperationState { UNSET, WAITING, READY, DONE }

    struct Operation {
        bytes32 id;
        address target;
        uint256 value;
        bytes data;
        bytes32 predecessor;
        uint256 timestamp;
        bool executed;
        bool cancelled;
    }

    // ========== STORAGE ==========

    uint256 public constant MIN_DELAY = 2 days;
    uint256 public constant MAX_DELAY = 30 days;

    uint256 public delay;
    mapping(bytes32 => Operation) private _operations;
    mapping(bytes32 => uint256) private _timestamps;
    uint256 private _nonce;

    // ========== EVENTS ==========

    event CallScheduled(bytes32 indexed id, uint256 indexed index, address target, uint256 value, bytes data, bytes32 predecessor, uint256 delay);
    event CallExecuted(bytes32 indexed id, uint256 indexed index, address target, uint256 value, bytes data);
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

    // ========== CONSTRUCTOR & INITIALIZER ==========

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) public initializer {
        if (minDelay < MIN_DELAY || minDelay > MAX_DELAY) {
            revert InvalidDelay(minDelay);
        }

        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        delay = minDelay;

        // LKS-TL-01 fix : accorder DEFAULT_ADMIN_ROLE à admin pour que TIMELOCK_ADMIN_ROLE
        // reste administrable. Sans ce grant, getRoleAdmin(TIMELOCK_ADMIN_ROLE) = DEFAULT_ADMIN_ROLE
        // et personne ne peut modifier TIMELOCK_ADMIN_ROLE → rôle immutable figé sur le deployer.
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TIMELOCK_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _setRoleAdmin(TIMELOCK_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(PROPOSER_ROLE, TIMELOCK_ADMIN_ROLE);
        _setRoleAdmin(EXECUTOR_ROLE, TIMELOCK_ADMIN_ROLE);
        _setRoleAdmin(CANCELLER_ROLE, TIMELOCK_ADMIN_ROLE);

        for (uint256 i = 0; i < proposers.length; i++) {
            _grantRole(PROPOSER_ROLE, proposers[i]);
        }

        if (executors.length == 0) {
            _grantRole(EXECUTOR_ROLE, address(0));
        } else {
            for (uint256 i = 0; i < executors.length; i++) {
                _grantRole(EXECUTOR_ROLE, executors[i]);
            }
        }

        _grantRole(PROPOSER_ROLE, admin);
        _grantRole(EXECUTOR_ROLE, admin);
        _grantRole(CANCELLER_ROLE, admin);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // ========== SCHEDULE FUNCTIONS ==========

    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) external onlyRole(PROPOSER_ROLE) returns (bytes32) {
        return _schedule(target, value, data, predecessor, salt, delay);
    }

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

    function cancel(bytes32 id) external onlyRole(CANCELLER_ROLE) {
        if (_timestamps[id] == 0) revert OperationNotScheduled(id);
        if (_timestamps[id] == 1) revert OperationAlreadyExecuted(id);

        delete _timestamps[id];

        emit CallCancelled(id);
    }

    // ========== VIEW FUNCTIONS ==========

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

    function isOperation(bytes32 id) public view returns (bool) {
        return getOperationState(id) != OperationState.UNSET;
    }

    function isOperationPending(bytes32 id) public view returns (bool) {
        return getOperationState(id) == OperationState.WAITING;
    }

    function isOperationReady(bytes32 id) public view returns (bool) {
        return getOperationState(id) == OperationState.READY;
    }

    function isOperationDone(bytes32 id) public view returns (bool) {
        return getOperationState(id) == OperationState.DONE;
    }

    function getTimestamp(bytes32 id) external view returns (uint256) {
        return _timestamps[id];
    }

    function hashOperation(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(target, value, data, predecessor, salt));
    }

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
        _timestamps[id] = 1;
    }

    // ========== RECEIVE ETH ==========

    receive() external payable {}

    // ========== STORAGE GAP ==========

    uint256[50] private __gap;
}
