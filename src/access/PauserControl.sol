// SPDX-License-Identifier: GPL-3.0-only

pragma solidity ^0.8.18;

import "@openzeppelin/contracts/utils/Pausable.sol";
import "./AccessControl.sol";

abstract contract PauserControl is AccessControl, Pausable {
    // 0cc58340b26c619cd4edc70f833d3f4d9d26f3ae7d5ef2965f81fe5495049a4f
    bytes32 public constant PAUSER_ROLE = keccak256("pauser");

    modifier onlyPauser() {
        require(hasRole(PAUSER_ROLE, msg.sender), "Caller is not a pauser");
        _;
    }

    function pause() public virtual onlyPauser {
        _pause();
    }

    function unpause() public virtual onlyPauser {
        _unpause();
    }
}
