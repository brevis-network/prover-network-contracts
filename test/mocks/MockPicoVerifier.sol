// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/pico/IPicoVerifier.sol";

contract MockPicoVerifier is IPicoVerifier {
    mapping(bytes32 => bool) public validProofs;

    function setValidProof(bytes32 vk, bytes32 publicValuesDigest, uint256[8] calldata proof) external {
        bytes32 proofHash = keccak256(abi.encodePacked(vk, publicValuesDigest, proof));
        validProofs[proofHash] = true;
    }

    function verifyPicoProof(bytes32 riscvVkey, bytes calldata publicValues, uint256[8] calldata proof)
        external
        view
        override
    {
        bytes32 publicValuesHash = keccak256(publicValues);
        bytes32 proofHash = keccak256(abi.encodePacked(riscvVkey, publicValuesHash, proof));
        require(validProofs[proofHash], "Invalid proof");
    }

    function verifyPicoProof(bytes32 riscvVkey, bytes32 publicValuesHash, uint256[8] calldata proof)
        external
        view
        override
    {
        bytes32 proofHash = keccak256(abi.encodePacked(riscvVkey, publicValuesHash, proof));
        require(validProofs[proofHash], "Invalid proof");
    }
}
