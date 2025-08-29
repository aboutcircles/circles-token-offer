// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

interface IERC20TokenOffer {
    error ExceedsOfferLimit(uint256 availableLimit, uint256 value);
    error IneligibleAccount(address account);
    error InvalidTokenId(uint256 id);
    error OfferActive();
    error OfferDepositClosed();
    error OfferNotActive();
    error OfferTokensNotDeposited();
    error OnlyFromCycle();
    error OnlyHub();
    error OnlyOwner();

    event OfferClaimed(address indexed account, uint256 indexed spent, uint256 indexed received);
    event OfferTokensDeposited(uint256 indexed amount);

    function ACCOUNT_WEIGHT_PROVIDER() external view returns (address);
    function BASE_OFFER_LIMIT_IN_CRC() external view returns (uint256);
    function CREATED_BY_CYCLE() external view returns (bool);
    function HUB() external view returns (address);
    function OFFER_END() external view returns (uint256);
    function OFFER_START() external view returns (uint256);
    function OWNER() external view returns (address);
    function TOKEN() external view returns (address);
    function TOKEN_PRICE_IN_CRC() external view returns (uint256);
    function WEIGHT_SCALE() external view returns (uint256);
    function claimantCount() external view returns (uint256);
    function depositOfferTokens() external;
    function getAccountOfferLimit(address account) external view returns (uint256);
    function getAvailableAccountOfferLimit(address account) external view returns (uint256);
    function getRequiredOfferTokenAmount() external view returns (uint256);
    function getTotalEligibleAccounts() external view returns (uint256);
    function isAccountEligible(address account) external view returns (bool);
    function isOfferAvailable() external view returns (bool);
    function isOfferTokensDeposited() external view returns (bool);
    function offerUsage(address account) external view returns (uint256 spentAmount);
    function onERC1155BatchReceived(
        address,
        address from,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) external returns (bytes4);
    function onERC1155Received(address, address from, uint256 id, uint256 value, bytes memory data)
        external
        returns (bytes4);
    function withdrawUnclaimedOfferTokens() external returns (uint256 balance);
}
