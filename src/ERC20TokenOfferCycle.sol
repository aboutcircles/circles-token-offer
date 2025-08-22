// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20TokenOfferFactory} from "src/interfaces/IERC20TokenOfferFactory.sol";
import {IAccountScoreProvider} from "src/interfaces/IAccountScoreProvider.sol";
import {IERC20TokenOffer} from "src/interfaces/IERC20TokenOffer.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {LibString} from "solady/utils/LibString.sol";

contract ERC20TokenOfferCycle {
    error OnlyAdmin();

    IERC20TokenOfferFactory public immutable OFFER_FACTORY;
    address public immutable ADMIN;
    IAccountScoreProvider public immutable ACCOUNT_SCORE_PROVIDER;
    /// @notice Circles v2 Hub.
    IHub public constant HUB = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));

    address public immutable OFFER_TOKEN;
    uint256 public immutable OFFERS_START;
    uint256 public immutable OFFER_DURATION;

    string public offerOrgName;
    mapping(uint256 => IERC20TokenOffer) public offers;
    //uint256 public currentOffer;
    //address[] public acceptedIds;

    /*//////////////////////////////////////////////////////////////
                            Modifiers
    //////////////////////////////////////////////////////////////*/

    modifier onlyAdmin() {
        if (msg.sender != ADMIN) revert OnlyAdmin();
        _;
    }

    constructor(
        address admin,
        address accountScoreProvider,
        address offerToken,
        uint256 offersStart,
        uint256 offerDuration,
        string memory offerName,
        string memory orgName
    ) {
        OFFER_FACTORY = IERC20TokenOfferFactory(msg.sender);
        ADMIN = admin;
        ACCOUNT_SCORE_PROVIDER = IAccountScoreProvider(accountScoreProvider);
        OFFER_TOKEN = offerToken;
        OFFERS_START = offersStart;
        OFFER_DURATION = offerDuration;
        offerOrgName = offerName;

        // register an org
        HUB.registerOrganization(orgName, 0);
    }

    function currentOfferId() public view returns (uint256) {
        return ((block.timestamp - OFFERS_START) / OFFER_DURATION) + 1; 
    }

    // trusts until offer end - must be called by admin at midnight
    function createNextOffer(uint256 tokenPriceInCRC, uint256 offerLimitInCRC, address[] memory acceptedCRC) external onlyAdmin returns (address nextOffer) {
        uint256 currentId = currentOfferId();
        uint256 offerStart = currentId == 0 ? OFFERS_START : offers[currentId].OFFER_END();
        string memory offerName = string.concat(offerOrgName, "-", LibString.toString(currentId + 1));
        
        nextOffer = OFFER_FACTORY.createERC20TokenOffer(
            address(0),
            address(ACCOUNT_SCORE_PROVIDER),
            address(this),
            OFFER_TOKEN,
            tokenPriceInCRC,
            offerLimitInCRC,
            offerStart, // end of previous
            OFFER_DURATION,
            offerName, // standard + id
            acceptedCRC
        );

        offers[currentId + 1] = IERC20TokenOffer(nextOffer);
    }

    // TODO: all offer owner functions and score provider
}
