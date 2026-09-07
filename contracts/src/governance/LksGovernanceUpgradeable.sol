// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "./ILKSTimelock.sol";

/**
 * @title LksGovernanceUpgradeable
 * @notice Système de gouvernance décentralisée pour LinkUs Protocol (UUPS Upgradeable)
 * @dev Utilise LKST (ERC20Votes) pour voting power + LKSTimelock pour sécurité
 */
contract LksGovernanceUpgradeable is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    // ========== TYPES ==========

    enum ProposalState { PENDING, ACTIVE, CANCELED, DEFEATED, SUCCEEDED, QUEUED, EXPIRED, EXECUTED }
    enum VoteType { AGAINST, FOR, ABSTAIN }

    struct ProposalAction {
        address target;
        uint256 value;
        bytes data;
        string description;
    }

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
        uint256 eta;
        bytes32 timelockId;
        bool executed;
        uint256 createdAt;
    }

    struct Receipt {
        bool hasVoted;
        VoteType support;
        uint256 votes;
    }

    // ========== STORAGE ==========

    ERC20Votes public lkstToken;
    ILKSTimelock public timelock;

    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 private _nextProposalId;
    mapping(uint256 => Proposal) private proposals;
    mapping(uint256 => mapping(address => Receipt)) public receipts;
    uint256[] public allProposalIds;
    mapping(address => uint256[]) public userProposals;

    uint256 public votingDelay;
    uint256 public votingPeriod;
    uint256 public timelockDelay;
    uint256 public proposalThreshold;
    uint256 public quorumNumerator;
    uint256 public totalProposals;

    // ========== EVENTS ==========

    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, string title, uint256 startBlock, uint256 endBlock);
    event VoteCast(address indexed voter, uint256 indexed proposalId, VoteType support, uint256 votes, string reason);
    event ProposalQueued(uint256 indexed proposalId, uint256 eta);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCanceled(uint256 indexed proposalId);
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

    // ========== CONSTRUCTOR & INITIALIZER ==========

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _lkstToken, address _timelock) public initializer {
        if (_lkstToken == address(0) || _timelock == address(0)) {
            revert InvalidAddress();
        }

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        lkstToken = ERC20Votes(_lkstToken);
        timelock = ILKSTimelock(_timelock);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
        _grantRole(PROPOSER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        _nextProposalId = 1;
        votingDelay = 1 days;
        votingPeriod = 5 days;
        timelockDelay = 2 days;
        proposalThreshold = 1000 * 10**18;
        quorumNumerator = 10;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // ========== PROPOSAL FUNCTIONS ==========

    function propose(
        string calldata title,
        string calldata description,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        string[] calldata actionDescriptions
    ) external whenNotPaused returns (uint256) {
        // LKS-GOV-09 fix : utiliser getPastVotes(block.number - 1) pour empêcher
        // les flashloan attacks sur le proposalThreshold (voter avec des LKST
        // empruntés puis rembourser dans la même transaction).
        uint256 votingPower = lkstToken.getPastVotes(msg.sender, block.number - 1);
        if (votingPower < proposalThreshold) {
            revert InsufficientVotingPower(proposalThreshold, votingPower);
        }

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

        emit ProposalCreated(proposalId, msg.sender, title, startBlock, endBlock);
        return proposalId;
    }

    function castVote(uint256 proposalId, VoteType support, string calldata reason) external whenNotPaused nonReentrant {
        return _castVote(msg.sender, proposalId, support, reason);
    }

    function queue(uint256 proposalId) external whenNotPaused {
        Proposal storage proposal = proposals[proposalId];

        // LKS-GOV-04 fix : utiliser state(proposalId) (view function dynamique)
        // au lieu de proposal.state qui n'est jamais muté vers SUCCEEDED.
        if (state(proposalId) != ProposalState.SUCCEEDED) {
            revert ProposalNotSucceeded(proposalId);
        }

        uint256 actionsLength = proposal.actions.length;
        address[] memory targets = new address[](actionsLength);
        uint256[] memory values = new uint256[](actionsLength);
        bytes[] memory calldatas = new bytes[](actionsLength);

        for (uint256 i = 0; i < actionsLength; i++) {
            targets[i] = proposal.actions[i].target;
            values[i] = proposal.actions[i].value;
            calldatas[i] = proposal.actions[i].data;
        }

        bytes32 timelockId = timelock.scheduleBatch(
            targets,
            values,
            calldatas,
            bytes32(0),
            bytes32(proposalId)
        );

        proposal.state = ProposalState.QUEUED;
        proposal.timelockId = timelockId;
        proposal.eta = timelock.getTimestamp(timelockId);

        emit ProposalQueued(proposalId, proposal.eta);
    }

    function execute(uint256 proposalId) external payable whenNotPaused nonReentrant {
        Proposal storage proposal = proposals[proposalId];

        // LKS-GOV-05 fix : utiliser state(proposalId) (view function dynamique)
        // pour gérer EXPIRED automatiquement.
        if (state(proposalId) != ProposalState.QUEUED) {
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

        uint256 actionsLength = proposal.actions.length;
        address[] memory targets = new address[](actionsLength);
        uint256[] memory values = new uint256[](actionsLength);
        bytes[] memory calldatas = new bytes[](actionsLength);

        for (uint256 i = 0; i < actionsLength; i++) {
            targets[i] = proposal.actions[i].target;
            values[i] = proposal.actions[i].value;
            calldatas[i] = proposal.actions[i].data;
        }

        timelock.executeBatch{value: msg.value}(
            targets,
            values,
            calldatas,
            bytes32(0),
            bytes32(proposalId)
        );

        emit ProposalExecuted(proposalId);
    }

    function cancel(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];

        if (proposals[proposalId].actions.length == 0) {
            revert ProposalNotFound(proposalId);
        }

        if (msg.sender != proposal.proposer && !hasRole(GUARDIAN_ROLE, msg.sender)) {
            revert InvalidAddress();
        }

        if (proposal.state == ProposalState.EXECUTED) {
            revert ProposalAlreadyExecuted(proposalId);
        }

        if (proposal.state == ProposalState.QUEUED && proposal.timelockId != bytes32(0)) {
            timelock.cancel(proposal.timelockId);
        }

        proposal.state = ProposalState.CANCELED;
        emit ProposalCanceled(proposalId);
    }

    // ========== VIEW FUNCTIONS ==========

    function state(uint256 proposalId) public view returns (ProposalState) {
        Proposal storage proposal = proposals[proposalId];

        if (proposal.executed) return ProposalState.EXECUTED;
        if (proposal.state == ProposalState.CANCELED) return ProposalState.CANCELED;
        if (proposal.state == ProposalState.QUEUED) {
            if (block.timestamp > proposal.eta + 7 days) return ProposalState.EXPIRED;
            return ProposalState.QUEUED;
        }
        if (block.number <= proposal.startBlock) return ProposalState.PENDING;
        if (block.number <= proposal.endBlock) return ProposalState.ACTIVE;

        if (_quorumReached(proposalId) && _voteSucceeded(proposalId)) {
            return ProposalState.SUCCEEDED;
        } else {
            return ProposalState.DEFEATED;
        }
    }

    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    function getProposalActions(uint256 proposalId) external view returns (ProposalAction[] memory) {
        return proposals[proposalId].actions;
    }

    function getReceipt(uint256 proposalId, address voter) external view returns (Receipt memory) {
        return receipts[proposalId][voter];
    }

    function getProposals(uint256 offset, uint256 limit) external view returns (Proposal[] memory) {
        uint256 total = allProposalIds.length;
        if (offset >= total) return new Proposal[](0);

        uint256 end = offset + limit > total ? total : offset + limit;
        uint256 size = end - offset;

        Proposal[] memory result = new Proposal[](size);
        for (uint256 i = 0; i < size; i++) {
            uint256 proposalId = allProposalIds[total - 1 - (offset + i)];
            result[i] = proposals[proposalId];
        }

        return result;
    }

    function getUserProposals(address user) external view returns (uint256[] memory) {
        return userProposals[user];
    }

    function getProposalVotes(uint256 proposalId) external view returns (uint256, uint256, uint256) {
        Proposal storage proposal = proposals[proposalId];
        return (proposal.forVotes, proposal.againstVotes, proposal.abstainVotes);
    }

    function quorumReached(uint256 proposalId) external view returns (bool) {
        return _quorumReached(proposalId);
    }

    function quorum() public view returns (uint256) {
        return (lkstToken.totalSupply() * quorumNumerator) / 100;
    }

    /**
     * @notice LKS-GOV-08 fix : quorum calculé sur le past total supply au moment du startBlock
     *         de la proposition, pas sur le supply courant qui est manipulable via mint/burn
     *         entre snapshot et quorum check.
     */
    function quorumForProposal(uint256 proposalId) public view returns (uint256) {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.startBlock == 0) return 0;
        // getPastTotalSupply requiert que le block soit strictement passé
        uint256 snapshotBlock = proposal.startBlock > 0 ? proposal.startBlock : block.number - 1;
        if (snapshotBlock >= block.number) {
            return (lkstToken.totalSupply() * quorumNumerator) / 100;
        }
        return (lkstToken.getPastTotalSupply(snapshotBlock) * quorumNumerator) / 100;
    }

    // ========== ADMIN FUNCTIONS ==========

    function setVotingDelay(uint256 newDelay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldDelay = votingDelay;
        votingDelay = newDelay;
        emit VotingDelayUpdated(oldDelay, newDelay);
    }

    function setVotingPeriod(uint256 newPeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldPeriod = votingPeriod;
        votingPeriod = newPeriod;
        emit VotingPeriodUpdated(oldPeriod, newPeriod);
    }

    function setQuorumNumerator(uint256 newQuorum) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newQuorum > 100) revert InvalidActions();
        uint256 oldQuorum = quorumNumerator;
        quorumNumerator = newQuorum;
        emit QuorumUpdated(oldQuorum, newQuorum);
    }

    function setProposalThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        proposalThreshold = newThreshold;
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    // ========== INTERNAL HELPERS ==========

    function _castVote(address voter, uint256 proposalId, VoteType support, string memory reason) internal {
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
        // LKS-GOV-08 fix : utiliser le past total supply au startBlock
        return totalVotes >= quorumForProposal(proposalId);
    }

    function _voteSucceeded(uint256 proposalId) internal view returns (bool) {
        Proposal storage proposal = proposals[proposalId];
        return proposal.forVotes > proposal.againstVotes;
    }

    // ========== STORAGE GAP ==========

    uint256[50] private __gap;
}
