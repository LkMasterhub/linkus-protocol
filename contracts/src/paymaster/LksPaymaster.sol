// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {IPaymaster} from "./interfaces/IPaymaster.sol";
import {IEntryPoint} from "./interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "./interfaces/PackedUserOperation.sol";

contract LksPaymaster is IPaymaster, AccessControl {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint256 private constant PAYMASTER_DATA_OFFSET = 52;
    uint256 private constant SIG_OFFSET = PAYMASTER_DATA_OFFSET + 12;
    uint256 private constant PAYMASTER_AND_DATA_MIN_LENGTH = SIG_OFFSET + 65;

    IEntryPoint public immutable entryPoint;
    address public paymasterSigner;

    uint256 public maxCostAllowed;
    uint256 public dailyBudget;
    mapping(uint256 => uint256) public dayBudgetUsed;

    bool public emergencyStopped;

    event PaymasterSignerUpdated(address indexed oldSigner, address indexed newSigner);
    event MaxCostUpdated(uint256 newMaxCost);
    event DailyBudgetUpdated(uint256 newBudget);
    event EmergencyStopToggled(bool stopped);
    event SponsorshipValidated(address indexed sender, uint256 maxCost, uint48 validUntil);
    event DepositIncreased(address indexed from, uint256 amount);

    error ZeroAddress();
    error ZeroMaxCost();
    error OnlyEntryPoint();
    error EmergencyStopActive();
    error SponsorshipTooExpensive(uint256 maxCost, uint256 allowed);
    error DailyBudgetExceeded(uint256 used, uint256 budget);
    error InvalidPaymasterDataLength(uint256 length);

    modifier onlyEntryPoint() {
        if (msg.sender != address(entryPoint)) revert OnlyEntryPoint();
        _;
    }

    constructor(IEntryPoint _entryPoint, address _paymasterSigner, address _admin) {
        if (address(_entryPoint) == address(0)) revert ZeroAddress();
        if (_paymasterSigner == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();

        entryPoint = _entryPoint;
        paymasterSigner = _paymasterSigner;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);

        maxCostAllowed = 0.01 ether;
        dailyBudget = 1 ether;
    }

    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32,
        uint256 maxCost
    ) external override onlyEntryPoint returns (bytes memory context, uint256 validationData) {
        if (emergencyStopped) revert EmergencyStopActive();
        if (userOp.paymasterAndData.length < PAYMASTER_AND_DATA_MIN_LENGTH) {
            revert InvalidPaymasterDataLength(userOp.paymasterAndData.length);
        }

        uint48 validUntil = uint48(bytes6(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET:PAYMASTER_DATA_OFFSET + 6]));
        uint48 validAfter = uint48(bytes6(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET + 6:SIG_OFFSET]));
        bytes calldata signature = userOp.paymasterAndData[SIG_OFFSET:SIG_OFFSET + 65];

        bytes32 digest = _getHash(userOp, validUntil, validAfter).toEthSignedMessageHash();
        address recovered = digest.recover(signature);

        if (recovered != paymasterSigner) {
            return ("", _packValidationData(true, validUntil, validAfter));
        }

        if (maxCost > maxCostAllowed) revert SponsorshipTooExpensive(maxCost, maxCostAllowed);

        uint256 day = block.timestamp / 1 days;
        uint256 usedToday = dayBudgetUsed[day] + maxCost;
        if (usedToday > dailyBudget) revert DailyBudgetExceeded(usedToday, dailyBudget);
        dayBudgetUsed[day] = usedToday;

        emit SponsorshipValidated(userOp.sender, maxCost, validUntil);

        context = abi.encode(day, maxCost);
        validationData = _packValidationData(false, validUntil, validAfter);
    }

    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external override onlyEntryPoint {
        (mode, actualUserOpFeePerGas);

        (uint256 day, uint256 reservedCost) = abi.decode(context, (uint256, uint256));

        if (actualGasCost < reservedCost) {
            uint256 refund = reservedCost - actualGasCost;
            uint256 current = dayBudgetUsed[day];
            dayBudgetUsed[day] = refund > current ? 0 : current - refund;
        }
    }

    function _packValidationData(bool sigFailed, uint48 validUntil, uint48 validAfter)
        internal
        pure
        returns (uint256)
    {
        uint256 sigAuthorizer = sigFailed ? 1 : 0;
        return sigAuthorizer | (uint256(validUntil) << 160) | (uint256(validAfter) << 208);
    }

    function getHash(PackedUserOperation calldata userOp, uint48 validUntil, uint48 validAfter)
        external
        view
        returns (bytes32)
    {
        return _getHash(userOp, validUntil, validAfter);
    }

    function _getHash(PackedUserOperation calldata userOp, uint48 validUntil, uint48 validAfter)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                userOp.sender,
                userOp.nonce,
                keccak256(userOp.initCode),
                keccak256(userOp.callData),
                userOp.accountGasLimits,
                userOp.preVerificationGas,
                userOp.gasFees,
                block.chainid,
                address(this),
                validUntil,
                validAfter
            )
        );
    }

    function setPaymasterSigner(address newSigner) external onlyRole(OPERATOR_ROLE) {
        if (newSigner == address(0)) revert ZeroAddress();
        address old = paymasterSigner;
        paymasterSigner = newSigner;
        emit PaymasterSignerUpdated(old, newSigner);
    }

    function setMaxCostAllowed(uint256 newMax) external onlyRole(OPERATOR_ROLE) {
        if (newMax == 0) revert ZeroMaxCost();
        maxCostAllowed = newMax;
        emit MaxCostUpdated(newMax);
    }

    function setDailyBudget(uint256 newBudget) external onlyRole(OPERATOR_ROLE) {
        dailyBudget = newBudget;
        emit DailyBudgetUpdated(newBudget);
    }

    function toggleEmergencyStop(bool stopped) external onlyRole(OPERATOR_ROLE) {
        emergencyStopped = stopped;
        emit EmergencyStopToggled(stopped);
    }

    function deposit() external payable {
        entryPoint.depositTo{value: msg.value}(address(this));
        emit DepositIncreased(msg.sender, msg.value);
    }

    function withdrawTo(address payable to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        entryPoint.withdrawTo(to, amount);
    }

    function addStake(uint32 unstakeDelaySec) external payable onlyRole(DEFAULT_ADMIN_ROLE) {
        entryPoint.addStake{value: msg.value}(unstakeDelaySec);
    }

    function unlockStake() external onlyRole(DEFAULT_ADMIN_ROLE) {
        entryPoint.unlockStake();
    }

    function withdrawStake(address payable to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        entryPoint.withdrawStake(to);
    }

    function getDeposit() external view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    function getDailyUsed() external view returns (uint256 day, uint256 used) {
        day = block.timestamp / 1 days;
        used = dayBudgetUsed[day];
    }

    receive() external payable {
        entryPoint.depositTo{value: msg.value}(address(this));
        emit DepositIncreased(msg.sender, msg.value);
    }
}
