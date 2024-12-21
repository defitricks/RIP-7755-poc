// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RIP7755OutboxToArbitrum} from "../../src/outboxes/RIP7755OutboxToArbitrum.sol";

contract MockArbitrumProver is RIP7755OutboxToArbitrum {
    function validateProof2(
        bytes memory storageKey,
        string calldata receiver,
        bytes[] calldata attributes,
        bytes calldata proof
    ) external view {
        _validateProof2(storageKey, receiver, attributes, proof);
    }
}
