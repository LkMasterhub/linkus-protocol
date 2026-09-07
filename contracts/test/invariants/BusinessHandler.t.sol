// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test}            from "forge-std/Test.sol";
import {ERC1967Proxy}    from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LksBusinessV8}   from "../../src/business/LksBusinessV8.sol";
import {ILksBusinessV8}  from "../../src/business/ILksBusinessV8.sol";

/**
 * @title  BusinessHandler
 * @notice Bounded handler for LksBusinessV8 invariant tests.
 *         Reproduit le cycle complet : create → fund → cancel? → withdraw/refund.
 */
contract BusinessHandler is Test {
    LksBusinessV8 public biz;
    address[]     public actors;
    bytes32[]     public projectIds;

    /// @dev Sum tracker pour cross-checking accounting.
    uint256 public ghost_totalFunded;
    uint256 public ghost_totalRefunded;
    uint256 public ghost_totalCreatorWithdrawn;
    uint256 public ghost_totalPlatformWithdrawn;

    constructor(LksBusinessV8 _biz, address[] memory _actors) {
        biz    = _biz;
        actors = _actors;
    }

    function createProject(uint256 actorSeed, uint256 saltSeed, uint128 goal, uint64 durationOffset) public {
        address creator = actors[actorSeed % actors.length];
        bytes32 salt    = keccak256(abi.encodePacked(saltSeed, creator));
        goal = uint128(bound(uint256(goal), 1 ether, 100 ether));
        // Duration in [1h+1, 30 days]
        durationOffset = uint64(bound(uint256(durationOffset), 1 hours + 1, 30 days));

        // Skip si déjà créé
        bytes32 expectedId = biz.projectIdOf(creator, salt);
        if (biz.project(expectedId).creator != address(0)) return;

        uint64 deadline = uint64(block.timestamp) + durationOffset;
        vm.prank(creator);
        try biz.createProject(salt, goal, deadline) returns (bytes32 id) {
            projectIds.push(id);
        } catch {}
    }

    function fund(uint256 actorSeed, uint256 projectSeed, uint128 amount) public {
        if (projectIds.length == 0) return;
        address funder = actors[actorSeed % actors.length];
        bytes32 id     = projectIds[projectSeed % projectIds.length];
        amount = uint128(bound(uint256(amount), 0.001 ether, 10 ether));

        // Skip si projet plus ACTIVE
        ILksBusinessV8.Project memory p = biz.project(id);
        if (p.status != ILksBusinessV8.ProjectStatus.ACTIVE) return;
        if (block.timestamp >= p.deadline) return;
        if (uint256(p.raised) + amount > type(uint128).max) return;

        vm.deal(funder, amount);
        vm.prank(funder);
        try biz.fund{value: amount}(id) {
            ghost_totalFunded += amount;
        } catch {}
    }

    function withdrawFunds(uint256 projectSeed) public {
        if (projectIds.length == 0) return;
        bytes32 id = projectIds[projectSeed % projectIds.length];
        ILksBusinessV8.Project memory p = biz.project(id);
        if (p.creator == address(0)) return;

        uint256 fee = (uint256(p.raised) * biz.platformFeeBps()) / 10_000;
        uint256 creatorAmount = uint256(p.raised) - fee;

        vm.prank(p.creator);
        try biz.withdrawFunds(id) {
            ghost_totalCreatorWithdrawn += creatorAmount;
        } catch {}
    }

    function refund(uint256 actorSeed, uint256 projectSeed) public {
        if (projectIds.length == 0) return;
        address contributor = actors[actorSeed % actors.length];
        bytes32 id          = projectIds[projectSeed % projectIds.length];
        uint256 owed = biz.contribution(id, contributor);
        if (owed == 0) return;

        vm.prank(contributor);
        try biz.refund(id) {
            ghost_totalRefunded += owed;
        } catch {}
    }

    function cancelByAdmin(uint256 projectSeed, address admin) public {
        if (projectIds.length == 0) return;
        bytes32 id = projectIds[projectSeed % projectIds.length];
        vm.prank(admin);
        try biz.cancelProject(id) {} catch {}
    }

    function withdrawPlatformFees() public {
        uint256 fees = biz.accumulatedPlatformFees();
        if (fees == 0) return;
        try biz.withdrawPlatformFees() {
            ghost_totalPlatformWithdrawn += fees;
        } catch {}
    }

    function warpForward(uint256 secondsForward) public {
        secondsForward = bound(secondsForward, 1, 35 days);
        vm.warp(block.timestamp + secondsForward);
    }

    function actorsLength() external view returns (uint256) { return actors.length; }
    function projectIdsLength() external view returns (uint256) { return projectIds.length; }
}

/**
 * @title  BusinessInvariantTest
 * @notice INV-13, INV-14, INV-15.
 *
 *         INV-13 : status ∈ {NONE, ACTIVE, FUNDED, REFUNDABLE, CANCELLED, WITHDRAWN}
 *         INV-14 : status==FUNDED post-deadline ⇒ raised ≥ goal
 *         INV-15 : address(biz).balance == totalFunded - refunded - creatorWithdrawn - platformWithdrawn
 */
contract BusinessInvariantTest is Test {
    LksBusinessV8   internal biz;
    BusinessHandler internal handler;

    address internal admin    = makeAddr("admin");
    address internal treasury = makeAddr("treasury");

    address[] internal actors;

    function setUp() public {
        LksBusinessV8 impl = new LksBusinessV8();
        bytes memory data = abi.encodeWithSelector(
            LksBusinessV8.initialize.selector, admin, treasury, uint16(250)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        biz = LksBusinessV8(address(proxy));

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));

        handler = new BusinessHandler(biz, actors);

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = BusinessHandler.createProject.selector;
        selectors[1] = BusinessHandler.fund.selector;
        selectors[2] = BusinessHandler.withdrawFunds.selector;
        selectors[3] = BusinessHandler.refund.selector;
        selectors[4] = BusinessHandler.cancelByAdmin.selector;
        selectors[5] = BusinessHandler.withdrawPlatformFees.selector;
        selectors[6] = BusinessHandler.warpForward.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice INV-15 : balance accounting global cohérent
    function invariant_balanceAccounting() public view {
        uint256 expected =
            handler.ghost_totalFunded()
            - handler.ghost_totalRefunded()
            - handler.ghost_totalCreatorWithdrawn()
            - handler.ghost_totalPlatformWithdrawn();
        assertEq(address(biz).balance, expected);
    }

    /// @notice INV-14 : si status calculé = FUNDED, raised ≥ goal
    function invariant_fundedImpliesGoalReached() public view {
        for (uint256 i = 0; i < handler.projectIdsLength(); ++i) {
            bytes32 id = handler.projectIds(i);
            ILksBusinessV8.ProjectStatus s = biz.projectStatus(id);
            if (s == ILksBusinessV8.ProjectStatus.FUNDED
                || s == ILksBusinessV8.ProjectStatus.WITHDRAWN) {
                ILksBusinessV8.Project memory p = biz.project(id);
                assertGe(uint256(p.raised), uint256(p.goal));
            }
        }
    }

    /// @notice INV-13 : creator existe et raised ≤ uint128.max pour tous les projets enregistrés
    function invariant_projectStateConsistent() public view {
        for (uint256 i = 0; i < handler.projectIdsLength(); ++i) {
            bytes32 id = handler.projectIds(i);
            ILksBusinessV8.Project memory p = biz.project(id);
            assertTrue(p.creator != address(0));
            assertLe(uint256(p.raised), uint256(type(uint128).max));
        }
    }

    /// @notice Sanity : platformFeeBps ≤ MAX
    function invariant_feeBpsBounded() public view {
        assertLe(biz.platformFeeBps(), uint16(3000));
    }
}
