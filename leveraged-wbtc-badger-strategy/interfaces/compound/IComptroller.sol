// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

interface IComptroller {
    /*** Assets You Are In ***/

    function enterMarkets(address[] calldata cTokens)
        external
        returns (uint256[] memory);

    function exitMarket(address cToken) external returns (uint256);

    function claimComp(address holder) external;
}
