// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./LKSVUpgradeableV3.sol";
import "../core/ILksCore.sol";

/**
 * @title LKSVUpgradeableV4 - Rewards pondérées par participation (réputation)
 * @notice Ajoute un multiplicateur discret par palier de réputation sociale
 *         (lue depuis LksCore) au-dessus du fix d'unités de V3.
 *
 * Design :
 * - V3 a corrigé le mismatch d'unités (rewardPerToken() en assets vs earned() en
 *   shares) en alignant les deux sur `totalSupply()`/`balanceOf()` (shares).
 * - V4 reste dans ce même domaine d'unités "shares" mais pondère chaque compte par
 *   un multiplicateur de réputation : `weightedBalance = balanceOf * multiplier / BPS`.
 *   `totalWeightedShares` remplace `totalSupply()` comme dénominateur — c'est une
 *   généralisation du fix V3, pas une réintroduction du bug (tout reste en shares).
 * - Le poids pondéré d'un compte est resynchronisé automatiquement à CHAQUE
 *   changement de solde sLKST — via l'override de `_update` (ERC20 hook interne
 *   commun à mint/burn/transfer). C'est délibéré : sLKST est un ERC20 librement
 *   transférable (cf. NatSpec V1 "sLKST tradable"), donc un simple `transfer()`
 *   change `balanceOf` sans passer par `deposit`/`withdraw`. Une première version
 *   de ce contrat ne syncait le poids que sur deposit/mint/withdraw/redeem — un
 *   staker pouvait alors accumuler des rewards, transférer ses parts à un tiers,
 *   puis continuer à claim indéfiniment sur son `weightedBalance` resté périmé
 *   (double-dip direct sur `rewardReserve`, trouvé en revue avant tout déploiement).
 *   Le multiplicateur lui-même (dérivé de la réputation LksCore) n'est en revanche
 *   PAS poussé par LksCore — voir NatSpec de `syncWeight` pour ce tradeoff résiduel.
 *
 * ⚠️ Migration V3 → V4 : voir NatSpec de `initializeV4`. Un retrofit de dénominateur
 *    pondéré sur un vault qui a déjà des stakers a son propre risque de "leak" si mal
 *    séquencé (premier compte syncé après upgrade pourrait scooper un backlog de
 *    rewards non attribué) — voir test `test_Migration_NoBacklogLeak`.
 */
contract LKSVUpgradeableV4 is LKSVUpgradeableV3 {
    // ============================================================================
    // TYPES
    // ============================================================================

    struct ParticipationTier {
        uint256 minReputation;   // seuil inclusif de réputation cumulée (ILksCore.getReputation)
        uint256 multiplierBps;   // multiplicateur en bps (10_000 = 1x)
    }

    // ============================================================================
    // STATE (append-only après le storage de V1/V2/V3 — ne jamais réordonner)
    // ============================================================================

    /// @notice LksCore — source de vérité de la réputation sociale on-chain
    ILksCore public lksCore;

    /// @notice Somme des `weightedBalance` de tous les stakers connus (dénominateur reward)
    uint256 public totalWeightedShares;

    /// @notice Parts pondérées par compte (balanceOf * multiplier / BPS), rafraîchi au touch
    mapping(address => uint256) public weightedBalance;

    /// @notice 4 paliers de réputation, triés par minReputation croissant
    ParticipationTier[4] public participationTiers;

    // ============================================================================
    // CONSTANTS
    // ============================================================================

    uint256 public constant BPS = 10_000;

    /// @notice Plafond dur du multiplicateur (3x) pour borner l'impact d'une mauvaise config
    uint256 public constant MAX_MULTIPLIER_BPS = 30_000;

    // ============================================================================
    // EVENTS
    // ============================================================================

    event LksCoreUpdated(address indexed oldCore, address indexed newCore);
    event ParticipationTiersUpdated(ParticipationTier[4] tiers);
    event WeightSynced(address indexed account, uint256 oldWeighted, uint256 newWeighted, uint256 multiplierBps);

    // ============================================================================
    // ERRORS
    // ============================================================================

    error InvalidTiers();
    error InvalidMultiplier(uint256 bps);
    error RewardRateMustBeZeroForMigration();

    /// @notice Version du contrat
    function version() external pure override returns (string memory) {
        return "4.0.0";
    }

    // ============================================================================
    // INITIALIZER
    // ============================================================================

    /**
     * @notice Câble LksCore + seuils de paliers par défaut, à appeler via upgradeToAndCall.
     * @dev reinitializer(2) : V1 a consommé la version 1 via `initialize()`. V2/V3
     *      n'ajoutent pas d'état donc n'ont pas consommé de reinitializer. V4 est la
     *      2e migration d'état réelle.
     *
     *      ⚠️ SÉQUENCE DE MIGRATION OBLIGATOIRE (sinon risque de "first-sync scoop") :
     *      1. Avant l'upgrade, s'assurer que `rewardRate == 0` (timelock via `setRewardRate`).
     *         Cet init réinitialise `lastUpdateTime = block.timestamp` pour qu'aucun
     *         `rewardPerToken` ne s'accumule sur un dénominateur `totalWeightedShares`
     *         encore à 0 alors que des stakers existants ont déjà `balanceOf > 0`.
     *      2. Immédiatement après l'upgrade (rewardRate toujours à 0), appeler
     *         `syncWeightBatch()` pour TOUS les stakers connus (event `Staked`
     *         historique). Comme aucune reward n'est émise pendant cette étape, l'ordre
     *         dans lequel les comptes sont synced n'a aucun impact — personne ne peut
     *         scooper les rewards de quelqu'un d'autre.
     *      3. Une fois tous les stakers connus synced, le timelock réactive
     *         `setRewardRate(...)`.
     */
    function initializeV4(address _lksCore) public reinitializer(2) {
        if (_lksCore == address(0)) revert InvalidAddress();
        // Défense en profondeur : force l'opérateur à suivre la séquence documentée
        // ci-dessus plutôt que de compter uniquement sur la procédure hors-chaîne.
        if (rewardRate != 0) revert RewardRateMustBeZeroForMigration();
        lksCore = ILksCore(_lksCore);

        // Ancre le point de départ de l'accrual pondéré : aucun backlog n'est
        // attribuable rétroactivement à un dénominateur qui n'existait pas encore.
        lastUpdateTime = block.timestamp;

        participationTiers[0] = ParticipationTier({minReputation: 0,    multiplierBps: 10_000}); // 1x
        participationTiers[1] = ParticipationTier({minReputation: 100,  multiplierBps: 12_000}); // 1.2x
        participationTiers[2] = ParticipationTier({minReputation: 500,  multiplierBps: 14_500}); // 1.45x
        participationTiers[3] = ParticipationTier({minReputation: 2000, multiplierBps: 20_000}); // 2x

        emit LksCoreUpdated(address(0), _lksCore);
        emit ParticipationTiersUpdated(participationTiers);
    }

    // ============================================================================
    // WEIGHTED REWARD ACCOUNTING (overrides)
    // ============================================================================

    function rewardPerToken() public view override returns (uint256) {
        if (totalWeightedShares == 0) {
            return rewardPerTokenStored;
        }

        uint256 timeElapsed = block.timestamp - lastUpdateTime;
        uint256 newRewards = timeElapsed * rewardRate;

        return rewardPerTokenStored + (newRewards * PRECISION / totalWeightedShares);
    }

    function earned(address account) public view override returns (uint256) {
        uint256 rewardDelta = rewardPerToken() - userRewardPerTokenPaid[account];
        return (weightedBalance[account] * rewardDelta / PRECISION) + rewards[account];
    }

    // ============================================================================
    // ERC20 _update HOOK — seul point de synchronisation du poids pondéré.
    //
    // `_update(from, to, value)` est le hook interne commun à mint (from=0), burn
    // (to=0) ET transfer normal — il capture donc deposit/mint/withdraw/redeem
    // (qui appellent _mint/_burn) AUSSI BIEN QUE `transfer()`/`transferFrom()` bruts
    // sur sLKST. C'est volontairement le SEUL endroit qui gère le sync : ne pas
    // dupliquer d'appels à `_syncWeight` dans deposit/mint/withdraw/redeem (V1 les
    // fournit déjà, on ne les override plus ici) — un staker qui transfère ses
    // parts sans jamais rappeler deposit/withdraw doit voir son poids retomber à 0
    // immédiatement, sinon il peut continuer à `claimRewards()` sur un
    // `weightedBalance` périmé alors qu'il ne détient plus aucune part (double-dip
    // sur `rewardReserve` — c'est le bug que ce hook ferme).
    //
    // Ordre : geler les rewards de `from`/`to` avec leur ANCIEN poids d'abord (même
    // logique que le modifier `updateReward`), PUIS laisser le solde changer, PUIS
    // resynchroniser le poids sur le NOUVEAU solde.
    // ============================================================================

    function _update(address from, address to, uint256 value) internal override {
        _freezeReward(from);
        _freezeReward(to);

        super._update(from, to, value);

        _syncWeight(from);
        _syncWeight(to);
    }

    function _freezeReward(address account) internal {
        if (account == address(0)) return;
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;
        rewards[account] = earned(account);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
    }

    // ============================================================================
    // PARTICIPATION WEIGHT SYNC
    // ============================================================================

    /**
     * @notice Rafraîchit le poids pondéré d'un compte sur la réputation courante.
     * @dev Permissionless et appelable pour N'IMPORTE QUEL compte (pas seulement
     *      msg.sender) — c'est volontaire : la réputation évolue côté LksCore sans
     *      notifier le vault, donc un tiers (keeper, ou l'utilisateur lui-même) doit
     *      pouvoir forcer le refresh après un gain/perte de réputation, sinon le
     *      multiplicateur reste figé jusqu'au prochain deposit/withdraw. Gèle
     *      d'abord les rewards avec l'ANCIEN poids via `updateReward`, donc aucun
     *      utilisateur ne peut "voler" de rewards passées en syncant quelqu'un
     *      d'autre — au pire il force juste un refresh anticipé et légitime.
     */
    function syncWeight(address account) external updateReward(account) {
        _syncWeight(account);
    }

    /// @notice Batch de `syncWeight` — utilisé pour la migration post-upgrade (voir `initializeV4`).
    function syncWeightBatch(address[] calldata accounts) external {
        for (uint256 i = 0; i < accounts.length; i++) {
            _updateRewardAndSync(accounts[i]);
        }
    }

    function _updateRewardAndSync(address account) internal updateReward(account) {
        _syncWeight(account);
    }

    function _syncWeight(address account) internal {
        if (account == address(0)) return;

        uint256 oldWeighted = weightedBalance[account];
        uint256 newWeighted = _weightedOf(account);

        if (newWeighted == oldWeighted) return;

        totalWeightedShares = totalWeightedShares - oldWeighted + newWeighted;
        weightedBalance[account] = newWeighted;

        emit WeightSynced(account, oldWeighted, newWeighted, currentMultiplier(account));
    }

    function _weightedOf(address account) internal view returns (uint256) {
        uint256 shares = balanceOf(account);
        if (shares == 0) return 0;
        return shares * currentMultiplier(account) / BPS;
    }

    /**
     * @notice Multiplicateur courant (bps) d'un compte selon sa réputation LksCore.
     * @dev Fail-safe : un appel externe qui revert (LksCore mal wiré/en pause) ne doit
     *      jamais bloquer le staking — retombe sur 1x, jamais sur un revert.
     */
    function currentMultiplier(address account) public view returns (uint256) {
        if (address(lksCore) == address(0)) return BPS;

        try lksCore.getReputation(account) returns (uint256 rep) {
            uint256 mult = participationTiers[0].multiplierBps;
            for (uint256 i = 0; i < participationTiers.length; i++) {
                if (rep >= participationTiers[i].minReputation) {
                    mult = participationTiers[i].multiplierBps;
                }
            }
            return mult;
        } catch {
            return BPS;
        }
    }

    // ============================================================================
    // ADMIN
    // ============================================================================

    function setLksCore(address _lksCore) external onlyOwner {
        if (_lksCore == address(0)) revert InvalidAddress();
        emit LksCoreUpdated(address(lksCore), _lksCore);
        lksCore = ILksCore(_lksCore);
    }

    /// @notice Reconfigure les 4 paliers. Seuils strictement croissants, multiplicateurs
    ///         non décroissants et bornés à [1x, MAX_MULTIPLIER_BPS] pour éviter qu'une
    ///         mauvaise config draine la reserve de façon disproportionnée pour un tier.
    function setParticipationTiers(ParticipationTier[4] calldata tiers) external onlyOwner {
        if (tiers[0].minReputation != 0) revert InvalidTiers();

        for (uint256 i = 0; i < tiers.length; i++) {
            if (tiers[i].multiplierBps < BPS || tiers[i].multiplierBps > MAX_MULTIPLIER_BPS) {
                revert InvalidMultiplier(tiers[i].multiplierBps);
            }
            if (i > 0) {
                if (tiers[i].minReputation <= tiers[i - 1].minReputation) revert InvalidTiers();
                if (tiers[i].multiplierBps < tiers[i - 1].multiplierBps) revert InvalidTiers();
            }
            participationTiers[i] = tiers[i];
        }

        emit ParticipationTiersUpdated(participationTiers);
    }

    // ============================================================================
    // STORAGE GAP
    // ============================================================================

    uint256[45] private __gapV4;
}
