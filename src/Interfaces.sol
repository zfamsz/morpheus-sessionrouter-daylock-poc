// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interfaces for the Morpheus Base diamond, derived from the
///         Morpheus-Lumerin-Node source (smart-contracts/contracts/interfaces/).
///         Only the functions this reproduction needs are declared.
interface ISessionRouter {
    function openSession(
        address user_,
        uint256 amount_,
        bool isDirectPaymentFromUser_,
        bytes calldata approvalEncoded_,
        bytes calldata signature_
    ) external returns (bytes32);

    function closeSession(bytes calldata receiptEncoded_, bytes calldata signature_) external;

    function claimForProvider(bytes32 sessionId_) external;

    function getSessionEnd(uint256 amount_, uint256 pricePerSecond_, uint128 openedAt_)
        external
        view
        returns (uint128);

    function stakeToStipend(uint256 amount_, uint128 timestamp_) external view returns (uint256);

    function stipendToStake(uint256 stipend_, uint128 timestamp_) external view returns (uint256);

    function getUserStakesOnHold(address user_, uint8 iterations_)
        external
        view
        returns (uint256 available_, uint256 hold_);

    function startOfTheDay(uint128 timestamp_) external pure returns (uint128);
}

interface IMarketplace {
    function postModelBid(address provider_, bytes32 modelId_, uint256 pricePerSecond_)
        external
        returns (bytes32);
}

interface IModelRegistry {
    function modelRegister(
        address modelOwner_,
        bytes32 modelId_,
        bytes32 ipfsCID_,
        uint256 fee_,
        uint256 amount_,
        string calldata name_,
        string[] calldata tags_
    ) external;

    function getModelId(address account_, bytes32 baseModelId_) external pure returns (bytes32);
}

interface IProviderRegistry {
    function providerRegister(address provider_, uint256 amount_, string calldata endpoint_) external;
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
