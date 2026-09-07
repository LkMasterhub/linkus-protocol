// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/core/LksCoreUpgradeable.sol";
import "../src/core/ILksCore.sol";

contract LksCoreUpgradeableTest is Test {
    LksCoreUpgradeable public core;

    address public admin    = address(0xA11CE);
    address public treasury = address(0xBEEF);
    address public alice    = address(0x1111);
    address public bob      = address(0x2222);
    address public social   = address(0x3333); // sera grant SOCIAL_WRITER

    uint256 constant TIER_BASIC_PRICE    = 0.01 ether;
    uint256 constant TIER_STANDARD_PRICE = 0.05 ether;
    uint256 constant TIER_PREMIUM_PRICE  = 0.1 ether;

    // ============================================================================
    // SETUP
    // ============================================================================

    function setUp() public {
        // Deploy implementation
        LksCoreUpgradeable impl = new LksCoreUpgradeable();

        // Deploy proxy with initialize
        bytes memory initData = abi.encodeCall(
            LksCoreUpgradeable.initialize,
            (admin, treasury)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        core = LksCoreUpgradeable(payable(address(proxy)));

        // Configure tiers depuis admin
        vm.startPrank(admin);
        core.setTierConfig(
            ILksCore.AccessTier.BASIC,
            ILksCore.TierConfig({
                monthlyPrice: TIER_BASIC_PRICE,
                reputationBonus: 0,
                active: true
            })
        );
        core.setTierConfig(
            ILksCore.AccessTier.STANDARD,
            ILksCore.TierConfig({
                monthlyPrice: TIER_STANDARD_PRICE,
                reputationBonus: 100,
                active: true
            })
        );
        core.setTierConfig(
            ILksCore.AccessTier.PREMIUM,
            ILksCore.TierConfig({
                monthlyPrice: TIER_PREMIUM_PRICE,
                reputationBonus: 500,
                active: true
            })
        );

        core.grantRole(core.SOCIAL_WRITER(), social);
        vm.stopPrank();

        // Fund test users
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    // ============================================================================
    // INITIALIZATION
    // ============================================================================

    function test_Initialize_grantsAdminRoles() public {
        assertTrue(core.hasRole(core.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(core.hasRole(core.ADMIN_ROLE(), admin));
        assertTrue(core.hasRole(core.PAUSER_ROLE(), admin));
        assertTrue(core.hasRole(core.UPGRADER_ROLE(), admin));
        assertTrue(core.hasRole(core.REGISTRY_ADMIN(), admin));
    }

    function test_Initialize_setsTreasury() public {
        assertEq(core.protocolTreasury(), treasury);
    }

    function test_Initialize_setsDefaultFeeRate() public {
        assertEq(core.platformFeeRate(), 500);
    }

    function test_Initialize_revertIfZeroAdmin() public {
        LksCoreUpgradeable impl = new LksCoreUpgradeable();
        bytes memory initData = abi.encodeCall(
            LksCoreUpgradeable.initialize,
            (address(0), treasury)
        );
        vm.expectRevert(LksCoreUpgradeable.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_revertIfZeroTreasury() public {
        LksCoreUpgradeable impl = new LksCoreUpgradeable();
        bytes memory initData = abi.encodeCall(
            LksCoreUpgradeable.initialize,
            (admin, address(0))
        );
        vm.expectRevert(LksCoreUpgradeable.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_cannotBeCalledTwice() public {
        vm.expectRevert();
        core.initialize(admin, treasury);
    }

    // ============================================================================
    // REGISTRY
    // ============================================================================

    function test_Registry_setContract_asAdmin() public {
        vm.prank(admin);
        core.setContract(keccak256("BUSINESS"), address(0x1234));
        assertEq(core.getContract(keccak256("BUSINESS")), address(0x1234));
    }

    function test_Registry_setContract_revertIfNotAdmin() public {
        vm.expectRevert();
        vm.prank(alice);
        core.setContract(keccak256("BUSINESS"), address(0x1234));
    }

    function test_Registry_setContract_revertIfZero() public {
        vm.prank(admin);
        vm.expectRevert(LksCoreUpgradeable.ZeroAddress.selector);
        core.setContract(keccak256("BUSINESS"), address(0));
    }

    function test_Registry_emitEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, false);
        emit ILksCore.ContractUpdated(keccak256("SOCIAL"), address(0), address(0x5555));
        core.setContract(keccak256("SOCIAL"), address(0x5555));
    }

    // ============================================================================
    // CLAIM TRIAL
    // ============================================================================

    function test_ClaimTrial_setsTrialState() public {
        vm.prank(alice);
        core.claimTrial();

        ILksCore.UserState memory s = core.getUserState(alice);
        assertEq(uint8(s.tier), uint8(ILksCore.AccessTier.BASIC));
        assertEq(uint8(s.subState), uint8(ILksCore.SubscriptionState.TRIAL));
        assertEq(s.expiresAt, block.timestamp + 7 days);
        assertEq(s.trialUsedAt, block.timestamp);
    }

    function test_ClaimTrial_isSubscriptionActive() public {
        vm.prank(alice);
        core.claimTrial();
        assertTrue(core.isSubscriptionActive(alice));
    }

    function test_ClaimTrial_revertIfAlreadyUsed() public {
        vm.prank(alice);
        core.claimTrial();

        vm.prank(alice);
        vm.expectRevert(LksCoreUpgradeable.TrialAlreadyUsed.selector);
        core.claimTrial();
    }

    function test_ClaimTrial_expiresAfter7Days() public {
        vm.prank(alice);
        core.claimTrial();

        vm.warp(block.timestamp + 8 days);
        assertFalse(core.isSubscriptionActive(alice));
        assertEq(uint8(core.getTier(alice)), uint8(ILksCore.AccessTier.NONE));
    }

    // ============================================================================
    // SUBSCRIBE
    // ============================================================================

    function test_Subscribe_basic() public {
        vm.prank(alice);
        core.subscribe{value: TIER_BASIC_PRICE}(ILksCore.AccessTier.BASIC);

        ILksCore.UserState memory s = core.getUserState(alice);
        assertEq(uint8(s.tier), uint8(ILksCore.AccessTier.BASIC));
        assertEq(uint8(s.subState), uint8(ILksCore.SubscriptionState.ACTIVE));
        assertEq(s.expiresAt, block.timestamp + 30 days);
    }

    function test_Subscribe_premium() public {
        vm.prank(alice);
        core.subscribe{value: TIER_PREMIUM_PRICE}(ILksCore.AccessTier.PREMIUM);
        assertEq(uint8(core.getTier(alice)), uint8(ILksCore.AccessTier.PREMIUM));
    }

    function test_Subscribe_excessRefunded() public {
        uint256 balanceBefore = alice.balance;
        uint256 overpay = 0.5 ether;

        vm.prank(alice);
        core.subscribe{value: TIER_BASIC_PRICE + overpay}(ILksCore.AccessTier.BASIC);

        uint256 balanceAfter = alice.balance;
        // Alice paid exactly TIER_BASIC_PRICE, the overpay was refunded
        assertEq(balanceBefore - balanceAfter, TIER_BASIC_PRICE);
    }

    function test_Subscribe_revertIfInsufficientPayment() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                LksCoreUpgradeable.InvalidPayment.selector,
                TIER_BASIC_PRICE,
                TIER_BASIC_PRICE - 1
            )
        );
        core.subscribe{value: TIER_BASIC_PRICE - 1}(ILksCore.AccessTier.BASIC);
    }

    function test_Subscribe_revertIfTierNone() public {
        vm.prank(alice);
        vm.expectRevert(LksCoreUpgradeable.InvalidTier.selector);
        core.subscribe{value: TIER_BASIC_PRICE}(ILksCore.AccessTier.NONE);
    }

    function test_Subscribe_revertIfTierInactive() public {
        vm.prank(admin);
        core.setTierConfig(
            ILksCore.AccessTier.BASIC,
            ILksCore.TierConfig({
                monthlyPrice: TIER_BASIC_PRICE,
                reputationBonus: 0,
                active: false
            })
        );

        vm.prank(alice);
        vm.expectRevert(LksCoreUpgradeable.TierInactive.selector);
        core.subscribe{value: TIER_BASIC_PRICE}(ILksCore.AccessTier.BASIC);
    }

    // ============================================================================
    // RENEW
    // ============================================================================

    function test_Renew_extendsExpiration() public {
        vm.prank(alice);
        core.subscribe{value: TIER_STANDARD_PRICE}(ILksCore.AccessTier.STANDARD);
        uint256 expiry1 = core.getUserState(alice).expiresAt;

        vm.warp(block.timestamp + 10 days);

        vm.prank(alice);
        core.renew{value: TIER_STANDARD_PRICE}();
        uint256 expiry2 = core.getUserState(alice).expiresAt;

        // Renew from old expiry (not from now)
        assertEq(expiry2, expiry1 + 30 days);
    }

    function test_Renew_afterExpiryUsesNow() public {
        vm.prank(alice);
        core.subscribe{value: TIER_STANDARD_PRICE}(ILksCore.AccessTier.STANDARD);

        vm.warp(block.timestamp + 40 days); // Past expiry

        vm.prank(alice);
        core.renew{value: TIER_STANDARD_PRICE}();
        ILksCore.UserState memory s = core.getUserState(alice);

        assertEq(s.expiresAt, block.timestamp + 30 days);
    }

    function test_Renew_revertIfNoSubscription() public {
        vm.prank(alice);
        vm.expectRevert(LksCoreUpgradeable.NoActiveSubscription.selector);
        core.renew{value: TIER_BASIC_PRICE}();
    }

    // ============================================================================
    // CANCEL SUBSCRIPTION — LKS-SUB-01 FIX
    // ============================================================================

    function test_CancelSubscription_refundsAutoRenewAllowance() public {
        // Alice subscribes and enables auto-renew with 3x BASIC price
        vm.startPrank(alice);
        core.subscribe{value: TIER_BASIC_PRICE}(ILksCore.AccessTier.BASIC);

        uint256 depositAmount = 0.01 ether;
        uint256 allowanceAmount = 3 * TIER_BASIC_PRICE;
        core.enableAutoRenew{value: depositAmount + allowanceAmount}();
        vm.stopPrank();

        uint256 balanceBefore = alice.balance;

        // Cancel
        vm.prank(alice);
        core.cancelSubscription();

        // Alice got her allowance back (but NOT her deposit)
        uint256 balanceAfter = alice.balance;
        assertEq(balanceAfter - balanceBefore, allowanceAmount);

        // Deposit is still held in contract state
        ILksCore.UserState memory s = core.getUserState(alice);
        assertEq(s.autoRenewDeposit, depositAmount);
        assertEq(s.autoRenewAllowance, 0);
        assertEq(uint8(s.subState), uint8(ILksCore.SubscriptionState.CANCELLED));
    }

    function test_CancelSubscription_withoutAutoRenew() public {
        vm.prank(alice);
        core.subscribe{value: TIER_BASIC_PRICE}(ILksCore.AccessTier.BASIC);

        vm.prank(alice);
        core.cancelSubscription();

        assertEq(
            uint8(core.getUserState(alice).subState),
            uint8(ILksCore.SubscriptionState.CANCELLED)
        );
    }

    function test_CancelSubscription_revertIfAlreadyCancelled() public {
        vm.startPrank(alice);
        core.subscribe{value: TIER_BASIC_PRICE}(ILksCore.AccessTier.BASIC);
        core.cancelSubscription();

        vm.expectRevert(LksCoreUpgradeable.AlreadyCancelled.selector);
        core.cancelSubscription();
        vm.stopPrank();
    }

    // ============================================================================
    // AUTO RENEW
    // ============================================================================

    function test_EnableAutoRenew_setsDepositAndAllowance() public {
        vm.startPrank(alice);
        core.subscribe{value: TIER_BASIC_PRICE}(ILksCore.AccessTier.BASIC);
        core.enableAutoRenew{value: 0.05 ether}(); // 0.01 deposit + 0.04 allowance
        vm.stopPrank();

        ILksCore.UserState memory s = core.getUserState(alice);
        assertEq(s.autoRenewDeposit, 0.01 ether);
        assertEq(s.autoRenewAllowance, 0.04 ether);
        assertTrue(s.autoRenewEnabled);
    }

    function test_EnableAutoRenew_revertIfAlreadyEnabled() public {
        vm.startPrank(alice);
        core.subscribe{value: TIER_BASIC_PRICE}(ILksCore.AccessTier.BASIC);
        core.enableAutoRenew{value: 0.05 ether}();

        vm.expectRevert(LksCoreUpgradeable.AutoRenewAlreadyEnabled.selector);
        core.enableAutoRenew{value: 0.01 ether}();
        vm.stopPrank();
    }

    function test_EnableAutoRenew_revertIfBelowDeposit() public {
        vm.startPrank(alice);
        core.subscribe{value: TIER_BASIC_PRICE}(ILksCore.AccessTier.BASIC);

        vm.expectRevert(
            abi.encodeWithSelector(
                LksCoreUpgradeable.InvalidPayment.selector,
                0.01 ether,
                0.005 ether
            )
        );
        core.enableAutoRenew{value: 0.005 ether}();
        vm.stopPrank();
    }

    function test_DisableAutoRenew_refundsAllowance() public {
        vm.startPrank(alice);
        core.subscribe{value: TIER_BASIC_PRICE}(ILksCore.AccessTier.BASIC);
        core.enableAutoRenew{value: 0.1 ether}(); // 0.01 deposit + 0.09 allowance
        vm.stopPrank();

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        core.disableAutoRenew();

        assertEq(alice.balance - balanceBefore, 0.09 ether);
        ILksCore.UserState memory s = core.getUserState(alice);
        assertEq(s.autoRenewAllowance, 0);
        assertEq(s.autoRenewDeposit, 0.01 ether); // deposit stays
        assertFalse(s.autoRenewEnabled);
    }

    // ============================================================================
    // REFUND DEPOSIT — LKS-SUB-02 FIX
    // ============================================================================

    function test_RefundDeposit_succeedsWithHighReputation() public {
        // Setup: alice subscribes, enables auto-renew (deposits 0.01), builds reputation
        vm.startPrank(alice);
        core.subscribe{value: TIER_BASIC_PRICE}(ILksCore.AccessTier.BASIC);
        core.enableAutoRenew{value: 0.01 ether}();
        vm.stopPrank();

        // Social adds reputation
        vm.prank(social);
        core.addReputation(alice, 200);

        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        core.refundDeposit();

        assertEq(alice.balance - balanceBefore, 0.01 ether);
        assertEq(core.getUserState(alice).autoRenewDeposit, 0);
    }

    function test_RefundDeposit_revertBelowMinReputation() public {
        vm.startPrank(alice);
        core.subscribe{value: TIER_BASIC_PRICE}(ILksCore.AccessTier.BASIC);
        core.enableAutoRenew{value: 0.01 ether}();
        vm.stopPrank();

        // Reputation = 50 (below MIN_REPUTATION_FOR_REFUND = 100)
        vm.prank(social);
        core.addReputation(alice, 50);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                LksCoreUpgradeable.InsufficientReputation.selector,
                100,
                50
            )
        );
        core.refundDeposit();
    }

    function test_RefundDeposit_revertIfNoDeposit() public {
        vm.prank(social);
        core.addReputation(alice, 500);

        vm.prank(alice);
        vm.expectRevert(LksCoreUpgradeable.DepositAlreadyRefunded.selector);
        core.refundDeposit();
    }

    function test_RefundDeposit_readsReputationOnChain_NotFromParam() public {
        // Le test critique LKS-SUB-02 : n'importe qui peut appeler refundDeposit
        // mais la fonction ne prend PAS de param reputation.
        // La réputation est lue depuis le state on-chain.
        vm.startPrank(alice);
        core.subscribe{value: TIER_BASIC_PRICE}(ILksCore.AccessTier.BASIC);
        core.enableAutoRenew{value: 0.01 ether}();
        vm.stopPrank();

        // Alice essaie sans avoir de reputation → doit revert
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                LksCoreUpgradeable.InsufficientReputation.selector,
                100,
                0
            )
        );
        core.refundDeposit();

        // Bob ne peut pas non plus accélérer en appelant avec "sa" reputation
        vm.prank(bob);
        vm.expectRevert(LksCoreUpgradeable.DepositAlreadyRefunded.selector);
        core.refundDeposit();
    }

    // ============================================================================
    // REPUTATION (SOCIAL_WRITER)
    // ============================================================================

    function test_AddReputation_onlySocialWriter() public {
        vm.prank(social);
        core.addReputation(alice, 100);
        assertEq(core.getReputation(alice), 100);
    }

    function test_AddReputation_revertIfNotSocialWriter() public {
        vm.prank(alice);
        vm.expectRevert();
        core.addReputation(alice, 100);
    }

    function test_RemoveReputation_onlySocialWriter() public {
        vm.startPrank(social);
        core.addReputation(alice, 200);
        core.removeReputation(alice, 50);
        vm.stopPrank();
        assertEq(core.getReputation(alice), 150);
    }

    function test_RemoveReputation_revertOnUnderflow() public {
        vm.prank(social);
        core.addReputation(alice, 50);

        vm.prank(social);
        vm.expectRevert(
            abi.encodeWithSelector(
                LksCoreUpgradeable.ReputationUnderflow.selector,
                50,
                100
            )
        );
        core.removeReputation(alice, 100);
    }

    function test_AddReputation_revertIfZeroAddress() public {
        vm.prank(social);
        vm.expectRevert(LksCoreUpgradeable.ZeroAddress.selector);
        core.addReputation(address(0), 100);
    }

    // ============================================================================
    // WITHDRAW TREASURY — LKS-BIZ-07 FIX
    // ============================================================================

    function test_WithdrawTreasury_sendsEth() public {
        // Fund the contract via multiple subscribes
        vm.prank(alice);
        core.subscribe{value: TIER_PREMIUM_PRICE}(ILksCore.AccessTier.PREMIUM);
        vm.prank(bob);
        core.subscribe{value: TIER_PREMIUM_PRICE}(ILksCore.AccessTier.PREMIUM);

        assertEq(address(core).balance, TIER_PREMIUM_PRICE * 2);

        uint256 treasuryBalanceBefore = treasury.balance;

        vm.prank(admin);
        core.withdrawTreasury(TIER_PREMIUM_PRICE);

        assertEq(treasury.balance - treasuryBalanceBefore, TIER_PREMIUM_PRICE);
        assertEq(address(core).balance, TIER_PREMIUM_PRICE);
    }

    function test_WithdrawTreasury_revertIfNotAdmin() public {
        vm.prank(alice);
        core.subscribe{value: TIER_BASIC_PRICE}(ILksCore.AccessTier.BASIC);

        vm.prank(alice);
        vm.expectRevert();
        core.withdrawTreasury(TIER_BASIC_PRICE);
    }

    function test_WithdrawTreasury_revertIfInsufficientBalance() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                LksCoreUpgradeable.InsufficientBalance.selector,
                1 ether,
                0
            )
        );
        core.withdrawTreasury(1 ether);
    }

    // ============================================================================
    // PAUSE
    // ============================================================================

    function test_Pause_blocksSubscribe() public {
        vm.prank(admin);
        core.pause();

        vm.prank(alice);
        vm.expectRevert();
        core.subscribe{value: TIER_BASIC_PRICE}(ILksCore.AccessTier.BASIC);
    }

    function test_Pause_blocksClaimTrial() public {
        vm.prank(admin);
        core.pause();

        vm.prank(alice);
        vm.expectRevert();
        core.claimTrial();
    }

    function test_Pause_allowsCancelSubscription() public {
        // Users should be able to cancel even when paused
        vm.prank(alice);
        core.subscribe{value: TIER_BASIC_PRICE}(ILksCore.AccessTier.BASIC);

        vm.prank(admin);
        core.pause();

        vm.prank(alice);
        core.cancelSubscription(); // should NOT revert
    }

    function test_Unpause_restoresAccess() public {
        vm.startPrank(admin);
        core.pause();
        core.unpause();
        vm.stopPrank();

        vm.prank(alice);
        core.subscribe{value: TIER_BASIC_PRICE}(ILksCore.AccessTier.BASIC);
        assertEq(uint8(core.getTier(alice)), uint8(ILksCore.AccessTier.BASIC));
    }

    // ============================================================================
    // ADMIN — TIER CONFIG
    // ============================================================================

    function test_SetTierConfig_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        core.setTierConfig(
            ILksCore.AccessTier.BASIC,
            ILksCore.TierConfig({monthlyPrice: 1 ether, reputationBonus: 0, active: true})
        );
    }

    function test_SetTierConfig_updatesStorage() public {
        vm.prank(admin);
        core.setTierConfig(
            ILksCore.AccessTier.STANDARD,
            ILksCore.TierConfig({monthlyPrice: 0.2 ether, reputationBonus: 300, active: true})
        );
        ILksCore.TierConfig memory cfg = core.tierConfigs(ILksCore.AccessTier.STANDARD);
        assertEq(cfg.monthlyPrice, 0.2 ether);
        assertEq(cfg.reputationBonus, 300);
        assertTrue(cfg.active);
    }

    // ============================================================================
    // ADMIN — FEE RATE
    // ============================================================================

    function test_SetPlatformFeeRate_ok() public {
        vm.prank(admin);
        core.setPlatformFeeRate(1000);
        assertEq(core.platformFeeRate(), 1000);
    }

    function test_SetPlatformFeeRate_revertIfTooHigh() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                LksCoreUpgradeable.FeeRateTooHigh.selector,
                3001,
                3000
            )
        );
        core.setPlatformFeeRate(3001);
    }

    // ============================================================================
    // UPGRADE AUTHORIZATION
    // ============================================================================

    function test_UpgradeTo_onlyUpgraderRole() public {
        LksCoreUpgradeable newImpl = new LksCoreUpgradeable();

        // Non-upgrader fails
        vm.prank(alice);
        vm.expectRevert();
        UUPSUpgradeable(address(core)).upgradeToAndCall(address(newImpl), "");

        // Admin succeeds
        vm.prank(admin);
        UUPSUpgradeable(address(core)).upgradeToAndCall(address(newImpl), "");
    }

    // ============================================================================
    // INVARIANT-STYLE CHECK (treasury accounting)
    // ============================================================================

    function test_TreasuryAccounting_subscriptionsFundContract() public {
        uint256 before = address(core).balance;

        vm.prank(alice);
        core.subscribe{value: TIER_BASIC_PRICE}(ILksCore.AccessTier.BASIC);
        vm.prank(bob);
        core.subscribe{value: TIER_PREMIUM_PRICE}(ILksCore.AccessTier.PREMIUM);

        // Both subs funded the contract
        assertEq(address(core).balance - before, TIER_BASIC_PRICE + TIER_PREMIUM_PRICE);
    }
}
