// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPicoVerifier} from "./IPicoVerifier.sol";

/// @title Mock Pico Verifier
/// @author Brevis Network
/// @notice This contracts implements a mock solidity verifier for Pico.
contract MockPicoVerifier is IPicoVerifier {
    /// @notice Thrown when the proof is invalid.
    error InvalidProof();

    /// @notice Hashes the public values to a field elements inside Bn254 using SHA256.
    /// @param publicValues The public values.
    function sha256PublicValues(bytes calldata publicValues) public pure returns (bytes32) {
        return sha256(publicValues) & bytes32(uint256((1 << 253) - 1));
    }

    /// @notice Verifies a proof with given public values and riscv verification key.
    /// @param riscvVkey The verification key for the RISC-V program.
    /// @param publicValues The public values encoded as bytes.
    /// @param proof The proof of the riscv program execution in the Pico.
    function verifyPicoProof(bytes32 riscvVkey, bytes calldata publicValues, uint256[8] calldata proof) external pure {
        bytes32 publicValuesDigest = sha256PublicValues(publicValues);
        verifyPicoProof(riscvVkey, publicValuesDigest, proof);
    }

    /// @notice Verifies a proof with given public values and riscv verification key.
    /// @param riscvVkey The verification key for the RISC-V program.
    /// @param publicValuesDigest The sha256 hash of bytes-encoded public values.
    /// @param proof The proof of the riscv program execution in the Pico.
    function verifyPicoProof(bytes32 riscvVkey, bytes32 publicValuesDigest, uint256[8] calldata proof) public pure {
        // Mock verification: use first two elements of proof array as vkey and digest
        bytes32 vk = bytes32(proof[0]);
        bytes32 digest = bytes32(proof[1]);
        require(riscvVkey == vk && publicValuesDigest == digest, "invalid proof");
    }
}
