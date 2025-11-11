// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

import {
    FHE,
    externalEuint64,
    euint64
} from "@fhevm/solidity/lib/FHE.sol";
import { EthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract AnonymousPoll is EthereumConfig, ReentrancyGuard {
    address public owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    bool public paused;
    event Paused();
    event Unpaused();

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract paused");
        _;
    }

    uint256 public pollCreationFee;
    uint256 public collectedFees;

    struct Option {
        bytes encryptedOption;
        bytes encryptedOptionImageCID;
        euint64 encryptedVoteCount;
    }

    struct Poll {
        bytes encryptedQuestion;
        bytes encryptedQuestionImageCID;
        Option[] options;
        mapping(bytes32 => bool) hasVotedCommitment;
        mapping(bytes32 => euint64) userVotes;
        mapping(bytes32 => bytes[]) encryptedComments;
        address creator;
        bool isActive;
        bool commentsAllowed;
        uint256 startTime;
        uint256 endTime;
    }

    Poll[] private polls;
    mapping(address => uint256[]) private pollsByCreator;

    event PollCreated(uint256 indexed pollId, address indexed creator, bool commentsAllowed);
    event PollClosed(uint256 indexed pollId);
    event VoteCast(uint256 indexed pollId, bytes32 indexed voterCommitment, uint256 indexed optionId);
    event CommentSubmitted(uint256 indexed pollId, bytes32 indexed voterCommitment);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event PollMetadataUpdated(uint256 indexed pollId);
    event PollCreationFeeUpdated(uint256 newFee);

    modifier onlyCreator(uint256 pollId) {
        require(pollId < polls.length && polls[pollId].creator == msg.sender, "Not authorized");
        _;
    }

    modifier pollActive(uint256 pollId) {
        require(pollId < polls.length && polls[pollId].isActive, "Poll inactive");
        _;
    }

    modifier pollOpen(uint256 pollId) {
        require(pollId < polls.length, "Invalid poll");
        Poll storage p = polls[pollId];
        require(block.timestamp >= p.startTime && block.timestamp <= p.endTime, "Poll closed");
        _;
    }

    constructor() {
        owner = msg.sender;
        pollCreationFee = 0.00001 ether;
        emit OwnershipTransferred(address(0), owner);
    }

    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "New owner zero");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused();
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused();
    }

    function setPollCreationFee(uint256 newFee) external onlyOwner {
        pollCreationFee = newFee;
        emit PollCreationFeeUpdated(newFee);
    }

    function withdrawFees(address payable to) external onlyOwner nonReentrant {
        require(collectedFees > 0, "No fees");
        uint256 amount = collectedFees;
        collectedFees = 0;
        
        (bool sent, ) = to.call{value: amount}("");
        require(sent, "Withdraw failed");
        emit FeesWithdrawn(to, amount);
    }

    function recoverERC20(address tokenAddress, uint256 amount) external onlyOwner {
        SafeERC20.safeTransfer(IERC20(tokenAddress), owner, amount);
    }

    function createPoll(
        bytes calldata encryptedQuestion,
        bytes calldata encryptedQuestionImageCID,
        bytes[] calldata encryptedOptions,
        bytes[] calldata encryptedOptionImageCIDs,
        bool commentsAllowed,
        uint256 startTime,
        uint256 endTime
    ) external payable whenNotPaused returns (uint256) {
        require(msg.value == pollCreationFee, "Incorrect fee");
        require(encryptedOptions.length == encryptedOptionImageCIDs.length, "Options mismatch");
        require(encryptedOptions.length >= 2, "Need at least 2 options");
        require(startTime < endTime, "Invalid poll time");
        require(startTime >= block.timestamp, "Start time in past");

        collectedFees += msg.value;

        uint256 pollId = polls.length;
        polls.push();
        Poll storage p = polls[pollId];

        p.creator = msg.sender;
        p.encryptedQuestion = encryptedQuestion;
        p.encryptedQuestionImageCID = encryptedQuestionImageCID;
        p.isActive = true;
        p.commentsAllowed = commentsAllowed;
        p.startTime = startTime;
        p.endTime = endTime;

        for (uint256 i = 0; i < encryptedOptions.length; i++) {
            p.options.push(Option({
                encryptedOption: encryptedOptions[i],
                encryptedOptionImageCID: encryptedOptionImageCIDs[i],
                encryptedVoteCount: FHE.asEuint64(0)
            }));
            FHE.allowThis(p.options[i].encryptedVoteCount);
        }

        pollsByCreator[msg.sender].push(pollId);

        emit PollCreated(pollId, msg.sender, commentsAllowed);
        return pollId;
    }

    function updatePollMetadata(
        uint256 pollId,
        bytes calldata newEncryptedQuestion,
        bytes calldata newEncryptedQuestionImageCID
    ) external onlyCreator(pollId) pollActive(pollId) whenNotPaused {
        Poll storage p = polls[pollId];
        p.encryptedQuestion = newEncryptedQuestion;
        p.encryptedQuestionImageCID = newEncryptedQuestionImageCID;
        emit PollMetadataUpdated(pollId);
    }

    function vote(
        uint256 pollId,
        uint256 optionId,
        bytes32 voterCommitment,
        externalEuint64 encryptedWeight,
        bytes calldata inputProof
    ) external pollActive(pollId) pollOpen(pollId) whenNotPaused {
        Poll storage p = polls[pollId];
        require(!p.hasVotedCommitment[voterCommitment], "Already voted");
        require(optionId < p.options.length, "Invalid option");

        euint64 weight = FHE.fromExternal(encryptedWeight, inputProof);
        p.options[optionId].encryptedVoteCount = FHE.add(p.options[optionId].encryptedVoteCount, weight);

        p.hasVotedCommitment[voterCommitment] = true;
        p.userVotes[voterCommitment] = weight;

        emit VoteCast(pollId, voterCommitment, optionId);
    }

    function submitComment(
        uint256 pollId,
        bytes32 voterCommitment,
        bytes calldata encryptedComment
    ) external pollActive(pollId) pollOpen(pollId) whenNotPaused {
        Poll storage p = polls[pollId];
        require(p.commentsAllowed, "Comments disabled");
        require(p.hasVotedCommitment[voterCommitment], "Must vote to comment");
        require(encryptedComment.length > 0, "Empty comment");
        p.encryptedComments[voterCommitment].push(encryptedComment);
        emit CommentSubmitted(pollId, voterCommitment);
    }

    function closePoll(uint256 pollId) external onlyCreator(pollId) {
        require(pollId < polls.length, "Invalid poll");
        polls[pollId].isActive = false;
        emit PollClosed(pollId);
    }

    function getEncryptedVoteCount(uint256 pollId, uint256 optionId) external view returns (euint64) {
        require(pollId < polls.length, "Invalid poll");
        Poll storage p = polls[pollId];
        require(optionId < p.options.length, "Invalid option");
        return p.options[optionId].encryptedVoteCount;
    }

    function getEncryptedComments(uint256 pollId, bytes32 voterCommitment) external view returns (bytes[] memory) {
        require(pollId < polls.length, "Invalid poll");
        return polls[pollId].encryptedComments[voterCommitment];
    }

    function getPollsByCreator(address creator) external view returns (uint256[] memory) {
        return pollsByCreator[creator];
    }

    function getPollSummary(uint256 pollId) external view returns (
        bool isActive,
        bool commentsAllowed,
        uint256 optionsCount,
        uint256 startTime,
        uint256 endTime,
        address creator
    ) {
        require(pollId < polls.length, "Invalid poll");
        Poll storage p = polls[pollId];
        return (
            p.isActive,
            p.commentsAllowed,
            p.options.length,
            p.startTime,
            p.endTime,
            p.creator
        );
    }

    function isPollCreator(uint256 pollId, address user) external view returns (bool) {
        if (pollId >= polls.length) return false;
        return polls[pollId].creator == user;
    }

    function totalPolls() external view returns (uint256) {
        return polls.length;
    }

    function pollsByCreatorCount(address creator) external view returns (uint256) {
        return pollsByCreator[creator].length;
    }

    function getPollsByCreatorPaged(address creator, uint256 start, uint256 count) external view returns (uint256[] memory) {
        uint256[] storage creatorPolls = pollsByCreator[creator];
        uint256 length = creatorPolls.length;
        if (start >= length) return new uint256[](0);

        uint256 end = start + count;
        if (end > length) end = length;

        uint256[] memory page = new uint256[](end - start);
        for (uint256 i = start; i < end; i++) {
            page[i - start] = creatorPolls[i];
        }
        return page;
    }

    function getEncryptedQuestionImageCID(uint256 pollId) external view returns (bytes memory) {
        require(pollId < polls.length, "Invalid poll");
        return polls[pollId].encryptedQuestionImageCID;
    }

    function getOptionEncryptedImageCID(uint256 pollId, uint256 optionId) external view returns (bytes memory) {
        require(pollId < polls.length, "Invalid poll");
        Poll storage p = polls[pollId];
        require(optionId < p.options.length, "Invalid option");
        return p.options[optionId].encryptedOptionImageCID;
    }
}
