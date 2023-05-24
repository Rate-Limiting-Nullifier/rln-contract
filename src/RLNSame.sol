// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {IVerifier} from "./IVerifier.sol";

/// @title Rate-Limiting Nullifier registry contract
/// @dev This contract allows you to register RLN identityCommitment and withdraw/slash.
contract RLN is Ownable {
    using SafeERC20 for IERC20;

    /// @dev Membership deposit (stake amount) value.
    uint256 public immutable MEMBERSHIP_DEPOSIT;

    /// @dev Depth of the Merkle Tree. Registry set is the size of 1 << DEPTH.
    uint256 public immutable DEPTH;

    /// @dev Registry set size (1 << DEPTH).
    uint256 public immutable SET_SIZE;

    /// @dev Address of the fee receiver.
    address public FEE_RECEIVER;

    /// @dev Fee percentage.
    uint8 public FEE_PERCENTAGE;

    /// @dev Fee amount.
    uint256 public FEE_AMOUNT;

    /// @dev Current index where `identityCommitment` will be stored.
    uint256 public identityCommitmentIndex = 0;

    /// @dev Registry set. The keys are `identityCommitment`s.
    /// The values are addresses of accounts that call `register` transaction.
    mapping(uint256 => address) public members;

    /// @dev ERC20 token used for staking.
    IERC20 public immutable token;

    /// @dev Groth16 verifier.
    IVerifier public immutable verifier;

    /// @dev Emmited when a new member registered.
    /// @param identityCommitment: `identityCommitment`;
    /// @param index: identityCommitmentIndex value.
    event MemberRegistered(uint256 identityCommitment, uint256 index);

    /// @dev Emmited when a member was slashed.
    /// @param identityCommitment: `identityCommitment`;
    /// @param slasher: address of slasher (msg.sender).
    event MemberSlashed(uint256 identityCommitment, address slasher);

    /// @dev Emmited when a member was withdrawn.
    /// @param identityCommitment: `identityCommitment`;
    event MemberWithdrawn(uint256 identityCommitment);

    /// @param membershipDeposit: membership deposit;
    /// @param depth: depth of the merkle tree;
    /// @param feePercentage: fee percentage;
    /// @param feeReceiver: address of the fee receiver;
    /// @param _token: address of the ERC20 contract;
    /// @param _verifier: address of the Groth16 Verifier.
    constructor(
        uint256 membershipDeposit,
        uint256 depth,
        uint8 feePercentage,
        address feeReceiver,
        address _token,
        address _verifier
    ) {
        MEMBERSHIP_DEPOSIT = membershipDeposit;
        DEPTH = depth;
        SET_SIZE = 1 << depth;

        FEE_PERCENTAGE = feePercentage;
        FEE_RECEIVER = feeReceiver;
        FEE_AMOUNT = (FEE_PERCENTAGE * MEMBERSHIP_DEPOSIT) / 100;

        token = IERC20(_token);
        verifier = IVerifier(_verifier);
    }

    /// @dev Adds `identityCommitment` to the registry set and takes the necessary stake amount.
    ///
    /// NOTE: The set must not be full.
    ///
    /// @param identityCommitment: `identityCommitment`.
    function register(uint256 identityCommitment) external {
        require(identityCommitmentIndex < SET_SIZE, "RLN, register: set is full");

        token.safeTransferFrom(msg.sender, address(this), MEMBERSHIP_DEPOSIT);
        _register(identityCommitment);
    }

    /// @dev Add batch of `identityCommitment`s to the registry set.
    ///
    /// NOTE: The set must have enough space to store whole batch.
    ///
    /// @param identityCommitments: array of `identityCommitment`s.
    function registerBatch(uint256[] calldata identityCommitments) external {
        uint256 len = identityCommitments.length;
        require(len != 0, "RLN, registerBatch: idCommitments array is empty");
        require(identityCommitmentIndex + len <= SET_SIZE, "RLN, registerBatch: set is full");

        token.safeTransferFrom(msg.sender, address(this), MEMBERSHIP_DEPOSIT * len);
        for (uint256 i = 0; i < len; i++) {
            _register(identityCommitments[i]);
        }
    }

    /// @dev Internal register function. Sets the msg.sender as the value of the mapping.
    /// Doesn't allow duplicates.
    /// @param identityCommitment: `identityCommitment`.
    function _register(uint256 identityCommitment) internal {
        require(members[identityCommitment] == address(0), "idCommitment already registered");

        members[identityCommitment] = msg.sender;
        emit MemberRegistered(identityCommitment, identityCommitmentIndex);

        identityCommitmentIndex += 1;
    }

    /// @dev Remove the identityCommitment from the registry (withdraw/slash).
    /// Transfer the entire stake to the receiver if they registered the
    /// identityCommitment, otherwise transfers fee to the fee receiver
    /// @param identityCommitment: `identityCommitment`;
    /// @param receiver: stake receiver;
    /// @param proof: snarkjs's format generated proof (without public inputs) packed consequently.
    function withdraw(uint256 identityCommitment, address receiver, uint256[8] calldata proof) external {
        require(receiver != address(0), "RLN, withdraw: empty receiver address");

        address memberAddress = members[identityCommitment];
        require(memberAddress != address(0), "Member doesn't exist");

        require(_verifyProof(identityCommitment, receiver, proof), "RLN, withdraw: invalid proof");

        delete members[identityCommitment];

        // If memberAddress == receiver, then withdraw money without a fee
        if (memberAddress == receiver) {
            token.safeTransfer(receiver, MEMBERSHIP_DEPOSIT);
            emit MemberWithdrawn(identityCommitment);
        } else {
            token.safeTransfer(receiver, MEMBERSHIP_DEPOSIT - FEE_AMOUNT);
            token.safeTransfer(FEE_RECEIVER, FEE_AMOUNT);
            emit MemberSlashed(identityCommitment, receiver);
        }
    }

    /// @dev Changes fee percentage.
    ///
    /// @param feePercentage: new fee percentage.
    function changeFeePercentage(uint8 feePercentage) external onlyOwner {
        FEE_PERCENTAGE = feePercentage;
        FEE_AMOUNT = (FEE_PERCENTAGE * MEMBERSHIP_DEPOSIT) / 100;
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
