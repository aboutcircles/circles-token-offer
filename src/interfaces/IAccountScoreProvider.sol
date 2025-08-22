// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

interface IAccountScoreProvider {
    function getScoreDenominator() external view returns (uint256);
    function getAccountScore(address account) external view returns (uint256 tier);
    function getTotalAccountScore() external view returns (uint256);
    function finalizeScores() external;
}
