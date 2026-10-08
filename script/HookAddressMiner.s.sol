// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice Offline planner. Does not broadcast, load keys, or deploy a wrapper.
contract HookAddressMiner {
    address public constant MAINNET_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function run(address create2Deployer, address launchToken, uint256 start, uint256 attempts)
        external
        view
        returns (address predicted, bytes32 salt, bytes memory creationCode)
    {
        creationCode = abi.encodePacked(
            type(SIMDTESTHook).creationCode, abi.encode(IPoolManager(MAINNET_MANAGER), launchToken)
        );
        bytes32 hash = keccak256(creationCode);
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", create2Deployer, salt, hash)))));
            if (uint160(predicted) & 0x3fff == 0x20c8 && predicted.code.length == 0) {
                return (predicted, salt, creationCode);
            }
        }
        revert("No salt in search interval");
    }
}
