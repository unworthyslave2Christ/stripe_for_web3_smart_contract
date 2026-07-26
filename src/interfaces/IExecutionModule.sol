// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ERC-7579 Execution Module Interface
/// @notice Minimal execution interface required by the Web3 Subscription Module.
/// @dev Compatible with modular smart accounts exposing executeFromModule().
interface IExecutionModule {
    /**
     * @notice Execute one transaction from an installed module.
     *
     * @param target Contract to call.
     * @param value Native ETH value.
     * @param callData Encoded calldata.
     *
     * @return results Returned data from execution.
     */
    function executeFromModule(
        address target,
        uint256 value,
        bytes calldata callData
    )
        external
        returns (bytes[] memory results);
}