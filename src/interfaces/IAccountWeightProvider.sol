// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

/// @notice Provides per-account eligibility weights.
/// Weights are integers measured in units of `getWeightScale()`.
/// - 0          => ineligible
/// - Binary impls: weight ∈ {0, getWeightScale()}
/// - Graded impls: weight ∈ [0, ∞); MAY exceed getWeightScale() (e.g., boosts > 100%).
interface IAccountWeightProvider {
    event WeightsFinalized(address indexed offer, uint256 indexed accountsCount, uint256 indexed totalWeight);

    function getWeightScale() external view returns (uint256);

    // Reads scoped to calling offer (msg.sender)
    function getAccountWeight(address account) external view returns (uint256 weight);
    function getTotalWeight() external view returns (uint256 total);
    function getTotalAccounts() external view returns (uint256);

    // Admin writes / lifecycle
    function setAccountWeights(address offer, address[] memory accounts, uint256[] memory weights) external;
    function finalizeWeights() external;
}
