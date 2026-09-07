// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../src/token/LKSTUpgradeable.sol";
import "../src/token/LKSVUpgradeable.sol";
import "../src/token/LKSVUpgradeableV2.sol";
import "../src/token/LKSVUpgradeableV3.sol";
import "../src/token/LKSVUpgradeableV4.sol";

/// @dev Mock minimal — n'implémente que getReputation(address), suffisant pour
///      satisfaire l'appel `ILksCore(lksCore).getReputation(account)` de V4.
contract MockLksCore {
    mapping(address => uint256) public reputation;
    bool public shouldRevert;

    function setReputation(address user, uint256 rep) external {
        reputation[user] = rep;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function getReputation(address user) external view returns (uint256) {
        if (shouldRevert) revert("mock: core down");
        return reputation[user];
    }
}

contract LKSVUpgradeableV4Test is Test {
    LKSTUpgradeable public lkst;
    LKSVUpgradeableV4 public lksv;
    MockLksCore public core;

    address public admin = address(0xA11CE);
    address public alice = address(0x1111);
    address public bob = address(0x2222);

    uint256 constant STAKE_AMOUNT = 1000 ether;
    uint256 constant REWARD_RATE = 1e15; // 0.001 LKST/s

    function setUp() public {
        LKSTUpgradeable lkstImpl = new LKSTUpgradeable();
        vm.prank(admin);
        ERC1967Proxy lkstProxy = new ERC1967Proxy(
            address(lkstImpl),
            abi.encodeCall(LKSTUpgradeable.initialize, (admin))
        );
        lkst = LKSTUpgradeable(address(lkstProxy));

        core = new MockLksCore();

        LKSVUpgradeableV4 lksvImpl = new LKSVUpgradeableV4();
        vm.prank(admin);
        ERC1967Proxy lksvProxy = new ERC1967Proxy(
            address(lksvImpl),
            abi.encodeCall(LKSVUpgradeable.initialize, (IERC20(address(lkst)), admin))
        );
        lksv = LKSVUpgradeableV4(address(lksvProxy));

        vm.startPrank(admin);
        lksv.initializeV4(address(core));
        lkst.transfer(alice, STAKE_AMOUNT * 10);
        lkst.transfer(bob, STAKE_AMOUNT * 10);
        lkst.approve(address(lksv), type(uint256).max);
        lksv.fundRewards(1_000_000 ether);
        vm.stopPrank();
    }

    // ============================================================================
    // BASICS
    // ============================================================================

    function test_V4_versionString() public {
        assertEq(lksv.version(), "4.0.0");
    }

    function test_V4_defaultTiers() public {
        (uint256 min0, uint256 mult0) = lksv.participationTiers(0);
        (uint256 min1, uint256 mult1) = lksv.participationTiers(1);
        (uint256 min2, uint256 mult2) = lksv.participationTiers(2);
        (uint256 min3, uint256 mult3) = lksv.participationTiers(3);

        assertEq(min0, 0);
        assertEq(mult0, 10_000);
        assertEq(min1, 100);
        assertEq(mult1, 12_000);
        assertEq(min2, 500);
        assertEq(mult2, 14_500);
        assertEq(min3, 2000);
        assertEq(mult3, 20_000);
    }

    function test_V4_currentMultiplier_perTier() public {
        core.setReputation(alice, 0);
        assertEq(lksv.currentMultiplier(alice), 10_000);

        core.setReputation(alice, 100);
        assertEq(lksv.currentMultiplier(alice), 12_000);

        core.setReputation(alice, 499);
        assertEq(lksv.currentMultiplier(alice), 12_000);

        core.setReputation(alice, 500);
        assertEq(lksv.currentMultiplier(alice), 14_500);

        core.setReputation(alice, 999_999);
        assertEq(lksv.currentMultiplier(alice), 20_000);
    }

    /// @notice Un LksCore qui revert ne doit jamais bloquer le staking — fallback 1x.
    function test_V4_currentMultiplier_failSafeOnCoreRevert() public {
        core.setShouldRevert(true);
        assertEq(lksv.currentMultiplier(alice), 10_000);

        // Le staking doit rester fonctionnel même core cassé.
        vm.startPrank(alice);
        lkst.approve(address(lksv), STAKE_AMOUNT);
        lksv.deposit(STAKE_AMOUNT, alice);
        vm.stopPrank();

        assertGt(lksv.balanceOf(alice), 0);
    }

    function test_V4_currentMultiplier_zeroCoreAddress() public {
        vm.prank(admin);
        LKSVUpgradeableV4 fresh = LKSVUpgradeableV4(
            address(new ERC1967Proxy(
                address(new LKSVUpgradeableV4()),
                abi.encodeCall(LKSVUpgradeable.initialize, (IERC20(address(lkst)), admin))
            ))
        );
        // Pas d'initializeV4 appelé -> lksCore == address(0)
        assertEq(fresh.currentMultiplier(alice), 10_000);
    }

    // ============================================================================
    // WEIGHTED DISTRIBUTION
    // ============================================================================

    /// @notice Deux stakers à parts égales mais paliers de réputation différents
    ///         doivent se partager les rewards exactement au prorata du multiplicateur.
    function test_V4_weightedDistributionMatchesTierRatio() public {
        core.setReputation(alice, 0);     // 1x
        core.setReputation(bob, 2000);    // 2x

        vm.startPrank(alice);
        lkst.approve(address(lksv), STAKE_AMOUNT);
        lksv.deposit(STAKE_AMOUNT, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        lkst.approve(address(lksv), STAKE_AMOUNT);
        lksv.deposit(STAKE_AMOUNT, bob);
        vm.stopPrank();

        vm.prank(admin);
        lksv.setRewardRate(REWARD_RATE);

        skip(1 days);

        uint256 earnedAlice = lksv.earned(alice);
        uint256 earnedBob = lksv.earned(bob);

        assertGt(earnedAlice, 0);
        // bob doit toucher ~2x ce que touche alice (2x/1x)
        assertApproxEqRel(earnedBob, earnedAlice * 2, 0.01e18);
    }

    /// @notice syncWeight doit geler les rewards avec l'ANCIEN poids avant de rafraîchir —
    ///         un tiers ne peut pas voler de rewards déjà accumulées en syncant quelqu'un d'autre.
    function test_V4_syncWeight_isPermissionlessButSafe() public {
        core.setReputation(alice, 0); // 1x

        vm.startPrank(alice);
        lkst.approve(address(lksv), STAKE_AMOUNT);
        lksv.deposit(STAKE_AMOUNT, alice);
        vm.stopPrank();

        vm.prank(admin);
        lksv.setRewardRate(REWARD_RATE);

        skip(1 days);
        uint256 earnedBefore = lksv.earned(alice);
        assertGt(earnedBefore, 0);

        // alice monte de palier ; bob (tiers non lié) déclenche le sync pour elle.
        core.setReputation(alice, 2000); // 2x
        vm.prank(bob);
        lksv.syncWeight(alice);

        // Les rewards déjà accumulées avant le sync ne doivent pas disparaître.
        assertGe(lksv.earned(alice), earnedBefore);
    }

    // ============================================================================
    // RÉGRESSION — double-dip via transfer sLKST (trouvé en revue adversariale)
    // ============================================================================

    /// @notice Une version antérieure ne syncait le poids que sur deposit/mint/
    ///         withdraw/redeem. Un staker pouvait accumuler des rewards, transférer
    ///         TOUTES ses parts sLKST à un tiers via le `transfer()` ERC20 standard
    ///         (sans jamais rappeler withdraw/redeem), puis continuer à `claimRewards()`
    ///         indéfiniment sur son `weightedBalance` resté périmé — double-dip direct
    ///         sur `rewardReserve`, alors qu'il ne détient plus aucune part réelle.
    ///         Fixé par l'override de `_update` qui resync from/to sur CHAQUE transfer.
    function test_Regression_TransferDoesNotLeaveStaleWeightForDoubleDip() public {
        core.setReputation(alice, 0); // 1x

        vm.startPrank(alice);
        lkst.approve(address(lksv), STAKE_AMOUNT);
        lksv.deposit(STAKE_AMOUNT, alice);
        vm.stopPrank();

        vm.prank(admin);
        lksv.setRewardRate(REWARD_RATE);

        skip(1 days);

        uint256 earnedBeforeTransfer = lksv.earned(alice);
        assertGt(earnedBeforeTransfer, 0);

        // Alice claim ses rewards accumulées légitimement...
        vm.prank(alice);
        lksv.claimRewards();
        uint256 reserveAfterClaim = lksv.rewardReserve();

        // ...puis donne TOUTES ses parts sLKST à Bob via un transfer() ERC20 brut,
        // sans jamais repasser par withdraw/redeem.
        uint256 aliceShares = lksv.balanceOf(alice);
        vm.prank(alice);
        lksv.transfer(bob, aliceShares);

        assertEq(lksv.balanceOf(alice), 0);
        // Le poids pondéré d'Alice doit tomber à zéro immédiatement au transfer.
        assertEq(lksv.weightedBalance(alice), 0);
        // Et celui de Bob doit refléter les parts qu'il vient de recevoir.
        assertEq(lksv.weightedBalance(bob), aliceShares); // multiplier 1x pour bob aussi

        skip(1 days);

        // Alice ne détient plus rien : elle ne doit plus RIEN pouvoir claim, quel que
        // soit le temps qui passe, même si elle rappelle claimRewards().
        assertEq(lksv.earned(alice), 0);
        vm.prank(alice);
        lksv.claimRewards(); // no-op, ne doit rien transférer
        assertEq(lksv.rewardReserve(), reserveAfterClaim);

        // Bob, désormais le vrai détenteur, doit accumuler des rewards normalement.
        assertGt(lksv.earned(bob), 0);
    }

    // ============================================================================
    // MIGRATION / RÉGRESSION "FIRST-SYNC SCOOP"
    // ============================================================================

    /// @notice Si le rewardRate est laissé actif pendant qu'un dénominateur pondéré
    ///         encore vide (totalWeightedShares == 0) traverse une période sans sync,
    ///         cette période ne doit PAS s'accumuler en backlog récupérable par le
    ///         premier compte syncé. C'est l'invariant qui évite la reprise du bug
    ///         historique de fuite de distribution sous une autre forme.
    function test_Migration_NoBacklogLeak() public {
        core.setReputation(alice, 0);
        core.setReputation(bob, 0);

        // Les deux stakers déposent AVANT toute synchro de poids (simule des stakers
        // pré-existants d'une version antérieure sans notion de poids).
        vm.startPrank(alice);
        lkst.approve(address(lksv), STAKE_AMOUNT);
        lksv.deposit(STAKE_AMOUNT, alice);
        vm.stopPrank();
        // deposit() sync automatiquement alice -> on doit repartir de zéro pour le test :
        // simuler l'état "juste après upgrade" en remettant son poids à zéro manuellement
        // n'est pas possible depuis l'extérieur (pas de setter), donc on vérifie plutôt
        // l'invariant directement au niveau du dénominateur : tant qu'il est nul, aucune
        // reward ne doit s'accumuler, point.
        vm.stopPrank();

        vm.prank(admin);
        lksv.setRewardRate(REWARD_RATE);

        uint256 storedBefore = lksv.rewardPerTokenStored();

        // totalWeightedShares > 0 ici car deposit() a syncé alice — donc pour tester
        // le cas totalWeightedShares == 0, on retire alice entièrement.
        vm.startPrank(alice);
        lksv.redeem(lksv.balanceOf(alice), alice, alice);
        vm.stopPrank();

        assertEq(lksv.totalWeightedShares(), 0);

        // Le temps passe alors que plus personne n'est pondéré (mais rewardRate > 0,
        // scénario du "mauvais séquencement" explicitement documenté dans initializeV4).
        skip(30 days);

        // Invariant : rewardPerToken() ne doit PAS avoir avancé pendant ce vide.
        assertEq(lksv.rewardPerToken(), storedBefore);

        // bob revient (premier à syncer après le trou) : il ne doit récupérer AUCUN
        // backlog des 30 jours "perdus" — seulement ce qui s'accumule à partir de
        // maintenant.
        vm.startPrank(bob);
        lkst.approve(address(lksv), STAKE_AMOUNT);
        lksv.deposit(STAKE_AMOUNT, bob);
        vm.stopPrank();

        assertEq(lksv.earned(bob), 0);

        skip(1 hours);
        uint256 expected = 1 hours * REWARD_RATE;
        assertApproxEqRel(lksv.earned(bob), expected, 0.01e18);
    }

    /// @notice Séquence de migration recommandée : rate à 0, syncWeightBatch, puis
    ///         réactivation — vérifie qu'elle ne produit aucune distorsion.
    function test_Migration_RecommendedSequenceIsFair() public {
        core.setReputation(alice, 0);    // 1x
        core.setReputation(bob, 2000);   // 2x

        // rewardRate reste à 0 pendant toute la phase de dépôt + sync.
        vm.startPrank(alice);
        lkst.approve(address(lksv), STAKE_AMOUNT);
        lksv.deposit(STAKE_AMOUNT, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        lkst.approve(address(lksv), STAKE_AMOUNT);
        lksv.deposit(STAKE_AMOUNT, bob);
        vm.stopPrank();

        assertEq(lksv.rewardRate(), 0);
        assertEq(lksv.earned(alice), 0);
        assertEq(lksv.earned(bob), 0);

        vm.prank(admin);
        lksv.setRewardRate(REWARD_RATE);

        skip(1 days);

        assertApproxEqRel(lksv.earned(bob), lksv.earned(alice) * 2, 0.01e18);
    }

    /// @notice initializeV4 doit refuser d'être appelé si rewardRate != 0 — défense
    ///         en profondeur contre une migration mal séquencée (voir NatSpec initializeV4).
    function test_Migration_InitializeV4RejectsNonZeroRewardRate() public {
        LKSVUpgradeableV3 v3Impl = new LKSVUpgradeableV3();
        vm.prank(admin);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(v3Impl),
            abi.encodeCall(LKSVUpgradeable.initialize, (IERC20(address(lkst)), admin))
        );
        LKSVUpgradeableV3 v3 = LKSVUpgradeableV3(address(proxy));

        vm.startPrank(admin);
        v3.setRewardRate(REWARD_RATE); // laissé actif par erreur avant l'upgrade

        LKSVUpgradeableV4 v4Impl = new LKSVUpgradeableV4();
        vm.expectRevert(LKSVUpgradeableV4.RewardRateMustBeZeroForMigration.selector);
        LKSVUpgradeableV4(address(proxy)).upgradeToAndCall(
            address(v4Impl),
            abi.encodeCall(LKSVUpgradeableV4.initializeV4, (address(core)))
        );
        vm.stopPrank();
    }

    /// @notice Simule le vrai chemin de migration : bob stake sous V3 (avant que
    ///         `weightedBalance` existe), le proxy est upgradé vers V4. Tant que
    ///         personne n'appelle `syncWeight(bob)`/`syncWeightBatch`, bob a
    ///         `balanceOf > 0` mais `weightedBalance == 0` — il ne gagne AUCUNE
    ///         reward, alors qu'alice, qui dépose APRÈS l'upgrade (donc synced
    ///         automatiquement par le hook `_update`), touche normalement. C'est le
    ///         manque-à-gagner résiduel documenté dans `initializeV4` : `syncWeightBatch`
    ///         reste une étape opérationnelle obligatoire post-upgrade, le hook
    ///         `_update` ne peut pas rattraper rétroactivement un solde déjà existant
    ///         avant que la variable `weightedBalance` n'existe. Un `syncWeight(bob)`
    ///         permissionless corrige la situation pour la suite (pas rétroactivement).
    function test_Migration_PreExistingStakerUnsyncedUntilExplicitSync() public {
        LKSVUpgradeableV3 v3Impl = new LKSVUpgradeableV3();
        vm.prank(admin);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(v3Impl),
            abi.encodeCall(LKSVUpgradeable.initialize, (IERC20(address(lkst)), admin))
        );
        LKSVUpgradeableV3 v3 = LKSVUpgradeableV3(address(proxy));

        vm.startPrank(admin);
        lkst.transfer(bob, STAKE_AMOUNT * 2);
        vm.stopPrank();

        vm.startPrank(bob);
        lkst.approve(address(proxy), type(uint256).max);
        v3.deposit(STAKE_AMOUNT, bob); // bob stake AVANT que V4/weightedBalance existe
        vm.stopPrank();

        // Upgrade V3 -> V4 en respectant la séquence documentée (rate=0 au moment de l'upgrade).
        LKSVUpgradeableV4 v4Impl = new LKSVUpgradeableV4();
        vm.prank(admin);
        LKSVUpgradeableV4(address(proxy)).upgradeToAndCall(
            address(v4Impl),
            abi.encodeCall(LKSVUpgradeableV4.initializeV4, (address(core)))
        );
        LKSVUpgradeableV4 v4 = LKSVUpgradeableV4(address(proxy));

        // bob existe toujours avec ses parts, mais n'a jamais été synced.
        assertGt(v4.balanceOf(bob), 0);
        assertEq(v4.weightedBalance(bob), 0);
        assertEq(v4.totalWeightedShares(), 0);

        // alice dépose APRÈS l'upgrade -> synced automatiquement par le hook _update.
        core.setReputation(alice, 0);
        vm.startPrank(admin);
        lkst.transfer(alice, STAKE_AMOUNT);
        vm.stopPrank();
        vm.startPrank(alice);
        lkst.approve(address(proxy), type(uint256).max);
        v4.deposit(STAKE_AMOUNT, alice);
        vm.stopPrank();

        vm.prank(admin);
        v4.setRewardRate(REWARD_RATE);
        skip(1 days);

        // bob : aucune reward tant qu'il n'a pas été synced, malgré un stake réel.
        assertEq(v4.earned(bob), 0);
        assertGt(v4.earned(alice), 0);

        // syncWeight corrige la situation pour la suite (pas de rattrapage rétroactif).
        v4.syncWeight(bob);
        assertEq(v4.earned(bob), 0); // toujours 0 : rien n'a été accumulé pour lui avant le sync
        skip(1 days);
        assertGt(v4.earned(bob), 0); // désormais il accumule normalement
    }

    // ============================================================================
    // ADMIN — setParticipationTiers validation
    // ============================================================================

    function test_V4_setParticipationTiers_onlyOwner() public {
        LKSVUpgradeableV4.ParticipationTier[4] memory tiers = _validTiers();
        vm.prank(alice);
        vm.expectRevert();
        lksv.setParticipationTiers(tiers);
    }

    function test_V4_setParticipationTiers_rejectsNonZeroFirstThreshold() public {
        LKSVUpgradeableV4.ParticipationTier[4] memory tiers = _validTiers();
        tiers[0].minReputation = 1;
        vm.prank(admin);
        vm.expectRevert(LKSVUpgradeableV4.InvalidTiers.selector);
        lksv.setParticipationTiers(tiers);
    }

    function test_V4_setParticipationTiers_rejectsNonIncreasingThresholds() public {
        LKSVUpgradeableV4.ParticipationTier[4] memory tiers = _validTiers();
        tiers[2].minReputation = tiers[1].minReputation; // pas strictement croissant
        vm.prank(admin);
        vm.expectRevert(LKSVUpgradeableV4.InvalidTiers.selector);
        lksv.setParticipationTiers(tiers);
    }

    function test_V4_setParticipationTiers_rejectsMultiplierOutOfBounds() public {
        LKSVUpgradeableV4.ParticipationTier[4] memory tiers = _validTiers();
        tiers[3].multiplierBps = lksv.MAX_MULTIPLIER_BPS() + 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LKSVUpgradeableV4.InvalidMultiplier.selector, tiers[3].multiplierBps));
        lksv.setParticipationTiers(tiers);
    }

    function test_V4_setParticipationTiers_rejectsDecreasingMultiplier() public {
        LKSVUpgradeableV4.ParticipationTier[4] memory tiers = _validTiers();
        tiers[2].multiplierBps = tiers[1].multiplierBps - 1;
        vm.prank(admin);
        vm.expectRevert(LKSVUpgradeableV4.InvalidTiers.selector);
        lksv.setParticipationTiers(tiers);
    }

    function _validTiers() internal pure returns (LKSVUpgradeableV4.ParticipationTier[4] memory tiers) {
        tiers[0] = LKSVUpgradeableV4.ParticipationTier({minReputation: 0, multiplierBps: 10_000});
        tiers[1] = LKSVUpgradeableV4.ParticipationTier({minReputation: 100, multiplierBps: 12_000});
        tiers[2] = LKSVUpgradeableV4.ParticipationTier({minReputation: 500, multiplierBps: 14_500});
        tiers[3] = LKSVUpgradeableV4.ParticipationTier({minReputation: 2000, multiplierBps: 20_000});
    }
}
