// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/core/LksCoreUpgradeable.sol";
import "../src/core/ILksCore.sol";
import "../src/social/LksSocialModule.sol";
import "../src/social/ILksIdentityV2.sol";

/**
 * @dev Mock IdentityV2 qui retourne un tokenId fictif pour chaque adresse passée en "mintIdentity".
 */
contract MockIdentityV2 {
    mapping(address => uint256) public tokenIdOf;
    uint256 private _nextId;

    function mintTo(address user) external returns (uint256) {
        _nextId++;
        tokenIdOf[user] = _nextId;
        return _nextId;
    }

    function getTokenIdByOwner(address owner) external view returns (uint256) {
        return tokenIdOf[owner];
    }

    function balanceOf(address owner) external view returns (uint256) {
        return tokenIdOf[owner] > 0 ? 1 : 0;
    }
}

contract LksSocialModuleTest is Test {
    LksCoreUpgradeable public core;
    LksSocialModule public social;
    MockIdentityV2 public identity;

    address public admin    = address(0xA11CE);
    address public treasury = address(0xBEEF);
    address public alice    = address(0x1111);
    address public bob      = address(0x2222);
    address public charlie  = address(0x3333);
    address public dave     = address(0x4444);

    uint256 constant TIER_PREMIUM_PRICE = 0.1 ether;

    function setUp() public {
        // Deploy Core
        LksCoreUpgradeable coreImpl = new LksCoreUpgradeable();
        ERC1967Proxy coreProxy = new ERC1967Proxy(
            address(coreImpl),
            abi.encodeCall(LksCoreUpgradeable.initialize, (admin, treasury))
        );
        core = LksCoreUpgradeable(payable(address(coreProxy)));

        // Deploy identity mock
        identity = new MockIdentityV2();

        // Deploy social
        LksSocialModule socialImpl = new LksSocialModule();
        ERC1967Proxy socialProxy = new ERC1967Proxy(
            address(socialImpl),
            abi.encodeCall(LksSocialModule.initialize, (address(core), address(identity), admin))
        );
        social = LksSocialModule(payable(address(socialProxy)));

        // Grant SOCIAL_WRITER to social module
        vm.startPrank(admin);
        core.grantRole(core.SOCIAL_WRITER(), address(social));
        // Setup PREMIUM tier for tier-gating tests
        core.setTierConfig(
            ILksCore.AccessTier.PREMIUM,
            ILksCore.TierConfig({
                monthlyPrice: TIER_PREMIUM_PRICE,
                reputationBonus: 500,
                active: true
            })
        );
        vm.stopPrank();

        // Mint identities
        identity.mintTo(alice);
        identity.mintTo(bob);
        identity.mintTo(charlie);
        // dave has no identity

        // Fund
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(charlie, 10 ether);
        vm.deal(dave, 10 ether);
    }

    // ============================================================================
    // INITIALIZATION
    // ============================================================================

    function test_Init_setsDependencies() public {
        assertEq(address(social.coreContract()), address(core));
        assertEq(address(social.identityContract()), address(identity));
    }

    function test_Init_grantsRoles() public {
        assertTrue(social.hasRole(social.ADMIN_ROLE(), admin));
        assertTrue(social.hasRole(social.PAUSER_ROLE(), admin));
        assertTrue(social.hasRole(social.UPGRADER_ROLE(), admin));
    }

    function test_Init_hasSocialWriterRoleOnCore() public {
        assertTrue(core.hasRole(core.SOCIAL_WRITER(), address(social)));
    }

    function test_Init_revertIfZeroCore() public {
        LksSocialModule impl = new LksSocialModule();
        vm.expectRevert(LksSocialModule.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(LksSocialModule.initialize, (address(0), address(identity), admin))
        );
    }

    // ============================================================================
    // POSTS
    // ============================================================================

    function test_CreatePost_success() public {
        vm.prank(alice);
        uint256 postId = social.createPost(bytes32("post1"), bytes32("media1"));
        assertEq(postId, 1);

        LksSocialModule.Post memory p = social.getPost(postId);
        assertEq(p.author, alice);
        assertEq(p.contentHash, bytes32("post1"));
        assertEq(p.likes, 0);
    }

    function test_CreatePost_incrementsUserStats() public {
        vm.prank(alice);
        social.createPost(bytes32("post1"), bytes32(0));
        LksSocialModule.UserStats memory s = social.getUserStats(alice);
        assertEq(s.posts, 1);
    }

    function test_CreatePost_writesReputationToCore() public {
        assertEq(core.getReputation(alice), 0);

        vm.prank(alice);
        social.createPost(bytes32("post1"), bytes32(0));

        // Default reputationPerPost = 2
        assertEq(core.getReputation(alice), 2);
    }

    function test_CreatePost_revertIfNoIdentity() public {
        vm.prank(dave);
        vm.expectRevert(LksSocialModule.IdentityRequired.selector);
        social.createPost(bytes32("post1"), bytes32(0));
    }

    function test_CreatePost_revertIfDuplicateHash() public {
        vm.prank(alice);
        social.createPost(bytes32("post1"), bytes32(0));

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(LksSocialModule.ContentHashAlreadyUsed.selector, bytes32("post1"))
        );
        social.createPost(bytes32("post1"), bytes32(0));
    }

    function test_CreatePost_revertIfTooSoon() public {
        vm.prank(alice);
        social.createPost(bytes32("post1"), bytes32(0));

        vm.prank(alice);
        vm.expectRevert();
        social.createPost(bytes32("post2"), bytes32(0));
    }

    function test_CreatePost_multipleAfterInterval() public {
        vm.prank(alice);
        social.createPost(bytes32("post1"), bytes32(0));
        vm.warp(block.timestamp + 11 seconds);
        vm.prank(alice);
        social.createPost(bytes32("post2"), bytes32(0));
    }

    // ============================================================================
    // LIKES
    // ============================================================================

    function test_LikePost_incrementsLikes() public {
        vm.prank(alice);
        uint256 pid = social.createPost(bytes32("post1"), bytes32(0));

        vm.prank(bob);
        social.likePost(pid);

        LksSocialModule.Post memory p = social.getPost(pid);
        assertEq(p.likes, 1);
        assertTrue(social.hasLiked(pid, bob));
    }

    function test_LikePost_addsReputationToAuthor() public {
        vm.prank(alice);
        uint256 pid = social.createPost(bytes32("post1"), bytes32(0));
        uint256 repBefore = core.getReputation(alice);

        vm.prank(bob);
        social.likePost(pid);

        // Alice gets reputationPerLike (default 1)
        assertEq(core.getReputation(alice), repBefore + 1);
    }

    function test_LikePost_revertIfAlreadyLiked() public {
        vm.prank(alice);
        uint256 pid = social.createPost(bytes32("p1"), bytes32(0));

        vm.prank(bob);
        social.likePost(pid);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LksSocialModule.AlreadyLiked.selector, pid));
        social.likePost(pid);
    }

    function test_UnlikePost_decrements() public {
        vm.prank(alice);
        uint256 pid = social.createPost(bytes32("p1"), bytes32(0));
        vm.prank(bob);
        social.likePost(pid);

        vm.prank(bob);
        social.unlikePost(pid);

        LksSocialModule.Post memory p = social.getPost(pid);
        assertEq(p.likes, 0);
    }

    // ============================================================================
    // TIPS — PULL PATTERN (LKS-SOC-01/02 FIX)
    // ============================================================================

    function test_TipPost_storesInTipsOwed() public {
        vm.prank(alice);
        uint256 pid = social.createPost(bytes32("p1"), bytes32(0));

        vm.prank(bob);
        social.tipPost{value: 0.01 ether}(pid);

        // Alice doesn't get eth directly → stored in tipsOwed
        // platformFee = 0.01 * 100 / 10000 = 0.0001
        // authorAmount = 0.0099
        assertEq(social.tipsOwed(alice), 0.0099 ether);
        assertEq(social.accumulatedPlatformFees(), 0.0001 ether);
        assertEq(address(social).balance, 0.01 ether); // held in contract
    }

    function test_TipPost_zeroBalanceChange_onAuthor() public {
        vm.prank(alice);
        uint256 pid = social.createPost(bytes32("p1"), bytes32(0));

        uint256 aliceBalBefore = alice.balance;
        vm.prank(bob);
        social.tipPost{value: 0.01 ether}(pid);

        // Pull pattern : alice balance unchanged
        assertEq(alice.balance, aliceBalBefore);
    }

    function test_WithdrawTips_authorReceives() public {
        vm.prank(alice);
        uint256 pid = social.createPost(bytes32("p1"), bytes32(0));
        vm.prank(bob);
        social.tipPost{value: 0.01 ether}(pid);

        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        social.withdrawTips();

        assertEq(alice.balance - aliceBalBefore, 0.0099 ether);
        assertEq(social.tipsOwed(alice), 0);
    }

    function test_WithdrawTips_revertIfNothing() public {
        vm.prank(alice);
        vm.expectRevert(LksSocialModule.NothingToWithdraw.selector);
        social.withdrawTips();
    }

    function test_TipPost_revertIfSelfTip() public {
        vm.prank(alice);
        uint256 pid = social.createPost(bytes32("p1"), bytes32(0));

        vm.prank(alice);
        vm.expectRevert(LksSocialModule.CannotTipSelf.selector);
        social.tipPost{value: 0.001 ether}(pid);
    }

    function test_TipPost_revertIfBelowMin() public {
        vm.prank(alice);
        uint256 pid = social.createPost(bytes32("p1"), bytes32(0));

        vm.prank(bob);
        vm.expectRevert();
        social.tipPost{value: 0.00001 ether}(pid);
    }

    function test_TipPost_freeTierDailyLimit() public {
        // Bob has identity but no premium subscription → free tier, limited to 5 tips/day
        vm.prank(alice);
        uint256 pid = social.createPost(bytes32("p1"), bytes32(0));

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(bob);
            social.tipPost{value: 0.001 ether}(pid);
        }

        // 6th tip fails
        vm.prank(bob);
        vm.expectRevert();
        social.tipPost{value: 0.001 ether}(pid);
    }

    function test_TipPost_premiumTierNoLimit() public {
        // Bob subscribes to PREMIUM tier in Core
        vm.prank(bob);
        core.subscribe{value: TIER_PREMIUM_PRICE}(ILksCore.AccessTier.PREMIUM);

        vm.prank(alice);
        uint256 pid = social.createPost(bytes32("p1"), bytes32(0));

        // Do 10 tips — should all succeed
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(bob);
            social.tipPost{value: 0.001 ether}(pid);
        }
        assertEq(social.getUserStats(alice).tipsReceived, 10);
    }

    function test_IsPremium_returnsFalseForFreeTier() public {
        assertFalse(social.isPremium(bob));
    }

    function test_IsPremium_returnsTrueForPremium() public {
        vm.prank(bob);
        core.subscribe{value: TIER_PREMIUM_PRICE}(ILksCore.AccessTier.PREMIUM);
        assertTrue(social.isPremium(bob));
    }

    function test_IsPremium_BASIC_notPremium() public {
        vm.prank(admin);
        core.setTierConfig(
            ILksCore.AccessTier.BASIC,
            ILksCore.TierConfig({monthlyPrice: 0.01 ether, reputationBonus: 0, active: true})
        );
        vm.prank(bob);
        core.subscribe{value: 0.01 ether}(ILksCore.AccessTier.BASIC);

        // BASIC is NOT premium (LKS-SOC-04 fix)
        assertFalse(social.isPremium(bob));
    }

    // ============================================================================
    // PLATFORM FEES
    // ============================================================================

    function test_WithdrawPlatformFees_recipientReceives() public {
        vm.prank(alice);
        uint256 pid = social.createPost(bytes32("p1"), bytes32(0));
        vm.prank(bob);
        social.tipPost{value: 0.01 ether}(pid);

        assertEq(social.accumulatedPlatformFees(), 0.0001 ether);

        uint256 adminBefore = admin.balance;
        vm.prank(admin);
        social.withdrawPlatformFees();

        assertEq(admin.balance - adminBefore, 0.0001 ether);
        assertEq(social.accumulatedPlatformFees(), 0);
    }

    function test_WithdrawPlatformFees_revertIfNotRecipient() public {
        vm.prank(alice);
        vm.expectRevert(LksSocialModule.TransferFailed.selector);
        social.withdrawPlatformFees();
    }

    // ============================================================================
    // FOLLOWS
    // ============================================================================

    function test_Follow_simple() public {
        vm.prank(alice);
        social.follow(bob);

        assertTrue(social.isFollowing(alice, bob));
        assertEq(social.getFollowersCount(bob), 1);
        assertEq(social.getFollowingCount(alice), 1);
    }

    function test_Follow_addsReputationToFollowed() public {
        uint256 bobRepBefore = core.getReputation(bob);
        vm.prank(alice);
        social.follow(bob);
        // reputationPerFollow = 5
        assertEq(core.getReputation(bob), bobRepBefore + 5);
    }

    function test_Follow_revertSelfFollow() public {
        vm.prank(alice);
        vm.expectRevert(LksSocialModule.CannotFollowSelf.selector);
        social.follow(alice);
    }

    function test_Follow_revertIfAlreadyFollowing() public {
        vm.prank(alice);
        social.follow(bob);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LksSocialModule.AlreadyFollowing.selector, bob));
        social.follow(bob);
    }

    function test_Unfollow_success() public {
        vm.prank(alice);
        social.follow(bob);

        vm.prank(alice);
        social.unfollow(bob);

        assertFalse(social.isFollowing(alice, bob));
        assertEq(social.getFollowersCount(bob), 0);
    }

    function test_Unfollow_revertIfNotFollowing() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LksSocialModule.NotFollowing.selector, bob));
        social.unfollow(bob);
    }

    // ============================================================================
    // BATCH FOLLOW — NEW
    // ============================================================================

    function test_BatchFollow_success() public {
        address[] memory users = new address[](2);
        users[0] = bob;
        users[1] = charlie;

        vm.prank(alice);
        (uint256 successCount, uint256 skippedCount) = social.batchFollow(users);
        assertEq(successCount, 2);
        assertEq(skippedCount, 0);

        assertTrue(social.isFollowing(alice, bob));
        assertTrue(social.isFollowing(alice, charlie));
        assertEq(social.getFollowingCount(alice), 2);
    }

    function test_BatchFollow_skipsDuplicates() public {
        // Pre-follow bob
        vm.prank(alice);
        social.follow(bob);

        address[] memory users = new address[](3);
        users[0] = bob;      // Already followed — skip
        users[1] = charlie;  // OK
        users[2] = alice;    // Self — skip

        vm.prank(alice);
        (uint256 successCount, uint256 skippedCount) = social.batchFollow(users);
        assertEq(successCount, 1);
        assertEq(skippedCount, 2);
    }

    function test_BatchFollow_skipsZeroAddress() public {
        address[] memory users = new address[](2);
        users[0] = address(0);
        users[1] = bob;

        vm.prank(alice);
        (uint256 successCount, uint256 skippedCount) = social.batchFollow(users);
        assertEq(successCount, 1);
        assertEq(skippedCount, 1);
    }

    function test_BatchFollow_revertIfTooLarge() public {
        address[] memory users = new address[](51); // > MAX_BATCH_FOLLOW (50)

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LksSocialModule.BatchTooLarge.selector, uint256(51), uint256(50)));
        social.batchFollow(users);
    }

    function test_BatchFollow_emptyArray_returnsZero() public {
        address[] memory empty = new address[](0);
        vm.prank(alice);
        (uint256 s, uint256 k) = social.batchFollow(empty);
        assertEq(s, 0);
        assertEq(k, 0);
    }

    function test_BatchFollow_writesReputationToAllFollowed() public {
        address[] memory users = new address[](3);
        users[0] = bob;
        users[1] = charlie;
        users[2] = dave; // dave has no identity but follow writing still works (reputation target)

        vm.prank(alice);
        social.batchFollow(users);

        // Each gets reputationPerFollow = 5
        assertEq(core.getReputation(bob), 5);
        assertEq(core.getReputation(charlie), 5);
        assertEq(core.getReputation(dave), 5);
    }

    // ============================================================================
    // PAGINATION
    // ============================================================================

    function test_GetUserPosts_pagination() public {
        vm.prank(admin);
        social.setMinPostInterval(0);

        vm.startPrank(alice);
        social.createPost(bytes32("p1"), bytes32(0));
        social.createPost(bytes32("p2"), bytes32(0));
        social.createPost(bytes32("p3"), bytes32(0));
        vm.stopPrank();

        LksSocialModule.Post[] memory postsList = social.getUserPosts(alice, 0, 10);
        assertEq(postsList.length, 3);
        // Most recent first
        assertEq(postsList[0].contentHash, bytes32("p3"));
        assertEq(postsList[2].contentHash, bytes32("p1"));
    }

    // ============================================================================
    // ADMIN
    // ============================================================================

    function test_SetPlatformFeeRate_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        social.setPlatformFeeRate(200);
    }

    function test_SetPlatformFeeRate_updates() public {
        vm.prank(admin);
        social.setPlatformFeeRate(200);
        assertEq(social.platformFeeRate(), 200);
    }

    function test_SetPlatformFeeRate_revertIfTooHigh() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LksSocialModule.FeeRateTooHigh.selector, 1001, 1000));
        social.setPlatformFeeRate(1001);
    }

    function test_Pause_blocksCreatePost() public {
        vm.prank(admin);
        social.pause();

        vm.prank(alice);
        vm.expectRevert();
        social.createPost(bytes32("p1"), bytes32(0));
    }

    function test_Pause_allowsWithdrawTips() public {
        vm.prank(alice);
        uint256 pid = social.createPost(bytes32("p1"), bytes32(0));
        vm.prank(bob);
        social.tipPost{value: 0.001 ether}(pid);

        vm.prank(admin);
        social.pause();

        vm.prank(alice);
        social.withdrawTips(); // should NOT revert
    }

    function test_SetReputationRates_updates() public {
        vm.prank(admin);
        social.setReputationRates(20, 10, 5, 2);

        assertEq(social.reputationPerTip(), 20);
        assertEq(social.reputationPerFollow(), 10);
        assertEq(social.reputationPerPost(), 5);
        assertEq(social.reputationPerLike(), 2);
    }
}
