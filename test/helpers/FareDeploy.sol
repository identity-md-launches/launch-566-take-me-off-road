// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {MedallionHook} from "../../src/MedallionHook.sol";

abstract contract FareDeploy {
    function _deployHook(IPoolManager manager) internal returns (MedallionHook hook) {
        bytes memory creation = abi.encodePacked(type(MedallionHook).creationCode, abi.encode(manager));
        bytes32 creationHash = keccak256(creation);
        bytes memory preimage = abi.encodePacked(bytes1(0xff), address(this), bytes32(0), creationHash);
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            assembly ("memory-safe") {
                mstore(add(preimage, 0x35), salt)
            }
            address predicted = address(uint160(uint256(keccak256(preimage))));
            if (uint160(predicted) & 0x3fff != 0x10cc || predicted.code.length != 0) continue;
            address deployed;
            assembly ("memory-safe") {
                deployed := create2(0, add(creation, 32), mload(creation), salt)
            }
            require(deployed == predicted, "hook CREATE2 deployment failed");
            return MedallionHook(deployed);
        }
        revert("hook salt not found");
    }
}
