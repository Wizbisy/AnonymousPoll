// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

import {
    FHE,
    externalEuint64,
    externalEuint256,
    euint64,
    euint256
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

    uint256 public constant MAX_OPTIONS = 3;
    uint256 public constant MAX_COMMENTS_PER_USER = 1;

    struct Option {
        euint256 encryptedOption;
        euint256 encryptedOptionImageCID;
        euint64 encryptedVoteCount;
    }

    struct Poll {
        euint256 encryptedQuestion;
        euint256 encryptedQuestionImageCID;
        Option[] options;
        mapping(bytes32 => bool) hasVotedCommitment;
        mapping(bytes32 => euint64) userVotes;
        mapping(bytes32 => euint256[]) encryptedComments;
        address creator;
        bool isActive;
        bool revealed;
        bool commentsAllowed;
        uint256 startTime;
        uint256 endTime;
        uint64[] revealedVoteCounts;
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
    event VotesRevealed(uint256 indexed pollId);
    event EncryptedVoteCountForReveal(uint256 indexed pollId, uint256 indexed optionId, euint64 encryptedVoteCount);

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
        if (block.timestamp > p.endTime) {
            if (p.isActive) {
                p.isActive = false;
                emit PollClosed(pollId);
            }
            revert("Poll closed");
        }
        require(block.timestamp >= p.startTime, "Poll not started");
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

    function recoverStuckETH(address payable to) external onlyOwner nonReentrant {
        uint256 stuckAmount = address(this).balance - collectedFees;
        require(stuckAmount > 0, "No stuck ETH");
        (bool sent, ) = to.call{value: stuckAmount}("");
        require(sent, "Withdraw failed");
    }

    function createPoll(
        externalEuint256 encryptedQuestion,
        externalEuint256 encryptedQuestionImageCID,
        externalEuint256[] calldata encryptedOptions,
        externalEuint256[] calldata encryptedOptionImageCIDs,
        bytes calldata inputProof,
        bool commentsAllowed,
        uint256 startTime,
        uint256 endTime
    ) external payable whenNotPaused returns (uint256) {
        require(msg.value == pollCreationFee, "Incorrect fee");
        require(encryptedOptions.length == encryptedOptionImageCIDs.length, "Options mismatch");
        require(encryptedOptions.length >= 2 && encryptedOptions.length <= MAX_OPTIONS, "Invalid options count");
        require(startTime < endTime, "Invalid poll time");
        require(startTime >= block.timestamp, "Start time in past");

        collectedFees += msg.value;

        uint256 pollId = polls.length;
        polls.push();
        Poll storage p = polls[pollId];

        p.creator = msg.sender;
        p.encryptedQuestion = FHE.fromExternal(encryptedQuestion, inputProof);
        p.encryptedQuestionImageCID = FHE.fromExternal(encryptedQuestionImageCID, inputProof);
        p.isActive = true;
        p.revealed = false;
        p.commentsAllowed = commentsAllowed;
        p.startTime = startTime;
        p.endTime = endTime;

        FHE.allowThis(p.encryptedQuestion);
        FHE.allowThis(p.encryptedQuestionImageCID);

        for (uint256 i = 0; i < encryptedOptions.length; i++) {
            euint256 encOpt = FHE.fromExternal(encryptedOptions[i], inputProof);
            euint256 encCID = FHE.fromExternal(encryptedOptionImageCIDs[i], inputProof);
            p.options.push(Option({
                encryptedOption: encOpt,
                encryptedOptionImageCID: encCID,
                encryptedVoteCount: FHE.asEuint64(0)
            }));
            FHE.allowThis(encOpt);
            FHE.allowThis(encCID);
            FHE.allowThis(p.options[i].encryptedVoteCount);
        }

        pollsByCreator[msg.sender].push(pollId);

        emit PollCreated(pollId, msg.sender, commentsAllowed);
        return pollId;
    }

    function updatePollMetadata(
        uint256 pollId,
        externalEuint256 newEncryptedQuestion,
        externalEuint256 newEncryptedQuestionImageCID,
        bytes calldata inputProof
    ) external onlyCreator(pollId) pollActive(pollId) whenNotPaused {
        Poll storage p = polls[pollId];
        p.encryptedQuestion = FHE.fromExternal(newEncryptedQuestion, inputProof);
        p.encryptedQuestionImageCID = FHE.fromExternal(newEncryptedQuestionImageCID, inputProof);
        FHE.allowThis(p.encryptedQuestion);
        FHE.allowThis(p.encryptedQuestionImageCID);
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
        externalEuint256 encryptedComment,
        bytes calldata inputProof
    ) external pollActive(pollId) pollOpen(pollId) whenNotPaused {
        Poll storage p = polls[pollId];
        require(p.commentsAllowed, "Comments disabled");
        require(p.hasVotedCommitment[voterCommitment], "Must vote to comment");
        require(p.encryptedComments[voterCommitment].length < MAX_COMMENTS_PER_USER, "Max comments reached");

        euint256 encComment = FHE.fromExternal(encryptedComment, inputProof);
        FHE.allowThis(encComment);
        p.encryptedComments[voterCommitment].push(encComment);

        emit CommentSubmitted(pollId, voterCommitment);
    }

    function closePoll(uint256 pollId) external onlyCreator(pollId) {
        require(pollId < polls.length, "Invalid poll");
        Poll storage p = polls[pollId];
        require(p.isActive, "Already closed");
        p.isActive = false;
        emit PollClosed(pollId);
    }

    function revealVoteCounts(uint256 pollId) external onlyCreator(pollId) {
        Poll storage p = polls[pollId];
        require(block.timestamp > p.endTime, "Poll not ended");
        require(!p.revealed, "Already revealed");
        p.revealed = true;
        for (uint256 i = 0; i < p.options.length; i++) {
            emit EncryptedVoteCountForReveal(pollId, i, p.options[i].encryptedVoteCount);
        }
        emit VotesRevealed(pollId);
    }

    function submitRevealedVoteCounts(uint256 pollId, uint64[] calldata revealedCounts) external onlyCreator(pollId) {
        Poll storage p = polls[pollId];
        require(!p.revealed || p.revealedVoteCounts.length == 0, "Already revealed");
        require(revealedCounts.length == p.options.length, "Mismatched counts");
        for (uint256 i = 0; i < revealedCounts.length; i++) {
            p.revealedVoteCounts.push(revealedCounts[i]);
        }
        p.revealed = true;
        emit VotesRevealed(pollId);
    }

    function getEncryptedVoteCount(uint256 pollId, uint256 optionId) external view returns (euint64) {
        require(pollId < polls.length, "Invalid poll");
        Poll storage p = polls[pollId];
        require(optionId < p.options.length, "Invalid option");
        return p.options[optionId].encryptedVoteCount;
    }

    function getRevealedVoteCount(uint256 pollId, uint256 optionId) external view returns (uint64) {
        require(pollId < polls.length, "Invalid poll");
        Poll storage p = polls[pollId];
        require(p.revealed, "Not revealed");
        require(optionId < p.options.length, "Invalid option");
        return p.revealedVoteCounts[optionId];
    }

    function getEncryptedComment(uint256 pollId, bytes32 voterCommitment, uint256 commentIndex) external view returns (euint256) {
        require(pollId < polls.length, "Invalid poll");
        Poll storage p = polls[pollId];
        require(commentIndex < p.encryptedComments[voterCommitment].length, "Invalid comment index");
        return p.encryptedComments[voterCommitment][commentIndex];
    }

    function getEncryptedCommentsCount(uint256 pollId, bytes32 voterCommitment) external view returns (uint256) {
        require(pollId < polls.length, "Invalid poll");
        return polls[pollId].encryptedComments[voterCommitment].length;
    }

    function getPollsByCreator(address creator) external view returns (uint256[] memory) {
        return pollsByCreator[creator];
    }

    function getPollSummary(uint256 pollId) external view returns (
        bool isActive,
        bool revealed,
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
            p.revealed,
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
        if (start >= length) {
            return new uint256[](0);
        }

        uint256 end = start + count;
        if (end > length) end = length;

        uint256[] memory page = new uint256[](end - start);
        for (uint256 i = start; i < end; i++) {
            page[i - start] = creatorPolls[i];
        }
        return page;
    }

    function getEncryptedQuestion(uint256 pollId) external view returns (euint256) {
        require(pollId < polls.length, "Invalid poll");
        return polls[pollId].encryptedQuestion;
    }

    function getEncryptedQuestionImageCID(uint256 pollId) external view returns (euint256) {
        require(pollId < polls.length, "Invalid poll");
        return polls[pollId].encryptedQuestionImageCID;
    }

    function getEncryptedOption(uint256 pollId, uint256 optionId) external view returns (euint256) {
        require(pollId < polls.length, "Invalid poll");
        Poll storage p = polls[pollId];
        require(optionId < p.options.length, "Invalid option");
        return p.options[optionId].encryptedOption;
    }

    function getOptionEncryptedImageCID(uint256 pollId, uint256 optionId) external view returns (euint256) {
        require(pollId < polls.length, "Invalid poll");
        Poll storage p = polls[pollId];
        require(optionId < p.options.length, "Invalid option");
        return p.options[optionId].encryptedOptionImageCID;
    }
}