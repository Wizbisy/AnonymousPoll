// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    FHE,
    externalEuint64,
    euint64
} from "@fhevm/solidity/lib/FHE.sol";
import { EthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract AnonymousPoll is EthereumConfig {
    uint256 public constant POLL_CREATION_FEE = 0.00001 ether;
    uint256 public collectedFees;
    address public owner;

    struct Option {
        bytes encryptedOption;
        string optionImageCID;
        euint64 encryptedVoteCount;
    }

    struct Poll {
        bytes encryptedQuestion;
        string questionImageCID;
        Option[] options;
        mapping(bytes32 => bool) hasVotedCommitment;
        mapping(bytes32 => euint64) userVotes;
        mapping(bytes32 => bytes[]) encryptedComments;
        address creator;
        bool isActive;
        bool commentsAllowed;
    }

    Poll[] private polls;
    mapping(address => uint256[]) private pollsByCreator;

    event PollCreated(uint256 indexed pollId, address indexed creator, bool commentsAllowed);
    event VoteCast(uint256 indexed pollId, bytes32 indexed voterCommitment, uint256 indexed optionId);
    event CommentSubmitted(uint256 indexed pollId, bytes32 indexed voterCommitment);
    event PollClosed(uint256 indexed pollId);
    event FeesWithdrawn(address indexed to, uint256 amount);

    modifier onlyCreator(uint256 pollId) {
        require(pollId < polls.length && polls[pollId].creator == msg.sender, "Not authorized");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier pollActive(uint256 pollId) {
        require(pollId < polls.length && polls[pollId].isActive, "Poll inactive");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function createPoll(
        bytes calldata encryptedQuestion,
        string calldata questionImageCID,
        bytes[] calldata encryptedOptions,
        string[] calldata optionImageCIDs,
        bool commentsAllowed
    ) external payable returns (uint256) {
        require(msg.value == POLL_CREATION_FEE, "Must pay poll creation fee");
        collectedFees += msg.value;
        require(encryptedOptions.length == optionImageCIDs.length, "Mismatched options/images");
        uint256 pollId = polls.length;
        polls.push();
        Poll storage p = polls[pollId];

        p.creator = msg.sender;
        p.encryptedQuestion = encryptedQuestion;
        p.questionImageCID = questionImageCID;
        p.isActive = true;
        p.commentsAllowed = commentsAllowed;

        for (uint256 i = 0; i < encryptedOptions.length; i++) {
            p.options.push(Option({
                encryptedOption: encryptedOptions[i],
                optionImageCID: optionImageCIDs[i],
                encryptedVoteCount: FHE.asEuint64(0)
            }));
            FHE.allowThis(p.options[i].encryptedVoteCount);
        }

        pollsByCreator[msg.sender].push(pollId);
        emit PollCreated(pollId, msg.sender, commentsAllowed);
        return pollId;
    }

    function vote(
        uint256 pollId,
        uint256 optionId,
        bytes32 voterCommitment,
        externalEuint64 encryptedWeight,
        bytes calldata inputProof
    ) external pollActive(pollId) {
        Poll storage p = polls[pollId];
        require(!p.hasVotedCommitment[voterCommitment], "Commitment voted");
        require(optionId < p.options.length, "Invalid option");

        euint64 weight = FHE.fromExternal(encryptedWeight, inputProof);
        p.options[optionId].encryptedVoteCount = FHE.add(p.options[optionId].encryptedVoteCount, weight);
        FHE.allowThis(p.options[optionId].encryptedVoteCount);

        p.hasVotedCommitment[voterCommitment] = true;
        p.userVotes[voterCommitment] = weight;

        emit VoteCast(pollId, voterCommitment, optionId);
    }

    function submitComment(
        uint256 pollId,
        bytes32 voterCommitment,
        bytes calldata encryptedComment
    ) external pollActive(pollId) {
        Poll storage p = polls[pollId];
        require(p.commentsAllowed, "Comments disabled");
        require(p.hasVotedCommitment[voterCommitment], "Must have voted");
        p.encryptedComments[voterCommitment].push(encryptedComment);
        emit CommentSubmitted(pollId, voterCommitment);
    }

    function closePoll(uint256 pollId) external onlyCreator(pollId) {
        polls[pollId].isActive = false;
        emit PollClosed(pollId);
    }

    function getEncryptedVoteCount(uint256 pollId, uint256 optionId) external view returns (euint64) {
        Poll storage p = polls[pollId];
        require(optionId < p.options.length, "Invalid option");
        return p.options[optionId].encryptedVoteCount;
    }

    function getEncryptedComments(uint256 pollId, bytes32 voterCommitment) external view returns (bytes[] memory) {
        Poll storage p = polls[pollId];
        return p.encryptedComments[voterCommitment];
    }

    function getPollsByCreator(address creator) external view returns (uint256[] memory) {
        return pollsByCreator[creator];
    }

    function withdrawFees(address payable to) external onlyOwner {
        require(collectedFees > 0, "No fees to withdraw");
        uint256 amount = collectedFees;
        collectedFees = 0;
        (bool sent, ) = to.call{value: amount}("");
        require(sent, "Withdraw failed");
        emit FeesWithdrawn(to, amount);
    }
}