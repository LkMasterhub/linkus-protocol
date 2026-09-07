# Gouvernance Multisig LinkUs Protocol

## Vue d'ensemble

Configuration multisig personnelle pour le développement solo avec plusieurs wallets.
Permet la gouvernance sécurisée des upgrades de contrats pendant la phase de développement.

## Architecture

### LksPersonalMultisig
- **Propriétaires** : 5 wallets personnels
- **Seuil critique** : 3/5 (contrats core et changements majeurs)
- **Seuil business** : 2/5 (opérations routinières)

### Types d'opérations
```solidity
enum OperationType { BUSINESS, CRITICAL }

BUSINESS:  Projets, Social, autres contrats métier
CRITICAL:  Core, Access, changements de gouvernance
```

## Utilisation

### 1. Déploiement
```bash
# Configurer vos wallets dans .env.local
export PRIVATE_KEY="0x..."
export RPC_URL="http://localhost:8545"

# Déployer multisig
./scripts/deploy-personal-multisig.sh
```

### 2. Configuration Upgrades
```bash
# Après déploiement des contrats upgradeables
export MULTISIG_ADDRESS="0x..."
export LKS_CORE_PROXY="0x..."
export LKS_ACCESS_PROXY="0x..."

# Transférer permissions d'upgrade
./scripts/configure-multisig-upgrades.sh
```

### 3. Proposer Upgrade
```solidity
// 1. Déployer nouvelle implémentation
LksCoreV2 newImpl = new LksCoreV2();

// 2. Encoder données d'upgrade
bytes memory upgradeData = abi.encodeWithSelector(
    UUPSUpgradeable.upgradeToAndCall.selector,
    address(newImpl),
    ""
);

// 3. Soumettre transaction multisig
multisig.submitTransaction(
    address(lksCoreProxy),
    0,
    upgradeData,
    LksPersonalMultisig.OperationType.CRITICAL
);
```

### 4. Confirmer et Exécuter
```javascript
// Confirmer avec 3 wallets différents
await multisig.connect(wallet1).confirmTransaction(txId);
await multisig.connect(wallet2).confirmTransaction(txId);
await multisig.connect(wallet3).confirmTransaction(txId);
// Auto-execution après 3ème confirmation
```

## Sécurité

### Protection Double
- **Multisig** : Empêche les actions non autorisées
- **UUPS** : Logique d'upgrade dans l'implémentation

### Rotation des Clés
```solidity
// Ajouter nouveau propriétaire (future feature)
// Retirer ancien propriétaire
// Changer seuils si nécessaire
```

### Timelock (Future)
```solidity
// Délai de 48h pour upgrades critiques
// Annulation possible pendant délai
```

## Workflows

### Upgrade Standard
1. Développer nouvelle version
2. Tests exhaustifs
3. Déployer implémentation
4. Soumettre proposition multisig
5. Confirmer avec seuil requis
6. Vérification post-upgrade

### Upgrade d'Urgence
1. Identifier problème critique
2. Développer correctif minimal
3. Tests de sécurité
4. Deployment express
5. Multisig express (3/5)
6. Monitoring renforcé

## Monitoring

### Events à Surveiller
```solidity
TransactionSubmitted(txId, to, value, opType)
TransactionConfirmed(txId, owner)
TransactionExecuted(txId)
ProtocolUpgraded(newImplementation, version)
```

### Dashboard
- Transactions en attente
- Confirmations par wallet
- Historique des upgrades
- Santé des contrats

Cette configuration permet une gouvernance sécurisée pendant le développement solo tout en préparant la transition vers une gouvernance communautaire future.