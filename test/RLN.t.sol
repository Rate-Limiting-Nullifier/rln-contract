// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "forge-std/Test.sol";

import "../src/RLN.sol";
import {IVerifier} from "../src/IVerifier.sol";

contract TestERC20 is ERC20 {
    constructor() ERC20("TestERC20", "TST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockVerifier is IVerifier {
    bool public result;

    constructor() {
        result = true;
    }

    function verifyProof(uint256[2] memory, uint256[2][2] memory, uint256[2] memory, uint256[2] memory)
        external
        view
        returns (bool)
    {
        return result;
    }

    function changeResult(bool _result) external {
        result = _result;
    }
}

contract RLNTest is Test {
    RLN rln;
    TestERC20 token;
    MockVerifier verifier;

    uint256 rlnInitialTokenBalance = 1000000;
    uint256 minimalDeposit = 100;
    uint256 depth = 20;
    uint8 feePercentage = 10;
    address feeReceiver = makeAddr("feeReceiver");
    uint256 freezePeriod = 1;

    uint256 identityCommitment0 = 1234;
    uint256 identityCommitment1 = 5678;

    address user0 = makeAddr("user0");
    address user1 = makeAddr("user1");
    address slashedReceiver = makeAddr("slashedReceiver");

    uint256 messageLimit0 = 2;
    uint256 messageLimit1 = 3;

    uint256[8] mockProof =
        [uint256(0), uint256(1), uint256(2), uint256(3), uint256(4), uint256(5), uint256(6), uint256(7)];

    function setUp() public {
        token = new TestERC20();
        verifier = new MockVerifier();
        rln = new RLN(
            minimalDeposit,
            depth,
            feePercentage,
            feeReceiver,
            freezePeriod,
            address(token),
            address(verifier)
        );
    }

    function test_initial_state() public {
        assertEq(rln.MINIMAL_DEPOSIT(), minimalDeposit);
        assertEq(rln.DEPTH(), depth);
        assertEq(rln.SET_SIZE(), 1 << depth);
        assertEq(rln.FEE_PERCENTAGE(), feePercentage);
        assertEq(rln.FEE_RECEIVER(), feeReceiver);
        assertEq(rln.FREEZE_PERIOD(), freezePeriod);
        assertEq(address(rln.token()), address(token));
        assertEq(address(rln.verifier()), address(verifier));
        assertEq(rln.identityCommitmentIndex(), 0);

        assertEq(token.balanceOf(address(rln)), 0);
    }

    /* register */

    function test_register_succeeds() public {
        // Test: register one user
        register(user0, identityCommitment0, messageLimit0);
        // Test: register second user
        register(user1, identityCommitment1, messageLimit1);
    }

    function test_register_fails_when_index_exceeds_set_size() public {
        // Set size is (1 << smallDepth) = 2
        uint256 smallDepth = 1;
        // uint256 smallSetSize = 1 << smallDepth;
        //
        TestERC20 _token = new TestERC20();
        RLN smallRLN = new RLN(
            minimalDeposit,
            smallDepth,
            feePercentage,
            feeReceiver,
            0,
            address(_token),
            address(verifier)
        );

        // register first user
        _token.mint(user0, minimalDeposit);
        vm.startPrank(user0);
        _token.approve(address(smallRLN), minimalDeposit);
        smallRLN.register(identityCommitment0, minimalDeposit);
        vm.stopPrank();
        // register second user
        _token.mint(user1, minimalDeposit);
        vm.startPrank(user1);
        _token.approve(address(smallRLN), minimalDeposit);
        smallRLN.register(identityCommitment1, minimalDeposit);
        vm.stopPrank();
        // Now tree (set) is full. Try register the third
        address user2 = makeAddr("user2");
        uint256 identityCommitment2 = 9999;
        token.mint(user2, minimalDeposit);
        vm.startPrank(user2);
        token.approve(address(smallRLN), minimalDeposit);
        // RLN, register: set is full
        vm.expectRevert("RLN, register: set is full");
        smallRLN.register(identityCommitment2, minimalDeposit);
        vm.stopPrank();
    }

    function test_register_fails_when_amount_lt_minimal_deposit() public {
        uint256 insufficientAmount = minimalDeposit - 1;
        token.mint(user0, rlnInitialTokenBalance);
        vm.startPrank(user0);
        token.approve(address(rln), rlnInitialTokenBalance);
        // vm.expectRevert("ERC20: insufficient allowance");
        // RLN, register: amount is lower than minimal deposit
        vm.expectRevert("RLN, register: amount is lower than minimal deposit");
        rln.register(identityCommitment0, insufficientAmount);
        vm.stopPrank();
    }

    function test_register_fails_when_duplicate_identity_commitments() public {
        // Register first with user0 with identityCommitment0
        register(user0, identityCommitment0, messageLimit0);
        // Register again with user1 with identityCommitment0
        token.mint(user1, rlnInitialTokenBalance);
        vm.startPrank(user1);
        token.approve(address(rln), rlnInitialTokenBalance);
        // Revert
        vm.expectRevert("RLN, register: idCommitment already registered");
        rln.register(identityCommitment0, rlnInitialTokenBalance);
        vm.stopPrank();
    }

    /* withdraw */

    function test_withdraw_succeeds() public {
        // register first
        register(user0, identityCommitment0, messageLimit0);
        // withdraw user0
        // Make sure mock verifier always return true
        assertEq(verifier.result(), true);
        rln.withdraw(identityCommitment0, mockProof);
        (uint256 blockNumber, uint256 amount, address receiver) = rln.withdrawals(identityCommitment0);
        assertEq(blockNumber, block.number);
        assertEq(amount, getRegisterAmount(messageLimit0));
        assertEq(receiver, user0);
    }

    function test_withdraw_fails_when_not_registered() public {
        // Withdraw fails
        vm.expectRevert("RLN, withdraw: member doesn't exist");
        rln.withdraw(identityCommitment0, mockProof);
    }

    function test_withdraw_fails_when_already_underways() public {
        // register first
        register(user0, identityCommitment0, messageLimit0);
        // withdraw user0
        rln.withdraw(identityCommitment0, mockProof);
        // withdraw again
        vm.expectRevert("RLN, release: such withdrawal exists");
        rln.withdraw(identityCommitment0, mockProof);
    }

    function test_withdraw_fails_when_invalid_proof() public {
        // register first
        register(user0, identityCommitment0, messageLimit0);
        // withdraw user0
        // Make sure mock verifier always return false
        verifier.changeResult(false);
        assertEq(verifier.result(), false);
        vm.expectRevert("RLN, withdraw: invalid proof");
        rln.withdraw(identityCommitment0, mockProof);
    }

    /* release */

    function test_release_succeeds() public {
        // register first
        register(user0, identityCommitment0, messageLimit0);
        // withdraw user0
        // Make sure mock verifier always return true
        assertEq(verifier.result(), true);
        rln.withdraw(identityCommitment0, mockProof);

        // Test: release succeeds after freeze period
        uint256 blockNumbersToRelease = getUnfrozenBlockHeight();
        vm.roll(blockNumbersToRelease);
        uint256 user0BalanceBefore = token.balanceOf(user0);
        uint256 rlnBalanceBefore = token.balanceOf(address(rln));
        rln.release(identityCommitment0);
        uint256 user0BalanceDiff = token.balanceOf(user0) - user0BalanceBefore;
        uint256 rlnBalanceDiff = rlnBalanceBefore - token.balanceOf(address(rln));
        uint256 expectedUser0BalanceDiff = getRegisterAmount(messageLimit0);
        assertEq(user0BalanceDiff, expectedUser0BalanceDiff);
        assertEq(rlnBalanceDiff, expectedUser0BalanceDiff);
        checkUserIsDeleted(identityCommitment0);
    }

    function test_release_fails_when_no_withdrawal() public {
        // release fails
        vm.expectRevert("RLN, release: no such withdrawals");
        rln.release(identityCommitment0);
    }

    function test_release_fails_when_freeze_period() public {
        // register first
        register(user0, identityCommitment0, messageLimit0);
        // withdraw user0
        // Make sure mock verifier always return true
        assertEq(verifier.result(), true);
        rln.withdraw(identityCommitment0, mockProof);
        (uint256 blockNumber, uint256 amount, address receiver) = rln.withdrawals(identityCommitment0);
        assertEq(blockNumber, block.number);
        assertEq(amount, getRegisterAmount(messageLimit0));
        assertEq(receiver, user0);

        // Test: release fails in freeze period
        vm.expectRevert("RLN, release: cannot release yet");
        rln.release(identityCommitment0);

        uint256 blockNumbersToRelease = getUnfrozenBlockHeight();
        // release still fails
        vm.roll(blockNumbersToRelease - 1);
        vm.expectRevert("RLN, release: cannot release yet");
        rln.release(identityCommitment0);
    }

    /* slash */

    function test_slash_succeeds() public {
        // Test: register and get slashed
        register(user0, identityCommitment0, messageLimit0);
        uint256 registerAmount = getRegisterAmount(messageLimit0);
        uint256 slashFee = getSlashFee(registerAmount);
        uint256 slashReward = registerAmount - slashFee;
        uint256 slashedReceiverBalanceBefore = token.balanceOf(slashedReceiver);
        uint256 rlnBalanceBefore = token.balanceOf(address(rln));
        uint256 feeReceiverBalanceBefore = token.balanceOf(feeReceiver);
        rln.slash(identityCommitment0, slashedReceiver, mockProof);
        uint256 slashedReceiverBalanceDiff = token.balanceOf(slashedReceiver) - slashedReceiverBalanceBefore;
        uint256 rlnBalanceDiff = rlnBalanceBefore - token.balanceOf(address(rln));
        uint256 feeReceiverBalanceDiff = token.balanceOf(feeReceiver) - feeReceiverBalanceBefore;
        assertEq(slashedReceiverBalanceDiff, slashReward);
        assertEq(rlnBalanceDiff, registerAmount);
        assertEq(feeReceiverBalanceDiff, slashFee);
        // check user0 is slashed
        checkUserIsDeleted(identityCommitment0);

        // Test: register, withdraw, ang get slashed before release
        register(user1, identityCommitment1, messageLimit1);
        rln.withdraw(identityCommitment1, mockProof);
        rln.slash(identityCommitment1, slashedReceiver, mockProof);
        // check user1 is slashed
        checkUserIsDeleted(identityCommitment1);
    }

    function test_slash_fails_when_receiver_is_zero() public {
        // register first
        register(user0, identityCommitment0, messageLimit0);
        // slash user0
        vm.expectRevert("RLN, slash: empty receiver address");
        rln.slash(identityCommitment0, address(0), mockProof);
    }

    function test_slash_fails_when_not_registered() public {
        // slash fails
        vm.expectRevert("RLN, slash: member doesn't exist");
        rln.slash(identityCommitment0, slashedReceiver, mockProof);
    }

    function test_slash_fails_when_self_slashing() public {
        // register first
        register(user0, identityCommitment0, messageLimit0);
        // slash fails when receiver is the same as the registered msg.sender
        vm.expectRevert("RLN, slash: self-slashing is prohibited");
        rln.slash(identityCommitment0, user0, mockProof);
    }

    function test_slash_fails_when_invalid_proof() public {
        // register first
        register(user0, identityCommitment0, messageLimit0);
        // slash user0
        // Make sure mock verifier always return false
        verifier.changeResult(false);
        assertEq(verifier.result(), false);
        vm.expectRevert("RLN, slash: invalid proof");
        rln.slash(identityCommitment0, slashedReceiver, mockProof);
    }

    /* Helpers */
    function getRegisterAmount(uint256 messageLimit) public view returns (uint256) {
        return messageLimit * minimalDeposit;
    }

    function register(address user, uint256 identityCommitment, uint256 messageLimit) public {
        uint256 registerTokenAmount = getRegisterAmount(messageLimit);
        token.mint(user, registerTokenAmount);

        uint256 tokenRLNBefore = token.balanceOf(address(rln));
        uint256 tokenUserBefore = token.balanceOf(user);
        uint256 identityCommitmentIndexBefore = rln.identityCommitmentIndex();

        vm.startPrank(user);
        token.approve(address(rln), registerTokenAmount);
        rln.register(identityCommitment, registerTokenAmount);
        vm.stopPrank();

        uint256 tokenRLNDiff = token.balanceOf(address(rln)) - tokenRLNBefore;
        uint256 tokenUserDiff = tokenUserBefore - token.balanceOf(user);

        // rln state
        assertEq(rln.identityCommitmentIndex(), identityCommitmentIndexBefore + 1);
        assertEq(tokenRLNDiff, registerTokenAmount);
        // user state
        (address userAddress, uint256 actualMessageLimit, uint256 index) = rln.members(identityCommitment);
        assertEq(userAddress, user);
        assertEq(actualMessageLimit, messageLimit);
        assertEq(index, identityCommitmentIndexBefore);
        assertEq(tokenUserDiff, registerTokenAmount);
    }

    function getUnfrozenBlockHeight() public view returns (uint256) {
        return block.number + freezePeriod + 1;
    }

    function checkUserIsDeleted(uint256 identityCommitment) public {
        // user state
        (address userAddress, uint256 actualMessageLimit, uint256 index) = rln.members(identityCommitment);
        assertEq(userAddress, address(0));
        assertEq(actualMessageLimit, 0);
        assertEq(index, 0);
        // withdrawal state
        (uint256 blockNumber, uint256 amount, address receiver) = rln.withdrawals(identityCommitment);
        assertEq(blockNumber, 0);
        assertEq(amount, 0);
        assertEq(receiver, address(0));
    }

    function getSlashFee(uint256 registerAmount) public view returns (uint256) {
        return registerAmount * feePercentage / 100;
    }
}
