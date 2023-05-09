// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {IVerifier} from "./IVerifier.sol";

/// @title Rate-Limit Nullifier registry contract
/// @dev This contract allows you to register RLN commitment and withdraw/slash.
contract RLN is Ownable {
    using SafeERC20 for IERC20;

    /// @dev User metadata struct
    /// @param userAddress: address of depositor
    /// @param messageLimit: user's message limit (stakeAmount / MINIMAL_DEPOSIT)
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

    /// @dev Current index where pubkey will be stored.
    uint256 public pubkeyIndex = 0;

    /// @dev Registry set. The keys are `id_commitment`'s (or pubkey's).
    /// The values are addresses of accounts that call `register` transaction.
    mapping(uint256 => User) public members;

    /// @dev ERC20 Token used for staking.
    IERC20 public immutable token;

    /// @dev Groth16 verifier.
    IVerifier public immutable verifier;

    /// @dev Emmited when a new member registered.
    /// @param pubkey: pubkey or `id_commitment`;
    /// @param index: pubkeyIndex value;
    /// @param messageLimit: user's message limit.
    event MemberRegistered(uint256 pubkey, uint256 index, uint256 messageLimit);

    /// @dev Emmited when a member was slashed.
    /// @param pubkey: pubkey or `id_commitment`;
    /// @param slasher: address of slasher (msg.sender).
    event MemberSlashed(uint256 pubkey, address slasher);

    /// @dev Emmited when a member was withdrawn.
    /// @param pubkey: pubkey or `id_commitment`;
    event MemberWithdrawn(uint256 pubkey);

    /// @param minimalDeposit: Minimal membership deposit;
    /// @param depth: Depth of the merkle tree;
    /// @param feePercentage: Fee percentage;
    /// @param feeReceiver: Address of the fee receiver;
    /// @param _token: Address of the ERC20 contract;
    /// @param _verifier: Address of the Groth16 Verifier.
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

    /// @dev Adds `id_commitment` to the registry set and takes the necessary stake amount.
    ///
    /// NOTE: The set must not be full.
    ///
    /// @param pubkey: `id_commitment`.
    function register(uint256 pubkey, uint256 amount) external {
        require(pubkeyIndex < SET_SIZE, "RLN, register: set is full");
        require(amount >= MINIMAL_DEPOSIT, "RLN, register: amount is lower than minimal deposit");

        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 messageLimit = amount / MINIMAL_DEPOSIT;

        _register(pubkey, messageLimit);
    }

    /// @dev Add batch of pubkeys to the registry set.
    ///
    /// NOTE: The set must have enough space to store whole batch.
    ///
    /// @param pubkeys: Array of `id_commitment's`.
    function registerBatch(uint256[] calldata pubkeys, uint256[] calldata amounts) external {
        uint256 pubkeyLen = pubkeys.length;
        require(pubkeyLen != 0, "RLN, registerBatch: pubkeys array is empty");
        require(pubkeyLen == amounts.length, "RLN, registerBatch: invalid input");
        require(pubkeyIndex + pubkeyLen <= SET_SIZE, "RLN, registerBatch: set is full");

        for (uint256 i = 0; i < pubkeyLen; i++) {
            uint256 amount = amounts[i];
            require(amount >= MINIMAL_DEPOSIT, "RLN, registerBatch: amount is lower than minimal deposit");

            token.safeTransferFrom(msg.sender, address(this), amount);
            uint256 messageLimit = amount / MINIMAL_DEPOSIT;

            _register(pubkeys[i], messageLimit);
        }
    }

    /// @dev Internal register function. Sets the msg.sender as the value of the mapping.
    /// Doesn't allow duplicates.
    /// @param pubkey: `id_commitment`.
    function _register(uint256 pubkey, uint256 messageLimit) internal {
        require(members[pubkey].userAddress == address(0), "Pubkey already registered");

        members[pubkey] = User(msg.sender, messageLimit);
        emit MemberRegistered(pubkey, pubkeyIndex, messageLimit);

        pubkeyIndex += 1;
    }

    /// @dev Remove the pubkey from the registry (withdraw/slash).
    /// Transfer the entire stake to the receiver if they registered
    /// calculated pubkey, otherwise transfers `FEE` to the `FEE_RECEIVER`
    /// @param identityCommitment: `identityCommitment`;
    /// @param receiver: Stake receiver;
    /// @param proof: Snarkjs's format generated proof (without public inputs) packed consequently;
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
    /// @param feePercentage: New fee percentage.
    function changeFeePercentage(uint8 feePercentage) external onlyOwner {
        FEE_PERCENTAGE = feePercentage;
    }

    /// @dev Changes fee receiver.
    ///
    /// @param feeReceiver: New fee receiver.
    function changeFeeReceiver(address feeReceiver) external onlyOwner {
        FEE_RECEIVER = feeReceiver;
    }

    /// @dev Groth16 proof verification
    function _verifyProof(uint256 idCommitment, address receiver, uint256[8] calldata proof)
        internal
        view
        returns (bool)
    {
        return verifier.verifyProof(
            [proof[0], proof[1]],
            [[proof[2], proof[3]], [proof[4], proof[5]]],
            [proof[6], proof[7]],
            [idCommitment, uint256(uint160(receiver))]
        );
    }
}
