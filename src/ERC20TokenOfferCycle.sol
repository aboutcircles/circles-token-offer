// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20TokenOfferFactory} from "src/interfaces/IERC20TokenOfferFactory.sol";
import {IAccountWeightProvider} from "src/interfaces/IAccountWeightProvider.sol";
import {IERC20TokenOffer} from "src/interfaces/IERC20TokenOffer.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {LibString} from "solady/utils/LibString.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract ERC20TokenOfferCycle {
    using SafeTransferLib for address;

    error OnlyAdmin();
    error OnlyHub();
    error OnlyCurrentOffer();
    error NextOfferTokensAreAlreadyDeposited();
    error SoftLock();
    /*//////////////////////////////////////////////////////////////
                             Events
    //////////////////////////////////////////////////////////////*/

    event CycleConfiguration(
        address indexed admin,
        address indexed accountWeightProvider,
        address indexed offerToken,
        uint256 offersStart,
        uint256 offerDuration,
        bool softLockEnabled
    );

    event NextOfferCreated(
        address indexed nextOffer,
        uint256 indexed tokenPriceInCRC,
        uint256 indexed offerLimitInCRC,
        address[] acceptedCRC
    );

    event NextOfferTokensDeposited(address indexed nextOffer, uint256 indexed amount);

    event OfferTrustSynced(uint256 indexed offerId, address indexed offer);

    event OfferClaimed(address indexed offer, address indexed account, uint256 indexed received, uint256 spent);

    event UnclaimedTokensWithdrawn(address indexed offer, uint256 indexed amount);

    /// @notice Circles v2 Hub.
    IHub public constant HUB = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));
    IERC20TokenOfferFactory public immutable OFFER_FACTORY;
    address public immutable ADMIN;
    IAccountWeightProvider public immutable ACCOUNT_WEIGHT_PROVIDER;

    address public immutable OFFER_TOKEN;
    uint256 public immutable OFFERS_START;
    uint256 public immutable OFFER_DURATION;
    bool public immutable SOFT_LOCK_ENABLED;

    string public offerOrgName;
    mapping(uint256 => IERC20TokenOffer) public offers;
    mapping(uint256 => address[]) public acceptedCRC;
    mapping(address => uint256) public totalClaimed;

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
        bool accountWeightProviderUnbounded,
        address admin,
        address offerToken,
        uint256 offersStart,
        uint256 offerDuration,
        bool enableSoftLock,
        string memory offerName,
        string memory orgName
    ) {
        OFFER_FACTORY = IERC20TokenOfferFactory(msg.sender);
        ACCOUNT_WEIGHT_PROVIDER = IAccountWeightProvider(
            OFFER_FACTORY.createAccountWeightProvider(address(this), accountWeightProviderUnbounded)
        );
        ADMIN = admin;
        OFFER_TOKEN = offerToken;
        OFFERS_START = offersStart;
        OFFER_DURATION = offerDuration;
        SOFT_LOCK_ENABLED = enableSoftLock;
        offerOrgName = offerName;

        // register an org
        HUB.registerOrganization(orgName, 0);

        emit CycleConfiguration(
            ADMIN, address(ACCOUNT_WEIGHT_PROVIDER), OFFER_TOKEN, OFFERS_START, OFFER_DURATION, SOFT_LOCK_ENABLED
        );
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
        nextOffer = address(offers[currentId + 1]);
        // check case: next offer exists and tokens are deposited
        if (nextOffer != address(0) && IERC20TokenOffer(nextOffer).isOfferTokensDeposited()) {
            revert NextOfferTokensAreAlreadyDeposited();
        }
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
        emit OfferTrustSynced(currentId, address(offers[currentId]));
    }

    // offer functions
    function isOfferAvailable() external view returns (bool) {
        return currentOffer().isOfferAvailable();
    }

    function isAccountEligible(address account) external view returns (bool) {
        return currentOffer().isAccountEligible(account);
    }

    function getTotalEligibleAccounts() external view returns (uint256) {
        return currentOffer().getTotalEligibleAccounts();
    }

    function getClaimantCount() external view returns (uint256) {
        return currentOffer().claimantCount();
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
        OFFER_TOKEN.safeTransferFrom(ADMIN, address(this), requiredAmount);
        OFFER_TOKEN.safeApprove(address(nextOffer), requiredAmount);

        nextOffer.depositOfferTokens();

        emit NextOfferTokensDeposited(address(nextOffer), requiredAmount);
    }

    function withdrawUnclaimedOfferTokens(uint256 offerId) external onlyAdmin {
        IERC20TokenOffer offer = offers[offerId];
        uint256 amount = offer.withdrawUnclaimedOfferTokens();
        if (amount > 0) {
            OFFER_TOKEN.safeTransfer(ADMIN, amount);
            emit UnclaimedTokensWithdrawn(address(offer), amount);
        }
    }

    // callback

    function onERC1155Received(address, /*operator*/ address from, uint256 id, uint256 value, bytes memory data)
        external
        onlyHub
        returns (bytes4)
    {
        address offerAddress = address(currentOffer());
        if (from == offerAddress) {
            // track the claim
            (address account, uint256 amount) = abi.decode(data, (address, uint256));
            totalClaimed[account] += amount;
            emit OfferClaimed(offerAddress, account, amount, value);
            // transfer to admin
            HUB.safeTransferFrom(address(this), ADMIN, id, value, "");
            return this.onERC1155Received.selector;
        }

        if (SOFT_LOCK_ENABLED && totalClaimed[from] > OFFER_TOKEN.balanceOf(from)) revert SoftLock();
        data = abi.encode(from);

        // transfer to offer
        HUB.safeTransferFrom(address(this), offerAddress, id, value, data);

        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address, /*operator*/
        address from,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) external onlyHub returns (bytes4) {
        address offerAddress = address(currentOffer());
        if (from == offerAddress) {
            // track the claim
            (address account, uint256 amount, uint256 value) = abi.decode(data, (address, uint256, uint256));
            totalClaimed[account] += amount;
            emit OfferClaimed(offerAddress, account, amount, value);
            // transfer to admin
            HUB.safeBatchTransferFrom(address(this), ADMIN, ids, values, "");
            return this.onERC1155BatchReceived.selector;
        }

        if (SOFT_LOCK_ENABLED && totalClaimed[from] > OFFER_TOKEN.balanceOf(from)) revert SoftLock();
        data = abi.encode(from);

        // transfer to offer
        HUB.safeBatchTransferFrom(address(this), offerAddress, ids, values, data);

        return this.onERC1155BatchReceived.selector;
    }

    // weight provider function
    function setNextOfferAccountWeights(address[] memory accounts, uint256[] memory weights) external onlyAdmin {
        address nextOffer = address(offers[currentOfferId() + 1]);
        ACCOUNT_WEIGHT_PROVIDER.setAccountWeights(nextOffer, accounts, weights);
    }
}
