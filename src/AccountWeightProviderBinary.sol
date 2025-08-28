// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IAccountWeightProvider} from "src/interfaces/IAccountWeightProvider.sol";
import {IHub} from "src/interfaces/IHub.sol";

interface IEligibilityOrganization {
    function trust(address[] memory accounts, uint256[] memory weights)
        external
        returns (uint256 totalTrusted, uint256 totalUntrusted);
}

contract EligibilityOrganization {
    error OnlyAdmin();

    address public immutable ADMIN;
    /// @notice Circles v2 Hub.
    IHub public constant HUB = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));

    constructor() {
        ADMIN = msg.sender;
        HUB.registerOrganization("", bytes32(0));
    }

    function trust(address[] memory accounts, uint256[] memory weights)
        external
        returns (uint256 totalTrusted, uint256 totalUntrusted)
    {
        if (msg.sender != ADMIN) revert OnlyAdmin();
        for (uint256 i; i < accounts.length;) {
            bool alreadyTrusted = HUB.isTrusted(address(this), accounts[i]);

            if (weights[i] > 0 && !alreadyTrusted) {
                HUB.trust(accounts[i], type(uint96).max);
                ++totalTrusted;
            } else if (weights[i] == 0 && alreadyTrusted) {
                HUB.trust(accounts[i], uint96(0));
                ++totalUntrusted;
            }

            unchecked {
                ++i;
            }
        }
    }
}

contract AccountWeightProviderBinary is IAccountWeightProvider {
    struct OfferEligibility {
        uint256 totalAccounts;
        address eligibilityOrg;
        bool finalized;
    }
    /*//////////////////////////////////////////////////////////////
                             Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a function is called by a non-admin address.
    error OnlyAdmin();
    error LengthMismatch();
    error WeightsAlreadyFinalized();

    /*//////////////////////////////////////////////////////////////
                             Events
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                           Constants
    //////////////////////////////////////////////////////////////*/
    /// @notice Circles v2 Hub.
    IHub public constant HUB = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));
    uint256 internal constant ONE_IN_BASIS_POINTS = 10_000;
    address public immutable ADMIN;

    /*//////////////////////////////////////////////////////////////
                            Storage
    //////////////////////////////////////////////////////////////*/

    mapping(address offer => OfferEligibility) public offers;

    constructor(address admin) {
        ADMIN = admin;
    }

    // setting weight - 0 - not eligible, any other value - eligible
    function setAccountWeights(address offer, address[] memory accounts, uint256[] memory weights) external {
        if (msg.sender != ADMIN) revert OnlyAdmin();
        if (accounts.length != weights.length) revert LengthMismatch();

        OfferEligibility storage offerEligibility = offers[offer];
        if (offerEligibility.finalized) revert WeightsAlreadyFinalized();
        if (offerEligibility.eligibilityOrg == address(0)) {
            offerEligibility.eligibilityOrg = address(new EligibilityOrganization());
        }

        (uint256 totalTrusted, uint256 totalUntrusted) =
            IEligibilityOrganization(offerEligibility.eligibilityOrg).trust(accounts, weights);

        if (totalUntrusted > 0) offerEligibility.totalAccounts -= totalUntrusted;
        if (totalTrusted > 0) offerEligibility.totalAccounts += totalTrusted;
    }

    function getWeightScale() external pure returns (uint256) {
        return ONE_IN_BASIS_POINTS;
    }

    function getAccountWeight(address account) external view returns (uint256) {
        if (HUB.isTrusted(offers[msg.sender].eligibilityOrg, account)) return ONE_IN_BASIS_POINTS;
    }

    function getTotalWeight() external view returns (uint256) {
        return offers[msg.sender].totalAccounts * ONE_IN_BASIS_POINTS;
    }

    function getTotalAccounts() external view returns (uint256) {
        return offers[msg.sender].totalAccounts;
    }

    function finalizeWeights() external {
        offers[msg.sender].finalized = true;
        uint256 accountsCount = offers[msg.sender].totalAccounts;
        if (accountsCount > 0) emit WeightsFinalized(msg.sender, accountsCount, accountsCount * ONE_IN_BASIS_POINTS);
    }
}
