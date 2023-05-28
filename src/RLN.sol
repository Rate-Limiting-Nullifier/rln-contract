// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {IVerifier} from "./IVerifier.sol";

/// @title Rate-Limiting Nullifier registry contract
/// @dev This contract allows you to register RLN commitment and withdraw/slash.
contract RLN is Ownable {
    using SafeERC20 for IERC20;

    /// @dev User metadata struct.
    /// @param userAddress: address of depositor;
    /// @param messageLimit: user's message limit (stakeAmount / MINIMAL_DEPOSIT).
    struct User {
        address userAddress;
        uint256 messageLimit;
        uint256 index;
    }

    /// @dev Withdrawal time-lock struct
    /// @param blockNumber: number of block when a withdraw was initialized;
    /// @param messageLimit: amount of tokens to freeze/release;
    /// @param receiver: address of receiver.
    struct Withdrawal {
        uint256 blockNumber;
        uint256 amount;
        address receiver;
    }

    /// @dev Minimal membership deposit (stake amount) value - cost of 1 message.
    uint256 public immutable MINIMAL_DEPOSIT;

    /// @dev Depth of the Merkle Tree. Registry set is the size of 1 << DEPTH.
    uint256 public immutable DEPTH;

    /// @dev Registry set size (1 << DEPTH).
    uint256 public immutable SET_SIZE;

    /// @dev Address of the fee receiver.
    address public FEE_RECEIVER;

    /// @dev Fee percentage.
    uint8 public FEE_PERCENTAGE;

    /// @dev Freeze period - number of blocks for which the withdrawal of money is frozen.
    uint256 public FREEZE_PERIOD;

    /// @dev Current index where identityCommitment will be stored.
    uint256 public identityCommitmentIndex = 0;

    /// @dev Registry set. The keys are `identityCommitment`s.
    /// The values are addresses of accounts that call `register` transaction.
    mapping(uint256 => User) public members;

    /// @dev Withdrawals logic.
    mapping(uint256 => Withdrawal) public withdrawals;

    /// @dev ERC20 Token used for staking.
    IERC20 public immutable token;

    /// @dev Groth16 verifier.
    IVerifier public immutable verifier;

    /// @dev Emmited when a new member registered.
    /// @param identityCommitment: `identityCommitment`;
    /// @param messageLimit: user's message limit;
    /// @param index: idCommitmentIndex value.
    event MemberRegistered(uint256 identityCommitment, uint256 messageLimit, uint256 index);

    /// @dev Emmited when a member was withdrawn.
    /// @param index: index of `identityCommitment`;
    event MemberWithdrawn(uint256 index);

    /// @dev Emmited when a member was slashed.
    /// @param index: index of `identityCommitment`;
    /// @param slasher: address of slasher (msg.sender).
    event MemberSlashed(uint256 index, address slasher);

    /// @param minimalDeposit: minimal membership deposit;
    /// @param depth: depth of the merkle tree;
    /// @param feePercentage: fee percentage;
    /// @param feeReceiver: address of the fee receiver;
    /// @param _token: address of the ERC20 contract;
    /// @param _verifier: address of the Groth16 Verifier.
    constructor(
        uint256 minimalDeposit,
        uint256 depth,
        uint8 feePercentage,
        address feeReceiver,
        uint256 freezePeriod,
        address _token,
        address _verifier
    ) {
        MINIMAL_DEPOSIT = minimalDeposit;
        DEPTH = depth;
        SET_SIZE = 1 << depth;

        FEE_PERCENTAGE = feePercentage;
        FEE_RECEIVER = feeReceiver;
        FREEZE_PERIOD = freezePeriod;

        token = IERC20(_token);
        verifier = IVerifier(_verifier);
    }

    /// @dev Adds `identityCommitment` to the registry set and takes the necessary stake amount.
    ///
    /// NOTE: The set must not be full.
    ///
    /// @param identityCommitment: `identityCommitment`;
    /// @param amount: stake amount.
    function register(uint256 identityCommitment, uint256 amount) external {
        require(identityCommitmentIndex < SET_SIZE, "RLN, register: set is full");
        require(amount >= MINIMAL_DEPOSIT, "RLN, register: amount is lower than minimal deposit");
        require(members[identityCommitment].userAddress == address(0), "RLN, register: idCommitment already registered");

        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 messageLimit = amount / MINIMAL_DEPOSIT;

        members[identityCommitment] = User(msg.sender, messageLimit, identityCommitmentIndex);
        emit MemberRegistered(identityCommitment, messageLimit, identityCommitmentIndex);

        identityCommitmentIndex += 1;
    }

    /// @dev Request for withdraw and freeze the stake to prevent self-slashing. Stake can be
    /// released after FREEZE_PERIOD blocks.
    /// @param identityCommitment: `identityCommitment`;
    /// @param proof: snarkjs's format generated proof (without public inputs) packed consequently.
    function withdraw(uint256 identityCommitment, uint256[8] calldata proof) external {
        User memory member = members[identityCommitment];
        require(member.userAddress != address(0), "RLN, withdraw: member doesn't exist");
        require(withdrawals[identityCommitment].blockNumber == 0, "RLN, release: such withdrawal exists");
        require(_verifyProof(identityCommitment, member.userAddress, proof), "RLN, withdraw: invalid proof");

        uint256 withdrawAmount = member.messageLimit * MINIMAL_DEPOSIT;
        withdrawals[identityCommitment] = Withdrawal(block.number, withdrawAmount, member.userAddress);
        emit MemberWithdrawn(member.index);
    }

    /// @dev Releases stake amount.
    /// @param identityCommitment: `identityCommitment` of withdrawn user.
    function release(uint256 identityCommitment) external {
        Withdrawal memory withdrawal = withdrawals[identityCommitment];
        require(withdrawal.blockNumber != 0, "RLN, release: no such withdrawals");
        require(block.number - withdrawal.blockNumber > FREEZE_PERIOD, "RLN, release: cannot release yet");

        delete withdrawals[identityCommitment];
        delete members[identityCommitment];

        token.safeTransfer(withdrawal.receiver, withdrawal.amount);
    }

    /// @dev Slashes identity with identityCommitment.
    /// @param identityCommitment: `identityCommitment`;
    /// @param receiver: stake receiver;
    /// @param proof: snarkjs's format generated proof (without public inputs) packed consequently.
    function slash(uint256 identityCommitment, address receiver, uint256[8] calldata proof) external {
        require(receiver != address(0), "RLN, withdraw: empty receiver address");

        User memory member = members[identityCommitment];
        require(member.userAddress != address(0), "Member doesn't exist");

        require(_verifyProof(identityCommitment, receiver, proof), "RLN, withdraw: invalid proof");

        delete members[identityCommitment];
        delete withdrawals[identityCommitment];

        uint256 withdrawAmount = member.messageLimit * MINIMAL_DEPOSIT;
        uint256 feeAmount = (FEE_PERCENTAGE * withdrawAmount) / 100;

        token.safeTransfer(receiver, withdrawAmount - feeAmount);
        token.safeTransfer(FEE_RECEIVER, feeAmount);
        emit MemberSlashed(member.index, receiver);
    }

    /// @dev Changes fee percentage.
    ///
    /// @param feePercentage: new fee percentage.
    function changeFeePercentage(uint8 feePercentage) external onlyOwner {
        FEE_PERCENTAGE = feePercentage;
    }

    /// @dev Changes fee receiver.
    ///
    /// @param feeReceiver: new fee receiver.
    function changeFeeReceiver(address feeReceiver) external onlyOwner {
        FEE_RECEIVER = feeReceiver;
    }

    /// @dev Changes freeze period.
    ///
    /// @param freezePeriod: new freeze period.
    function changeFreezePeriod(uint256 freezePeriod) external onlyOwner {
        FREEZE_PERIOD = freezePeriod;
    }

    /// @dev Groth16 proof verification
    function _verifyProof(uint256 identityCommitment, address receiver, uint256[8] calldata proof)
        internal
        view
        returns (bool)
    {
        return verifier.verifyProof(
            [proof[0], proof[1]],
            [[proof[2], proof[3]], [proof[4], proof[5]]],
            [proof[6], proof[7]],
            [identityCommitment, uint256(uint160(receiver))]
        );
    }
}