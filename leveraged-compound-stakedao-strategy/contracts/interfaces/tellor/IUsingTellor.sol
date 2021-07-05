// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.5.17;
pragma experimental ABIEncoderV2;

interface IUsingTellor {
    function submitValue(uint256 _requestId, uint256 _value) external;

    function getNewValueCountbyRequestId(uint256 _requestId) external;

    function getTimestampbyRequestIDandIndex(uint256 _requestId, uint256 index)
        external
        view
        returns (uint256);

    function retrieveData(uint256 _requestId, uint256 _timestamp)
        external
        view
        returns (uint256);
}
