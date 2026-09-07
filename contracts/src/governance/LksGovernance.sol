// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "./ILKSTimelock.sol";

/**
 * @title LksGovernance
 * @notice Système de gouvernance décentralisée pour LinkUs Protocol
 * @dev Utilise LKST (ERC20Votes) pour voting power + LKSTimelock pour sécurité
 *
 * ARCHITECTURE:
 * - Propositions on-chain avec exécution via LKSTimelock
 * - Votes pondérés par LKST (1 LKST = 1 vote)
 * - Timelock 2 jours via contrat LKSTimelock dédié
 * - Quorum minimum requis pour validation
 * - Multi-sig guardian pour veto situations critiques
 *
 * FEATURES:
 * - Création propositions (texte + actions on-chain)
 * - Vote FOR/AGAINST/ABSTAIN
 * - Queue propositions → LKSTimelock.scheduleBatch()
 * - Exécution via LKSTimelock.executeBatch() après delay
 * - Delegation voting power (via LKST)
 * - Historique complet propositions
 *
 * SECURITY:
 * - LKSTimelock contrat dédié (2 jours delay minimum)
 * - Quorum 10% total supply LKST
 * - Guardians veto pour urgences
 * - Propositions costs 1000 LKST (anti-spam)
 * - Separation of concerns: Voting ≠ Execution
 */
contract LksGovernance is AccessControl, ReentrancyGuard, Pausable {

    // ========== TYPES ==========

    /// @notice États proposition
    enum ProposalState {
        PENDING,      // En attente de votes
        ACTIVE,       // Vote en cours
        CANCELED,     // Annulée par créateur/guardian
        DEFEATED,     // Rejetée (pas assez votes)
        SUCCEEDED,    // Approuvée (quorum atteint)
        QUEUED,       // En queue pour exécution (timelock)
        EXPIRED,      // Expirée sans exécution
        EXECUTED      // Exécutée
    }

    /// @notice Type de vote
    enum VoteType {
        AGAINST,
        FOR,
        ABSTAIN
    }

    /// @notice Action à exécuter
    struct ProposalAction {
        address target;       // Contract address
        uint256 value;        // ETH value
        bytes data;           // Calldata
        string description;   // Action description
    }

    /// @notice Proposition
    struct Proposal {
        uint256 id;
        address proposer;
        string title;
        string description;
        ProposalAction[] actions;
        uint256 startBlock;
        uint256 endBlock;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        ProposalState state;
        uint256 eta;          // Execution Time Arrival (après timelock)
        bytes32 timelockId;   // ID opération dans LKSTimelock
        bool executed;
        uint256 createdAt;
    }

    /// @notice Vote reçu
    struct Receipt {
        bool hasVoted;
        VoteType support;
        uint256 votes;        // Voting power au moment du vote
    }

    // ========== STORAGE ==========

    /// @notice LKST token (ERC20Votes)
    ERC20Votes public immutable lkstToken;

    /// @notice LKSTimelock contract
    ILKSTimelock public immutable timelock;

    /// @notice Roles
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Proposal counter
    uint256 private _nextProposalId = 1;

    /// @notice Propositions storage
    mapping(uint256 => Proposal) private proposals;

    /// @notice Votes reçus (proposalId => voter => Receipt)
    mapping(uint256 => mapping(address => Receipt)) public receipts;

    /// @notice Liste toutes propositions
    uint256[] public allProposalIds;

    /// @notice Propositions par user
    mapping(address => uint256[]) public userProposals;

    // Configuration
    uint256 public votingDelay = 1 days;        // Délai avant vote
    uint256 public votingPeriod = 5 days;       // Durée vote
    uint256 public timelockDelay = 2 days;      // Délai exécution
    uint256 public proposalThreshold = 1000 * 10**18;  // 1000 LKST pour proposer
    uint256 public quorumNumerator = 10;        // 10% du total supply

    /// @notice Total propositions
    uint256 public totalProposals;

    // ========== EVENTS ==========

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string title,
        uint256 startBlock,
        uint256 endBlock
    );

    event VoteCast(
        address indexed voter,
        uint256 indexed proposalId,
        VoteType support,
        uint256 votes,
        string reason
    );

    event ProposalQueued(
        uint256 indexed proposalId,
        uint256 eta
    );

    event ProposalExecuted(
        uint256 indexed proposalId
    );

    event ProposalCanceled(
        uint256 indexed proposalId
    );

    event VotingDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event VotingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event QuorumUpdated(uint256 oldQuorum, uint256 newQuorum);

    // ========== ERRORS ==========

    error InsufficientVotingPower(uint256 required, uint256 actual);
    error ProposalNotFound(uint256 proposalId);
    error ProposalNotActive(uint256 proposalId);
    error AlreadyVoted(uint256 proposalId);
    error ProposalNotSucceeded(uint256 proposalId);
    error TimelockNotReached(uint256 proposalId, uint256 eta);
    error ProposalAlreadyExecuted(uint256 proposalId);
    error ExecutionFailed(uint256 actionIndex);
    error InvalidProposalState(uint256 proposalId, ProposalState current);
    error InvalidAddress();
    error InvalidActions();

    // ========== CONSTRUCTOR ==========

    /**
     * @notice Initialize governance
     * @param _lkstToken Address LKST token (ERC20Votes)
     * @param _timelock Address LKSTimelock contract
     */
    constructor(address _lkstToken, address _timelock) {
        if (_lkstToken == address(0) || _timelock == address(0)) {
            revert InvalidAddress();
        }

        lkstToken = ERC20Votes(_lkstToken);
        timelock = ILKSTimelock(_timelock);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
        _grantRole(PROPOSER_ROLE, msg.sender);
    }

    // ========== PROPOSAL FUNCTIONS ==========

    /**
     * @notice Créer une proposition
     * @dev Requiert proposalThreshold LKST voting power
     * @param title Titre proposition
     * @param description Description détaillée
     * @param targets Contracts cibles
     * @param values ETH values
     * @param calldatas Calldata pour chaque action
     * @param actionDescriptions Descriptions actions
     * @return proposalId ID de la proposition
     */
    function propose(
        string calldata title,
        string calldata description,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        string[] calldata actionDescriptions
    ) external whenNotPaused returns (uint256) {
        // Vérifier voting power
        uint256 votingPower = lkstToken.getVotes(msg.sender);
        if (votingPower < proposalThreshold) {
            revert InsufficientVotingPower(proposalThreshold, votingPower);
        }

        // Valider actions
        if (targets.length == 0) revert InvalidActions();
        if (targets.length != values.length ||
            targets.length != calldatas.length ||
            targets.length != actionDescriptions.length) {
            revert InvalidActions();
        }

        uint256 proposalId = _nextProposalId++;
        uint256 startBlock = block.number + votingDelay;
        uint256 endBlock = startBlock + votingPeriod;

        Proposal storage proposal = proposals[proposalId];
        proposal.id = proposalId;
        proposal.proposer = msg.sender;
        proposal.title = title;
        proposal.description = description;
        proposal.startBlock = startBlock;
        proposal.endBlock = endBlock;
        proposal.state = ProposalState.PENDING;
        proposal.createdAt = block.timestamp;

        // Store actions
        for (uint256 i = 0; i < targets.length; i++) {
            proposal.actions.push(ProposalAction({
                target: targets[i],
                value: values[i],
                data: calldatas[i],
                description: actionDescriptions[i]
            }));
        }

        allProposalIds.push(proposalId);
        userProposals[msg.sender].push(proposalId);
        totalProposals++;

        emit ProposalCreated(
            proposalId,
            msg.sender,
            title,
            startBlock,
            endBlock
        );

        return proposalId;
    }

    /**
     * @notice Voter sur une proposition
     * @param proposalId ID proposition
     * @param support Type de vote (0=AGAINST, 1=FOR, 2=ABSTAIN)
     * @param reason Raison du vote (optionnel)
     */
    function castVote(
        uint256 proposalId,
        VoteType support,
        string calldata reason
    ) external whenNotPaused nonReentrant {
        return _castVote(msg.sender, proposalId, support, reason);
    }

    /**
     * @notice Queue une proposition approuvée dans LKSTimelock
     * @dev Schedule batch operations dans timelock contract
     * @param proposalId ID proposition
     */
    function queue(uint256 proposalId) external whenNotPaused {
        Proposal storage proposal = proposals[proposalId];

        if (proposal.state != ProposalState.SUCCEEDED) {
            revert ProposalNotSucceeded(proposalId);
        }

        // Extract actions pour timelock
        uint256 actionsLength = proposal.actions.length;
        address[] memory targets = new address[](actionsLength);
        uint256[] memory values = new uint256[](actionsLength);
        bytes[] memory calldatas = new bytes[](actionsLength);

        for (uint256 i = 0; i < actionsLength; i++) {
            targets[i] = proposal.actions[i].target;
            values[i] = proposal.actions[i].value;
            calldatas[i] = proposal.actions[i].data;
        }

        // Schedule dans timelock (predecessor = 0, salt = proposalId)
        bytes32 timelockId = timelock.scheduleBatch(
            targets,
            values,
            calldatas,
            bytes32(0),         // No predecessor
            bytes32(proposalId) // Salt = proposal ID for uniqueness
        );

        proposal.state = ProposalState.QUEUED;
        proposal.timelockId = timelockId;
        proposal.eta = timelock.getTimestamp(timelockId);

        emit ProposalQueued(proposalId, proposal.eta);
    }

    /**
     * @notice Exécuter une proposition via LKSTimelock
     * @dev Anyone can execute after timelock delay
     * @param proposalId ID proposition
     */
    function execute(uint256 proposalId) external payable whenNotPaused nonReentrant {
        Proposal storage proposal = proposals[proposalId];

        if (proposal.state != ProposalState.QUEUED) {
            revert InvalidProposalState(proposalId, proposal.state);
        }

        if (!timelock.isOperationReady(proposal.timelockId)) {
            revert TimelockNotReached(proposalId, proposal.eta);
        }

        if (proposal.executed) {
            revert ProposalAlreadyExecuted(proposalId);
        }

        proposal.state = ProposalState.EXECUTED;
        proposal.executed = true;

        // Extract actions pour timelock
        uint256 actionsLength = proposal.actions.length;
        address[] memory targets = new address[](actionsLength);
        uint256[] memory values = new uint256[](actionsLength);
        bytes[] memory calldatas = new bytes[](actionsLength);

        for (uint256 i = 0; i < actionsLength; i++) {
            targets[i] = proposal.actions[i].target;
            values[i] = proposal.actions[i].value;
            calldatas[i] = proposal.actions[i].data;
        }

        // Execute via timelock (forwarding ETH if needed)
        timelock.executeBatch{value: msg.value}(
            targets,
            values,
            calldatas,
            bytes32(0),         // No predecessor
            bytes32(proposalId) // Salt = proposal ID
        );

        emit ProposalExecuted(proposalId);
    }

    /**
     * @notice Annuler une proposition
     * @dev Seulement proposer ou guardian. Cancel aussi dans timelock si queued.
     * @param proposalId ID proposition
     */
    function cancel(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];

        if (proposals[proposalId].actions.length == 0) {
            revert ProposalNotFound(proposalId);
        }

        // Only proposer or guardian can cancel
        if (msg.sender != proposal.proposer && !hasRole(GUARDIAN_ROLE, msg.sender)) {
            revert InvalidAddress();
        }

        if (proposal.state == ProposalState.EXECUTED) {
            revert ProposalAlreadyExecuted(proposalId);
        }

        // Cancel dans timelock si déjà queued
        if (proposal.state == ProposalState.QUEUED && proposal.timelockId != bytes32(0)) {
            timelock.cancel(proposal.timelockId);
        }

        proposal.state = ProposalState.CANCELED;

        emit ProposalCanceled(proposalId);
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Get état proposition
     * @param proposalId ID proposition
     * @return ProposalState État actuel
     */
    function state(uint256 proposalId) public view returns (ProposalState) {
        Proposal storage proposal = proposals[proposalId];

        if (proposal.executed) {
            return ProposalState.EXECUTED;
        }

        if (proposal.state == ProposalState.CANCELED) {
            return ProposalState.CANCELED;
        }

        if (proposal.state == ProposalState.QUEUED) {
            if (block.timestamp > proposal.eta + 7 days) {
                return ProposalState.EXPIRED;
            }
            return ProposalState.QUEUED;
        }

        if (block.number <= proposal.startBlock) {
            return ProposalState.PENDING;
        }

        if (block.number <= proposal.endBlock) {
            return ProposalState.ACTIVE;
        }

        // Vote terminé, calculer résultat
        if (_quorumReached(proposalId) && _voteSucceeded(proposalId)) {
            return ProposalState.SUCCEEDED;
        } else {
            return ProposalState.DEFEATED;
        }
    }

    /**
     * @notice Get proposition complète
     * @param proposalId ID proposition
     * @return Proposal Données proposition
     */
    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    /**
     * @notice Get actions proposition
     * @param proposalId ID proposition
     * @return ProposalAction[] Tableau actions
     */
    function getProposalActions(uint256 proposalId) external view returns (ProposalAction[] memory) {
        return proposals[proposalId].actions;
    }

    /**
     * @notice Get receipt vote
     * @param proposalId ID proposition
     * @param voter Adresse votant
     * @return Receipt Reçu de vote
     */
    function getReceipt(uint256 proposalId, address voter) external view returns (Receipt memory) {
        return receipts[proposalId][voter];
    }

    /**
     * @notice Get propositions paginées
     * @param offset Index départ
     * @param limit Nombre max
     * @return Proposal[] Tableau propositions
     */
    function getProposals(uint256 offset, uint256 limit) external view returns (Proposal[] memory) {
        uint256 total = allProposalIds.length;
        if (offset >= total) return new Proposal[](0);

        uint256 end = offset + limit > total ? total : offset + limit;
        uint256 size = end - offset;

        Proposal[] memory result = new Proposal[](size);
        for (uint256 i = 0; i < size; i++) {
            uint256 proposalId = allProposalIds[total - 1 - (offset + i)]; // Reverse (newest first)
            result[i] = proposals[proposalId];
        }

        return result;
    }

    /**
     * @notice Get propositions user
     * @param user Adresse utilisateur
     * @return uint256[] IDs propositions
     */
    function getUserProposals(address user) external view returns (uint256[] memory) {
        return userProposals[user];
    }

    /**
     * @notice Get votes proposition
     * @param proposalId ID proposition
     * @return forVotes Votes pour
     * @return againstVotes Votes contre
     * @return abstainVotes Abstentions
     */
    function getProposalVotes(uint256 proposalId) external view returns (
        uint256 forVotes,
        uint256 againstVotes,
        uint256 abstainVotes
    ) {
        Proposal storage proposal = proposals[proposalId];
        return (proposal.forVotes, proposal.againstVotes, proposal.abstainVotes);
    }

    /**
     * @notice Check si quorum atteint
     * @param proposalId ID proposition
     * @return bool True si quorum atteint
     */
    function quorumReached(uint256 proposalId) external view returns (bool) {
        return _quorumReached(proposalId);
    }

    /**
     * @notice Get quorum requis actuel
     * @return uint256 Nombre votes requis
     */
    function quorum() public view returns (uint256) {
        return (lkstToken.totalSupply() * quorumNumerator) / 100;
    }

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @notice Set voting delay
     */
    function setVotingDelay(uint256 newDelay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldDelay = votingDelay;
        votingDelay = newDelay;
        emit VotingDelayUpdated(oldDelay, newDelay);
    }

    /**
     * @notice Set voting period
     */
    function setVotingPeriod(uint256 newPeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldPeriod = votingPeriod;
        votingPeriod = newPeriod;
        emit VotingPeriodUpdated(oldPeriod, newPeriod);
    }

    /**
     * @notice Set quorum
     */
    function setQuorumNumerator(uint256 newQuorum) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newQuorum > 100) revert InvalidActions();
        uint256 oldQuorum = quorumNumerator;
        quorumNumerator = newQuorum;
        emit QuorumUpdated(oldQuorum, newQuorum);
    }

    /**
     * @notice Set proposal threshold
     */
    function setProposalThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        proposalThreshold = newThreshold;
    }

    /**
     * @notice Pause contract
     */
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause contract
     */
    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    // ========== INTERNAL HELPERS ==========

    function _castVote(
        address voter,
        uint256 proposalId,
        VoteType support,
        string memory reason
    ) internal {
        Proposal storage proposal = proposals[proposalId];

        if (state(proposalId) != ProposalState.ACTIVE) {
            revert ProposalNotActive(proposalId);
        }

        Receipt storage receipt = receipts[proposalId][voter];
        if (receipt.hasVoted) {
            revert AlreadyVoted(proposalId);
        }

        uint256 votes = lkstToken.getPastVotes(voter, proposal.startBlock);

        if (support == VoteType.FOR) {
            proposal.forVotes += votes;
        } else if (support == VoteType.AGAINST) {
            proposal.againstVotes += votes;
        } else {
            proposal.abstainVotes += votes;
        }

        receipt.hasVoted = true;
        receipt.support = support;
        receipt.votes = votes;

        emit VoteCast(voter, proposalId, support, votes, reason);
    }

    function _quorumReached(uint256 proposalId) internal view returns (bool) {
        Proposal storage proposal = proposals[proposalId];
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes + proposal.abstainVotes;
        return totalVotes >= quorum();
    }

    function _voteSucceeded(uint256 proposalId) internal view returns (bool) {
        Proposal storage proposal = proposals[proposalId];
        return proposal.forVotes > proposal.againstVotes;
    }
}
