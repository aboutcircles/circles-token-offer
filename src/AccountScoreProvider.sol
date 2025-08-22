// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IAccountScoreProvider} from "src/interfaces/IAccountScoreProvider.sol";

contract AccountScoreProvider is IAccountScoreProvider {
    /*//////////////////////////////////////////////////////////////
                             Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a function is called by a non-admin address.
    error OnlyAdmin();
    error LengthMismatch();
    error ScoresFinalized();

    /*//////////////////////////////////////////////////////////////
                             Events
    //////////////////////////////////////////////////////////////*/

    event AccountScoreSet(address indexed offer, address indexed account, uint256 indexed score);

    //event OfferScoresFinalized(address indexed offer, uint256 indexed accountsCount, uint256 indexed totalScore);

    /*//////////////////////////////////////////////////////////////
                           Constants
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant ONE_IN_BASIS_POINTS = 10_000;
    address public immutable ADMIN;

    /*//////////////////////////////////////////////////////////////
                            Storage
    //////////////////////////////////////////////////////////////*/

    //mapping(address offer => uint256) public totalAccounts;
    mapping(address offer => uint256) public totalAccountScore;
    mapping(address offer => mapping(address account => uint256 score)) public accountScore;
    mapping(address offer => bool) public finalized;

    constructor(address admin) {
        ADMIN = admin;
    }

    // setting score - 0 - not eligible, ONE_IN_BASIS_POINTS - default; <ONE_IN_BASIS_POINTS> - multiplier
    function setAccountScores(address offer, address[] memory accounts, uint256[] memory scores) external {
        if (msg.sender != ADMIN) revert OnlyAdmin();
        if (finalized[offer]) revert ScoresFinalized();
        if (accounts.length != scores.length) revert LengthMismatch();
        uint256 totalScores;
        for (uint256 i; i < accounts.length;) {
            if (accountScore[offer][accounts[i]] != 0) totalAccountScore[offer] -= accountScore[offer][accounts[i]];
            accountScore[offer][accounts[i]] = scores[i];
            totalScores += scores[i];
            emit AccountScoreSet(offer, accounts[i], scores[i]);

            unchecked {
                ++i;
            }
        }
        totalAccountScore[offer] += totalScores;
    }

    function getScoreDenominator() external pure returns (uint256) {
        return ONE_IN_BASIS_POINTS;
    }

    function getAccountScore(address account) external view returns (uint256) {
        return accountScore[msg.sender][account];
    }

    function getTotalAccountScore() external view returns (uint256) {
        return totalAccountScore[msg.sender];
    }

    function finalizeScores() external {
        finalized[msg.sender] = true;
        // allows indexer spamming
        //emit OfferScoresFinalized(msg.sender, totalAccounts[msg.sender], totalAccountScore[msg.sender]);
    }
}
