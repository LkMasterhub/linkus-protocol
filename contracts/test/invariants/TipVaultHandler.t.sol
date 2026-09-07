// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test}        from "forge-std/Test.sol";
import {LksTipVault} from "../../src/tips/LksTipVault.sol";

/**
 * @notice Bounded handler for LksTipVault invariant tests.
 *         Each function is called with random inputs by the fuzzer ; the
 *         handler bounds them so that calls succeed at a non-trivial rate.
 */
contract TipVaultHandler is Test {
    LksTipVault public vault;

    address[]      public actors;
    bytes32[]      public posts;

    /// @dev Sum of all wei sent via tip() — ghost variable cross-checking balance.
    uint256 public ghost_totalTipped;
    /// @dev Sum of authorShare credited to authors via tip().
    uint256 public ghost_totalAuthorShares;
    /// @dev Sum of platformFee credited via tip().
    uint256 public ghost_totalPlatformFees;
    /// @dev Sum withdrawn by authors.
    uint256 public ghost_totalAuthorWithdrawn;
    /// @dev Sum withdrawn by platform fee recipient.
    uint256 public ghost_totalPlatformWithdrawn;

    constructor(LksTipVault _vault, address[] memory _actors, bytes32[] memory _posts) {
        vault  = _vault;
        actors = _actors;
        posts  = _posts;
    }

    function tip(uint256 actorSeed, uint256 authorSeed, uint256 postSeed, uint256 amount) public {
        address tipper = actors[actorSeed % actors.length];
        address author = actors[authorSeed % actors.length];
        bytes32 postId = posts[postSeed % posts.length];
        amount = bound(amount, vault.MIN_TIP(), 5 ether);
        if (vault.paused()) return;
        if (author == address(0)) return;

        uint256 fee         = (amount * vault.feeBps()) / 10_000;
        uint256 authorShare = amount - fee;

        vm.deal(tipper, amount);
        vm.prank(tipper);
        try vault.tip{value: amount}(postId, author) {
            ghost_totalTipped       += amount;
            ghost_totalAuthorShares += authorShare;
            ghost_totalPlatformFees += fee;
        } catch {
            // ignore (paused, etc.)
        }
    }

    function withdrawAuthor(uint256 actorSeed) public {
        address user = actors[actorSeed % actors.length];
        uint256 owed = vault.tipsOwed(user);
        if (owed == 0) return;
        vm.prank(user);
        try vault.withdraw() {
            ghost_totalAuthorWithdrawn += owed;
        } catch {}
    }

    function withdrawPlatform() public {
        uint256 fees = vault.platformFees();
        if (fees == 0) return;
        try vault.withdrawPlatformFees() {
            ghost_totalPlatformWithdrawn += fees;
        } catch {}
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }
}

/**
 * @title  TipVaultInvariantTest
 * @notice INV-01, INV-02, INV-03 (cf. plan V8).
 *
 *         INV-01 : sum(tipsOwed) + platformFees == address(vault).balance
 *         INV-02 : address(vault).balance ≥ 0 (toujours vrai, sanity)
 *         INV-03 : feeBps ≤ MAX_FEE_BPS
 */
contract TipVaultInvariantTest is Test {
    LksTipVault       internal vault;
    TipVaultHandler   internal handler;

    address internal admin     = makeAddr("admin");
    address internal recipient = makeAddr("recipient");

    address[] internal actors;
    bytes32[] internal posts;

    function setUp() public {
        vault = new LksTipVault(admin, 250, recipient); // 2.5%

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));

        posts.push(keccak256("post-1"));
        posts.push(keccak256("post-2"));
        posts.push(keccak256("post-3"));

        handler = new TipVaultHandler(vault, actors, posts);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = TipVaultHandler.tip.selector;
        selectors[1] = TipVaultHandler.withdrawAuthor.selector;
        selectors[2] = TipVaultHandler.withdrawPlatform.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice INV-01 : sum(tipsOwed) + platformFees == vault.balance + total withdrawn
    function invariant_balanceAccounting() public view {
        // sum(tipsOwed[*]) for our actors
        uint256 sumOwed = 0;
        for (uint256 i = 0; i < actors.length; ++i) {
            sumOwed += vault.tipsOwed(actors[i]);
        }
        uint256 totalCredits = handler.ghost_totalAuthorShares() + handler.ghost_totalPlatformFees();
        uint256 totalDebits  = handler.ghost_totalAuthorWithdrawn() + handler.ghost_totalPlatformWithdrawn();

        // Invariant : totalCredits == sumOwed + platformFees + totalDebits
        // Equivalent : sumOwed + platformFees == totalCredits - totalDebits == vault.balance
        assertEq(sumOwed + vault.platformFees(), totalCredits - totalDebits);
        assertEq(address(vault).balance, sumOwed + vault.platformFees());
    }

    /// @notice INV-03 : feeBps ≤ MAX_FEE_BPS toujours
    function invariant_feeBpsBounded() public view {
        assertLe(vault.feeBps(), vault.MAX_FEE_BPS());
    }

    /// @notice INV-07 sanity : ghost totals cohérents
    function invariant_ghostTotalsCoherent() public view {
        assertEq(
            handler.ghost_totalAuthorShares() + handler.ghost_totalPlatformFees(),
            handler.ghost_totalTipped()
        );
    }
}
