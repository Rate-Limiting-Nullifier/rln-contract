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

    /// @dev User metadata struct
    /// @param userAddress: address of depositor;
    /// @param messageLimit: user's message limit (stakeAmount / MINIMAL_DEPOSIT).
    struct User {
        address userAddress;
        uint256 messageLimit;
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

    /// @dev Current index where identityCommitment will be stored.
    uint256 public identityCommitmentIndex = 0;

    /// @dev Registry set. The keys are `identityCommitment`s.
    /// The values are addresses of accounts that call `register` transaction.
    mapping(uint256 => User) public members;

    /// @dev ERC20 Token used for staking.
    IERC20 public immutable token;

    /// @dev Groth16 verifier.
    IVerifier public immutable verifier;

    /// @dev Emmited when a new member registered.
    /// @param identityCommitment: `identityCommitment`;
    /// @param index: idCommitmentIndex value;
    /// @param messageLimit: user's message limit.
    event MemberRegistered(uint256 identityCommitment, uint256 index, uint256 messageLimit);

    /// @dev Emmited when a member was slashed.
    /// @param identityCommitment: `identityCommitment`;
    /// @param slasher: address of slasher (msg.sender).
    event MemberSlashed(uint256 identityCommitment, address slasher);

    /// @dev Emmited when a member was withdrawn.
    /// @param identityCommitment: `identityCommitment`;
    event MemberWithdrawn(uint256 identityCommitment);

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
        address _token,
        address _verifier
    ) {
        MINIMAL_DEPOSIT = minimalDeposit;
        DEPTH = depth;
        SET_SIZE = 1 << depth;

        FEE_PERCENTAGE = feePercentage;
        FEE_RECEIVER = feeReceiver;

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

        members[identityCommitment] = User(msg.sender, messageLimit);
        emit MemberRegistered(identityCommitment, identityCommitmentIndex, messageLimit);

        identityCommitmentIndex += 1;
    }

    /// @dev Remove the identityCommitment from the registry (withdraw/slash).
    /// Transfer the entire stake to the receiver if they registered
    /// calculated identityCommitment, otherwise transfers `FEE` to the `FEE_RECEIVER`
    /// @param identityCommitment: `identityCommitment`;
    /// @param receiver: stake receiver;
    /// @param proof: snarkjs's format generated proof (without public inputs) packed consequently.
    function withdraw(uint256 identityCommitment, address receiver, uint256[8] calldata proof) external {
        require(receiver != address(0), "RLN, withdraw: empty receiver address");

        User memory member = members[identityCommitment];
        require(member.userAddress != address(0), "Member doesn't exist");

        require(_verifyProof(identityCommitment, receiver, proof), "RLN, withdraw: invalid proof");

        delete members[identityCommitment];

        uint256 withdrawAmount = member.messageLimit * MINIMAL_DEPOSIT;

        // If memberAddress == receiver, then withdraw money without a fee
        if (member.userAddress == receiver) {
            token.safeTransfer(receiver, withdrawAmount);
            emit MemberWithdrawn(identityCommitment);
        } else {
            uint256 feeAmount = (FEE_PERCENTAGE * withdrawAmount) / 100;
            token.safeTransfer(receiver, withdrawAmount - feeAmount);
            token.safeTransfer(FEE_RECEIVER, feeAmount);
            emit MemberSlashed(identityCommitment, receiver);
        }
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
