// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC20TokenOfferFactory} from "src/interfaces/IERC20TokenOfferFactory.sol";
import {IAccountWeightProvider} from "src/interfaces/IAccountWeightProvider.sol";
import {IERC20TokenOffer} from "src/interfaces/IERC20TokenOffer.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {LibString} from "solady/utils/LibString.sol";

contract ERC20TokenOfferCycle {
    error OnlyAdmin();
    error OnlyHub();
    /*//////////////////////////////////////////////////////////////
                             Events
    //////////////////////////////////////////////////////////////*/

    event NextOfferCreated(
        address indexed nextOffer,
        uint256 indexed tokenPriceInCRC,
        uint256 indexed offerLimitInCRC,
        address[] acceptedCRC
    );

    IERC20TokenOfferFactory public immutable OFFER_FACTORY;
    address public immutable ADMIN;
    IAccountWeightProvider public immutable ACCOUNT_WEIGHT_PROVIDER;
    /// @notice Circles v2 Hub.
    IHub public constant HUB = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));

    address public immutable OFFER_TOKEN;
    uint256 public immutable OFFERS_START;
    uint256 public immutable OFFER_DURATION;

    string public offerOrgName;
    mapping(uint256 => IERC20TokenOffer) public offers;
    mapping(uint256 => address[]) public acceptedCRC;

    /*//////////////////////////////////////////////////////////////
                            Modifiers
    //////////////////////////////////////////////////////////////*/

    modifier onlyAdmin() {
        if (msg.sender != ADMIN) revert OnlyAdmin();
        _;
    }

    modifier onlyHub() {
        if (msg.sender != address(HUB)) revert OnlyHub();
        _;
    }

    constructor(
        address accountWeightProvider,
        address admin,
        address offerToken,
        uint256 offersStart,
        uint256 offerDuration,
        string memory offerName,
        string memory orgName
    ) {
        OFFER_FACTORY = IERC20TokenOfferFactory(msg.sender);
        ACCOUNT_WEIGHT_PROVIDER = IAccountWeightProvider(accountWeightProvider);
        ADMIN = admin;
        OFFER_TOKEN = offerToken;
        OFFERS_START = offersStart;
        OFFER_DURATION = offerDuration;
        offerOrgName = offerName;

        // register an org
        HUB.registerOrganization(orgName, 0);
    }

    function currentOfferId() public view returns (uint256) {
        if (block.timestamp < OFFERS_START) return 0;
        return ((block.timestamp - OFFERS_START) / OFFER_DURATION) + 1;
    }

    function currentOffer() public view returns (IERC20TokenOffer offer) {
        offer = offers[currentOfferId()];
    }

    function createNextOffer(uint256 tokenPriceInCRC, uint256 offerLimitInCRC, address[] memory _acceptedCRC)
        external
        onlyAdmin
        returns (address nextOffer)
    {
        uint256 currentId = currentOfferId();
        uint256 offerStart = OFFERS_START + (OFFER_DURATION * currentId);

        string memory offerName = string.concat(offerOrgName, "-", LibString.toString(currentId + 1));

        nextOffer = OFFER_FACTORY.createERC20TokenOffer(
            address(ACCOUNT_WEIGHT_PROVIDER),
            address(this),
            OFFER_TOKEN,
            tokenPriceInCRC,
            offerLimitInCRC,
            offerStart, // end of previous
            OFFER_DURATION,
            offerName, // standard + id
            _acceptedCRC
        );

        offers[currentId + 1] = IERC20TokenOffer(nextOffer);
        acceptedCRC[currentId + 1] = _acceptedCRC;

        emit NextOfferCreated(nextOffer, tokenPriceInCRC, offerLimitInCRC, _acceptedCRC);
    }

    function syncOfferTrust() external {
        uint256 currentId = currentOfferId();
        uint96 offerEnd = uint96(OFFERS_START + (OFFER_DURATION * currentId));
        address[] memory trustReceivers = acceptedCRC[currentId];

        for (uint256 i; i < trustReceivers.length;) {
            HUB.trust(trustReceivers[i], offerEnd);
            unchecked {
                ++i;
            }
        }
    }

    // offer functions
    function isOfferAvailable() external view returns (bool) {
        return currentOffer().isOfferAvailable();
    }

    function isAccountEligible(address account) external view returns (bool) {
        return currentOffer().isAccountEligible(account);
    }

    function getAccountOfferLimit(address account) public view returns (uint256) {
        return currentOffer().getAccountOfferLimit(account);
    }

    function getAvailableAccountOfferLimit(address account) external view returns (uint256) {
        return currentOffer().getAvailableAccountOfferLimit(account);
    }

    function getNextOfferAndRequiredTokenAmount()
        public
        view
        returns (IERC20TokenOffer nextOffer, uint256 requiredTokenAmount)
    {
        nextOffer = offers[currentOfferId() + 1];
        requiredTokenAmount = nextOffer.getRequiredOfferTokenAmount();
    }

    /// requires token pre-approval
    function depositNextOfferTokens() external onlyAdmin {
        (IERC20TokenOffer nextOffer, uint256 requiredAmount) = getNextOfferAndRequiredTokenAmount();
        IERC20(OFFER_TOKEN).transferFrom(ADMIN, address(this), requiredAmount);
        IERC20(OFFER_TOKEN).approve(address(nextOffer), requiredAmount);

        nextOffer.depositOfferTokens();
    }

    function withdrawUnclaimedOfferTokens(uint256 offerId) external onlyAdmin {
        IERC20TokenOffer offer = offers[offerId];
        uint256 amount = offer.withdrawUnclaimedOfferTokens();
        if (amount > 0) IERC20(OFFER_TOKEN).transfer(ADMIN, amount);
    }

    // callback

    function onERC1155Received(address, /*operator*/ address from, uint256 id, uint256 value, bytes calldata /*data*/ )
        external
        onlyHub
        returns (bytes4)
    {
        address offerAddress = address(currentOffer());
        if (from == offerAddress) {
            // transfer to admin
            HUB.safeTransferFrom(address(this), ADMIN, id, value, "");
            return this.onERC1155Received.selector;
        }

        // transfer to offer
        HUB.safeTransferFrom(address(this), offerAddress, id, value, abi.encode(from));

        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address, /*operator*/
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata /*data*/
    ) external onlyHub returns (bytes4) {
        address offerAddress = address(currentOffer());
        if (from == offerAddress) {
            // transfer to admin
            HUB.safeBatchTransferFrom(address(this), ADMIN, ids, values, "");
            return this.onERC1155BatchReceived.selector;
        }

        bytes memory forwardedFrom = abi.encode(from);

        // transfer to offer
        HUB.safeBatchTransferFrom(address(this), offerAddress, ids, values, forwardedFrom);

        return this.onERC1155BatchReceived.selector;
    }

    // weight provider function
    function setNextOfferAccountWeights(address[] memory accounts, uint256[] memory weights) external onlyAdmin {
        address nextOffer = address(offers[currentOfferId() + 1]);
        ACCOUNT_WEIGHT_PROVIDER.setAccountWeights(nextOffer, accounts, weights);
    }
}
