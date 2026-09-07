// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/governance/LksGovernanceUpgradeable.sol";
import "../src/governance/LKSTimelockUpgradeable.sol";
import "../src/token/LKSTUpgradeable.sol";

/**
 * @dev Tests pour les fixes Phase 4 appliqués à LksGovernanceUpgradeable :
 *        - LKS-GOV-04 : queue() utilise state(proposalId) dynamique
 *        - LKS-GOV-05 : execute() utilise state(proposalId) dynamique
 *        - LKS-GOV-08 : quorumForProposal utilise getPastTotalSupply
 *        - LKS-GOV-09 : propose() utilise getPastVotes(block.number - 1)
 *      Et le fix LKS-TL-01 sur LKSTimelockUpgradeable.
 */
contract LksGovernanceFixesTest is Test {
    LKSTUpgradeable public lkst;
    LKSTimelockUpgradeable public timelock;
    LksGovernanceUpgradeable public governance;

    address public admin = address(0xA11CE);
    address public alice = address(0x1111);
    address public bob   = address(0x2222);

    // Helpers constants for voting
    uint256 constant VOTER_SUPPLY = 100_000_000 ether; // 100M LKST each for alice & bob

    function setUp() public {
        // Deploy LKST token — initialize grants roles to msg.sender, so prank as admin
        LKSTUpgradeable lkstImpl = new LKSTUpgradeable();
        vm.prank(admin);
        ERC1967Proxy lkstProxy = new ERC1967Proxy(
            address(lkstImpl),
            abi.encodeCall(LKSTUpgradeable.initialize, (admin))
        );
        lkst = LKSTUpgradeable(address(lkstProxy));

        // Deploy Timelock — initialize takes admin as parameter
        LKSTimelockUpgradeable tlImpl = new LKSTimelockUpgradeable();
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;

        ERC1967Proxy tlProxy = new ERC1967Proxy(
            address(tlImpl),
            abi.encodeCall(LKSTimelockUpgradeable.initialize, (2 days, proposers, executors, admin))
        );
        timelock = LKSTimelockUpgradeable(payable(address(tlProxy)));

        // Deploy Governance — initialize grants roles to msg.sender, so prank as admin
        LksGovernanceUpgradeable govImpl = new LksGovernanceUpgradeable();
        vm.prank(admin);
        ERC1967Proxy govProxy = new ERC1967Proxy(
            address(govImpl),
            abi.encodeCall(LksGovernanceUpgradeable.initialize, (address(lkst), address(timelock)))
        );
        governance = LksGovernanceUpgradeable(address(govProxy));

        // Admin transfers some LKST to alice and bob and grants PROPOSER_ROLE
        vm.startPrank(admin);
        lkst.transfer(alice, VOTER_SUPPLY);
        lkst.transfer(bob, VOTER_SUPPLY);

        // Give governance the PROPOSER_ROLE and EXECUTOR_ROLE on Timelock
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governance));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(governance));

        // Lower proposal threshold to allow alice to propose
        governance.setProposalThreshold(1_000 ether);
        governance.setVotingDelay(1);   // 1 block delay
        governance.setVotingPeriod(10); // 10 blocks voting period
        vm.stopPrank();
    }

    // ============================================================================
    // LKS-TL-01 FIX : DEFAULT_ADMIN_ROLE accordé au Timelock
    // ============================================================================

    function test_LKS_TL_01_defaultAdminRoleGranted() public {
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_LKS_TL_01_timelockAdminRoleAdminIsDefaultAdmin() public {
        // getRoleAdmin(TIMELOCK_ADMIN_ROLE) should be DEFAULT_ADMIN_ROLE
        assertEq(
            timelock.getRoleAdmin(timelock.TIMELOCK_ADMIN_ROLE()),
            timelock.DEFAULT_ADMIN_ROLE()
        );
    }

    function test_LKS_TL_01_canGrantTimelockAdminToAnother() public {
        // Avec le fix, admin peut maintenant accorder TIMELOCK_ADMIN_ROLE à un autre compte
        bytes32 role = timelock.TIMELOCK_ADMIN_ROLE();
        vm.prank(admin);
        timelock.grantRole(role, bob);
        assertTrue(timelock.hasRole(role, bob));
    }

    // ============================================================================
    // LKS-GOV-09 FIX : propose() utilise getPastVotes
    // ============================================================================

    function test_LKS_GOV_09_proposeRequiresDelegation() public {
        // Alice has tokens but hasn't delegated → getPastVotes(alice, block.number-1) = 0
        // → should revert with InsufficientVotingPower
        vm.roll(block.number + 1); // advance block
        vm.prank(alice);
        vm.expectRevert();
        _propose(alice, "Test", "Description");
    }

    function test_LKS_GOV_09_proposeSucceedsAfterDelegation() public {
        // Alice delegates to herself
        vm.prank(alice);
        lkst.delegate(alice);
        vm.roll(block.number + 1); // delegation takes effect in next block

        vm.prank(alice);
        uint256 propId = _propose(alice, "Test", "Description");
        assertGt(propId, 0);
    }

    // ============================================================================
    // LKS-GOV-04 + 05 : queue() / execute() utilisent state(proposalId) dynamique
    // ============================================================================

    function test_LKS_GOV_04_05_fullGovernanceFlow() public {
        // Debug : vérifier les valeurs config
        assertEq(governance.votingDelay(), 1);
        assertEq(governance.votingPeriod(), 10);

        // Alice and Bob delegate to themselves
        vm.prank(alice);
        lkst.delegate(alice);
        vm.prank(bob);
        lkst.delegate(bob);
        // Advance several blocks so delegation checkpoints are in the past
        vm.roll(block.number + 10);

        // Alice proposes (uses getPastVotes fix, LKS-GOV-09)
        vm.prank(alice);
        uint256 propId = _propose(alice, "Test", "Desc");

        // Advance well past startBlock (votingDelay=1) into voting period
        vm.roll(block.number + 5);
        assertEq(
            uint8(governance.state(propId)),
            uint8(LksGovernanceUpgradeable.ProposalState.ACTIVE)
        );

        // Alice and bob vote FOR (uses getPastVotes at startBlock)
        vm.prank(alice);
        governance.castVote(propId, LksGovernanceUpgradeable.VoteType.FOR, "yes");
        vm.prank(bob);
        governance.castVote(propId, LksGovernanceUpgradeable.VoteType.FOR, "yes");

        // End voting period (votingPeriod=10, advance past it)
        vm.roll(block.number + 20);

        // LKS-GOV-04 check : state(proposalId) should now return SUCCEEDED
        assertEq(
            uint8(governance.state(propId)),
            uint8(LksGovernanceUpgradeable.ProposalState.SUCCEEDED)
        );

        // queue() should work (was broken in V6 before fix)
        governance.queue(propId);
        assertEq(
            uint8(governance.state(propId)),
            uint8(LksGovernanceUpgradeable.ProposalState.QUEUED)
        );

        // Advance past timelock delay (2 days)
        vm.warp(block.timestamp + 2 days + 1);

        // execute() should work (LKS-GOV-05 fix)
        governance.execute(propId);
        assertEq(
            uint8(governance.state(propId)),
            uint8(LksGovernanceUpgradeable.ProposalState.EXECUTED)
        );
    }

    // ============================================================================
    // LKS-GOV-08 FIX : quorumForProposal utilise past total supply
    // ============================================================================

    function test_LKS_GOV_08_quorumForProposalExists() public {
        // Test minimaliste : vérifie que quorumForProposal est callable et retourne une valeur
        // non-nulle cohérente. Le comportement détaillé getPastTotalSupply est déjà testé par
        // OpenZeppelin upstream.
        vm.prank(alice);
        lkst.delegate(alice);
        vm.roll(block.number + 5);

        vm.prank(alice);
        uint256 propId = _propose(alice, "Test", "Desc");

        // Au moins appelable sans revert
        uint256 q = governance.quorumForProposal(propId);
        // Quorum doit être > 0 (il y a au moins 1B LKST en supply)
        assertGt(q, 0);
        // Quorum doit être cohérent avec 10 % du supply (quorumNumerator = 10)
        uint256 expectedMax = (lkst.totalSupply() * 10) / 100;
        assertLe(q, expectedMax + 1);
    }

    // ============================================================================
    // HELPERS
    // ============================================================================

    function _propose(
        address /*proposer*/,
        string memory title,
        string memory description
    ) internal returns (uint256) {
        address[] memory targets = new address[](1);
        targets[0] = address(0xDEAD);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = "";
        string[] memory actionDescs = new string[](1);
        actionDescs[0] = "noop";

        return governance.propose(title, description, targets, values, calldatas, actionDescs);
    }
}
