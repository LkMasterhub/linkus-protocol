// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LksPaymaster} from "../src/paymaster/LksPaymaster.sol";
import {IPaymaster} from "../src/paymaster/interfaces/IPaymaster.sol";
import {IEntryPoint} from "../src/paymaster/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "../src/paymaster/interfaces/PackedUserOperation.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract MockEntryPoint {
    mapping(address => uint256) public deposits;
    mapping(address => uint256) public stakes;

    function depositTo(address account) external payable {
        deposits[account] += msg.value;
    }

    function balanceOf(address account) external view returns (uint256) {
        return deposits[account];
    }

    function addStake(uint32) external payable {
        stakes[msg.sender] += msg.value;
    }

    function unlockStake() external {}

    function withdrawStake(address payable to) external {
        uint256 amount = stakes[msg.sender];
        stakes[msg.sender] = 0;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "stake xfer failed");
    }

    function withdrawTo(address payable to, uint256 amount) external {
        require(deposits[msg.sender] >= amount, "insufficient deposit");
        deposits[msg.sender] -= amount;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "xfer failed");
    }

    receive() external payable {}
}

contract LksPaymasterTest is Test {
    using MessageHashUtils for bytes32;

    LksPaymaster internal paymaster;
    MockEntryPoint internal entryPoint;

    address internal signer;
    uint256 internal signerKey;
    address internal admin;
    address internal user;

    uint256 internal constant MAX_COST = 0.01 ether;
    uint256 internal constant DAILY_BUDGET = 1 ether;

    function setUp() public {
        (signer, signerKey) = makeAddrAndKey("signer");
        admin = makeAddr("admin");
        user = makeAddr("user");

        entryPoint = new MockEntryPoint();
        paymaster = new LksPaymaster(IEntryPoint(address(entryPoint)), signer, admin);

        vm.deal(admin, 100 ether);
        vm.deal(address(this), 100 ether);
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    function _hashUserOp(PackedUserOperation memory userOp, uint48 validUntil, uint48 validAfter)
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
                address(paymaster),
                validUntil,
                validAfter
            )
        );
    }

    function _signUserOp(uint256 key, PackedUserOperation memory userOp, uint48 validUntil, uint48 validAfter)
        internal
        view
        returns (bytes memory)
    {
        bytes32 ethHash = _hashUserOp(userOp, validUntil, validAfter).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function _buildPaymasterAndData(uint48 validUntil, uint48 validAfter, bytes memory sig)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodePacked(
            address(paymaster),
            uint128(50_000),
            uint128(30_000),
            bytes6(uint48ToBytes6(validUntil)),
            bytes6(uint48ToBytes6(validAfter)),
            sig
        );
    }

    function uint48ToBytes6(uint48 value) internal pure returns (bytes6) {
        return bytes6(uint48(value));
    }

    function _buildUserOp(address sender, bytes memory paymasterAndData)
        internal
        pure
        returns (PackedUserOperation memory)
    {
        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(abi.encodePacked(uint128(100_000), uint128(100_000))),
            preVerificationGas: 21_000,
            gasFees: bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei))),
            paymasterAndData: paymasterAndData,
            signature: ""
        });
    }

    function _buildSignedUserOp(uint256 key, uint48 validUntil, uint48 validAfter)
        internal
        view
        returns (PackedUserOperation memory)
    {
        bytes memory dummySig = new bytes(65);
        bytes memory pmData = _buildPaymasterAndData(validUntil, validAfter, dummySig);
        PackedUserOperation memory userOp = _buildUserOp(user, pmData);

        bytes memory sig = _signUserOp(key, userOp, validUntil, validAfter);
        userOp.paymasterAndData = _buildPaymasterAndData(validUntil, validAfter, sig);
        return userOp;
    }

    function _buildValidUserOp(uint48 validUntil, uint48 validAfter)
        internal
        view
        returns (PackedUserOperation memory)
    {
        return _buildSignedUserOp(signerKey, validUntil, validAfter);
    }

    // ========================================================================
    // Constructor
    // ========================================================================

    function test_Deployment() public view {
        assertEq(address(paymaster.entryPoint()), address(entryPoint));
        assertEq(paymaster.paymasterSigner(), signer);
        assertEq(paymaster.maxCostAllowed(), 0.01 ether);
        assertEq(paymaster.dailyBudget(), 1 ether);
        assertTrue(paymaster.hasRole(paymaster.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(paymaster.hasRole(paymaster.OPERATOR_ROLE(), admin));
        assertFalse(paymaster.emergencyStopped());
    }

    function test_Constructor_RevertZeroEntryPoint() public {
        vm.expectRevert(LksPaymaster.ZeroAddress.selector);
        new LksPaymaster(IEntryPoint(address(0)), signer, admin);
    }

    function test_Constructor_RevertZeroSigner() public {
        vm.expectRevert(LksPaymaster.ZeroAddress.selector);
        new LksPaymaster(IEntryPoint(address(entryPoint)), address(0), admin);
    }

    function test_Constructor_RevertZeroAdmin() public {
        vm.expectRevert(LksPaymaster.ZeroAddress.selector);
        new LksPaymaster(IEntryPoint(address(entryPoint)), signer, address(0));
    }

    // ========================================================================
    // validatePaymasterUserOp
    // ========================================================================

    function test_ValidatePaymasterUserOp_ValidSignature() public {
        bytes32 userOpHash = keccak256("op1");
        uint48 validUntil = uint48(block.timestamp + 15 minutes);
        uint48 validAfter = uint48(block.timestamp);
        uint256 maxCost = 0.005 ether;

        PackedUserOperation memory userOp = _buildValidUserOp(validUntil, validAfter);

        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(
            userOp, userOpHash, maxCost
        );

        // sigAuthorizer = 0 (valid)
        assertEq(uint160(validationData), 0);
        // validUntil packed at bits 160-207
        assertEq((validationData >> 160) & ((1 << 48) - 1), validUntil);
        // validAfter packed at bits 208-255
        assertEq(validationData >> 208, validAfter);

        // Context contains (day, maxCost)
        (uint256 day, uint256 reservedCost) = abi.decode(context, (uint256, uint256));
        assertEq(day, block.timestamp / 1 days);
        assertEq(reservedCost, maxCost);

        // Daily usage updated
        (, uint256 used) = paymaster.getDailyUsed();
        assertEq(used, maxCost);
    }

    function test_ValidatePaymasterUserOp_InvalidSignature_ReturnsSigFailed() public {
        bytes32 userOpHash = keccak256("op2");
        uint48 validUntil = uint48(block.timestamp + 15 minutes);
        uint48 validAfter = uint48(block.timestamp);

        (, uint256 wrongKey) = makeAddrAndKey("attacker");
        PackedUserOperation memory userOp = _buildSignedUserOp(wrongKey, validUntil, validAfter);

        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(
            userOp, userOpHash, 0.005 ether
        );

        // sigAuthorizer = 1 (failed)
        assertEq(uint160(validationData), 1);
        // Empty context
        assertEq(context.length, 0);
        // Daily usage NOT updated
        (, uint256 used) = paymaster.getDailyUsed();
        assertEq(used, 0);
    }

    function test_ValidatePaymasterUserOp_RevertsOverMaxCost() public {
        bytes32 userOpHash = keccak256("op3");
        uint48 validUntil = uint48(block.timestamp + 15 minutes);
        uint48 validAfter = uint48(block.timestamp);
        uint256 tooMuch = 0.02 ether; // > 0.01 ether allowed

        PackedUserOperation memory userOp = _buildValidUserOp(validUntil, validAfter);

        vm.prank(address(entryPoint));
        vm.expectRevert(
            abi.encodeWithSelector(LksPaymaster.SponsorshipTooExpensive.selector, tooMuch, MAX_COST)
        );
        paymaster.validatePaymasterUserOp(userOp, userOpHash, tooMuch);
    }

    function test_ValidatePaymasterUserOp_RevertsDailyBudgetExceeded() public {
        vm.prank(admin);
        paymaster.setDailyBudget(0.005 ether);

        bytes32 userOpHash = keccak256("op4");
        uint48 validUntil = uint48(block.timestamp + 15 minutes);
        uint48 validAfter = uint48(block.timestamp);

        PackedUserOperation memory userOp = _buildValidUserOp(validUntil, validAfter);

        uint256 maxCost = 0.01 ether; // > 0.005 budget
        vm.prank(address(entryPoint));
        vm.expectRevert(
            abi.encodeWithSelector(LksPaymaster.DailyBudgetExceeded.selector, maxCost, 0.005 ether)
        );
        paymaster.validatePaymasterUserOp(userOp, userOpHash, maxCost);
    }

    function test_ValidatePaymasterUserOp_RevertsOnlyEntryPoint() public {
        bytes32 userOpHash = keccak256("op5");
        PackedUserOperation memory userOp = _buildValidUserOp(uint48(block.timestamp + 1), uint48(block.timestamp));

        vm.prank(user);
        vm.expectRevert(LksPaymaster.OnlyEntryPoint.selector);
        paymaster.validatePaymasterUserOp(userOp, userOpHash, 0.001 ether);
    }

    function test_ValidatePaymasterUserOp_RevertsInvalidDataLength() public {
        PackedUserOperation memory userOp = _buildUserOp(user, hex"1234");

        vm.prank(address(entryPoint));
        vm.expectRevert(abi.encodeWithSelector(LksPaymaster.InvalidPaymasterDataLength.selector, 2));
        paymaster.validatePaymasterUserOp(userOp, keccak256("op"), 0.001 ether);
    }

    function test_ValidatePaymasterUserOp_RevertsEmergencyStop() public {
        vm.prank(admin);
        paymaster.toggleEmergencyStop(true);

        bytes32 userOpHash = keccak256("op6");
        PackedUserOperation memory userOp = _buildValidUserOp(uint48(block.timestamp + 1), uint48(block.timestamp));

        vm.prank(address(entryPoint));
        vm.expectRevert(LksPaymaster.EmergencyStopActive.selector);
        paymaster.validatePaymasterUserOp(userOp, userOpHash, 0.001 ether);
    }

    // ========================================================================
    // postOp
    // ========================================================================

    function test_PostOp_RefundsUnusedBudget() public {
        bytes32 userOpHash = keccak256("op7");
        uint48 validUntil = uint48(block.timestamp + 15 minutes);
        uint48 validAfter = uint48(block.timestamp);
        uint256 maxCost = 0.005 ether;

        PackedUserOperation memory userOp = _buildValidUserOp(validUntil, validAfter);

        vm.prank(address(entryPoint));
        (bytes memory context,) = paymaster.validatePaymasterUserOp(userOp, userOpHash, maxCost);

        (, uint256 usedBefore) = paymaster.getDailyUsed();
        assertEq(usedBefore, maxCost);

        // postOp reports actual cost much lower
        uint256 actualCost = 0.001 ether;
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, actualCost, 1 gwei);

        (, uint256 usedAfter) = paymaster.getDailyUsed();
        assertEq(usedAfter, actualCost, "daily usage should reflect actual cost");
    }

    function test_PostOp_RevertsOnlyEntryPoint() public {
        bytes memory context = abi.encode(uint256(0), uint256(0.001 ether));
        vm.prank(user);
        vm.expectRevert(LksPaymaster.OnlyEntryPoint.selector);
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 0, 0);
    }

    // ========================================================================
    // Admin
    // ========================================================================

    function test_SetPaymasterSigner() public {
        address newSigner = makeAddr("newSigner");
        vm.prank(admin);
        paymaster.setPaymasterSigner(newSigner);
        assertEq(paymaster.paymasterSigner(), newSigner);
    }

    function test_SetPaymasterSigner_RevertsZero() public {
        vm.prank(admin);
        vm.expectRevert(LksPaymaster.ZeroAddress.selector);
        paymaster.setPaymasterSigner(address(0));
    }

    function test_SetPaymasterSigner_RevertsNonOperator() public {
        vm.prank(user);
        vm.expectRevert();
        paymaster.setPaymasterSigner(makeAddr("x"));
    }

    function test_SetMaxCostAllowed() public {
        vm.prank(admin);
        paymaster.setMaxCostAllowed(0.1 ether);
        assertEq(paymaster.maxCostAllowed(), 0.1 ether);
    }

    function test_SetMaxCostAllowed_RevertsZero() public {
        vm.prank(admin);
        vm.expectRevert(LksPaymaster.ZeroMaxCost.selector);
        paymaster.setMaxCostAllowed(0);
    }

    function test_SetDailyBudget() public {
        vm.prank(admin);
        paymaster.setDailyBudget(10 ether);
        assertEq(paymaster.dailyBudget(), 10 ether);
    }

    function test_ToggleEmergencyStop() public {
        vm.prank(admin);
        paymaster.toggleEmergencyStop(true);
        assertTrue(paymaster.emergencyStopped());

        vm.prank(admin);
        paymaster.toggleEmergencyStop(false);
        assertFalse(paymaster.emergencyStopped());
    }

    // ========================================================================
    // Deposit management
    // ========================================================================

    function test_Deposit() public {
        paymaster.deposit{value: 1 ether}();
        assertEq(paymaster.getDeposit(), 1 ether);
    }

    function test_ReceiveEth_Deposits() public {
        (bool ok,) = address(paymaster).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(paymaster.getDeposit(), 0.5 ether);
    }

    function test_WithdrawTo() public {
        paymaster.deposit{value: 1 ether}();
        address payable dest = payable(makeAddr("dest"));

        vm.prank(admin);
        paymaster.withdrawTo(dest, 0.3 ether);

        assertEq(dest.balance, 0.3 ether);
        assertEq(paymaster.getDeposit(), 0.7 ether);
    }

    function test_WithdrawTo_RevertsNonAdmin() public {
        paymaster.deposit{value: 1 ether}();
        vm.prank(user);
        vm.expectRevert();
        paymaster.withdrawTo(payable(user), 0.1 ether);
    }

    function test_AddStake_UnlockStake_WithdrawStake() public {
        address payable dest = payable(makeAddr("stakeDest"));

        vm.prank(admin);
        paymaster.addStake{value: 2 ether}(86_400);

        vm.prank(admin);
        paymaster.unlockStake();

        vm.prank(admin);
        paymaster.withdrawStake(dest);

        assertEq(dest.balance, 2 ether);
    }

    // ========================================================================
    // Integration: full flow validate → postOp
    // ========================================================================

    function test_FullFlow_MultipleOpsIndependent() public {
        uint48 validUntil = uint48(block.timestamp + 15 minutes);
        uint48 validAfter = uint48(block.timestamp);

        // Op 1
        bytes32 h1 = keccak256("op-1");
        PackedUserOperation memory op1 = _buildValidUserOp(validUntil, validAfter);
        vm.prank(address(entryPoint));
        (bytes memory ctx1,) = paymaster.validatePaymasterUserOp(op1, h1, 0.003 ether);

        // Op 2 — use different nonce so UserOp hash differs and sig is unique
        bytes32 h2 = keccak256("op-2");
        PackedUserOperation memory op2 = _buildValidUserOp(validUntil, validAfter);
        op2.nonce = 1;
        bytes memory sig2 = _signUserOp(signerKey, op2, validUntil, validAfter);
        op2.paymasterAndData = _buildPaymasterAndData(validUntil, validAfter, sig2);
        vm.prank(address(entryPoint));
        (bytes memory ctx2,) = paymaster.validatePaymasterUserOp(op2, h2, 0.004 ether);

        (, uint256 usedReserved) = paymaster.getDailyUsed();
        assertEq(usedReserved, 0.007 ether);

        // postOp 1: actual 0.001
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx1, 0.001 ether, 1 gwei);

        // postOp 2: actual 0.002
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx2, 0.002 ether, 1 gwei);

        (, uint256 usedActual) = paymaster.getDailyUsed();
        assertEq(usedActual, 0.003 ether);
    }

    function test_GetHash_Deterministic() public view {
        bytes memory dummySig = new bytes(65);
        bytes memory pmData = _buildPaymasterAndData(100, 50, dummySig);
        PackedUserOperation memory op = _buildUserOp(user, pmData);

        bytes32 h1 = paymaster.getHash(op, 100, 50);
        bytes32 h2 = paymaster.getHash(op, 100, 50);
        assertEq(h1, h2);

        bytes32 h3 = paymaster.getHash(op, 101, 50);
        assertTrue(h1 != h3);
    }
}
