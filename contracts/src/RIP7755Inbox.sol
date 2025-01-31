// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";

import {IPrecheckContract} from "./interfaces/IPrecheckContract.sol";
import {CAIP10} from "./libraries/CAIP10.sol";
import {GlobalTypes} from "./libraries/GlobalTypes.sol";
import {ERC7786Base} from "./ERC7786Base.sol";
import {Call} from "./RIP7755Structs.sol";

/// @title RIP7755Inbox
///
/// @author Coinbase (https://github.com/base-org/RIP-7755-poc)
///
/// @notice An inbox contract within RIP-7755. This contract's sole purpose is to route requested transactions on
/// destination chains and store record of their fulfillment.
contract RIP7755Inbox is ERC7786Base {
    using Address for address payable;
    using GlobalTypes for bytes32;
    using CAIP10 for address;

    struct MainStorage {
        /// @notice A mapping from the keccak256 hash of a `CrossChainRequest` to its `FulfillmentInfo`. This can only be set once per call
        mapping(bytes32 requestHash => FulfillmentInfo) fulfillmentInfo;
    }

    /// @notice Stored on verifyingContract and proved against in originationContract
    struct FulfillmentInfo {
        /// @dev Block timestamp when fulfilled
        uint96 timestamp;
        /// @dev Msg.sender of fulfillment call
        address fulfiller;
    }

    // Main storage location used as the base for the fulfillmentInfo mapping following EIP-7201. (keccak256("RIP-7755"))
    bytes32 private constant _MAIN_STORAGE_LOCATION = 0x43f1016e17bdb0194ec37b77cf476d255de00011d02616ab831d2e2ce63d9ee2;

    /// @notice Event emitted when a cross chain call is fulfilled
    /// @param requestHash The keccak256 hash of a `CrossChainRequest`
    /// @param fulfilledBy The account that fulfilled the cross chain call
    event CallFulfilled(bytes32 indexed requestHash, address indexed fulfilledBy);

    /// @notice This error is thrown when an account attempts to submit a cross chain call that has already been fulfilled
    error CallAlreadyFulfilled();

    /// @notice This error is thrown if a fulfiller submits a `msg.value` greater than the total value needed for all the calls
    /// @param expected The total value needed for all the calls
    /// @param actual The received `msg.value`
    error InvalidValue(uint256 expected, uint256 actual);

    /// @notice Delivery of a message sent from another chain.
    ///
    /// @param sourceChain The CAIP-2 source chain identifier
    /// @param sender The CAIP-10 account address of the sender
    /// @param payload The encoded calls array
    /// @param attributes The attributes of the message
    ///
    /// @return selector The selector of the function
    function executeMessage(
        string calldata sourceChain,
        string calldata sender,
        bytes calldata payload,
        bytes[] calldata attributes
    ) external payable returns (bytes4) {
        string memory receiver = address(this).local();
        string memory combinedSender = CAIP10.format(sourceChain, sender);
        bytes32 messageId = keccak256(abi.encode(combinedSender, receiver, payload, attributes));

        _runPrecheck(sourceChain, sender, payload, attributes);

        if (_getFulfillmentInfo(messageId).timestamp != 0) {
            revert CallAlreadyFulfilled();
        }

        address fulfiller = _getFulfiller(attributes);

        _setFulfillmentInfo(messageId, FulfillmentInfo({timestamp: uint96(block.timestamp), fulfiller: fulfiller}));

        _sendCallsAndValidateMsgValue(payload);

        emit CallFulfilled({requestHash: messageId, fulfilledBy: fulfiller});

        return 0x675b049b; // this function's sig
    }

    /// @notice Returns the stored fulfillment info for a passed in call hash
    ///
    /// @param requestHash A keccak256 hash of a CrossChainRequest
    ///
    /// @return _ Fulfillment info stored for the call hash
    function getFulfillmentInfo(bytes32 requestHash) external view returns (FulfillmentInfo memory) {
        return _getFulfillmentInfo(requestHash);
    }

    function _sendCallsAndValidateMsgValue(bytes calldata payload) private {
        uint256 valueSent;

        Call[] memory calls = abi.decode(payload, (Call[]));

        for (uint256 i; i < calls.length; i++) {
            _call(payable(calls[i].to.bytes32ToAddress()), calls[i].data, calls[i].value);

            unchecked {
                valueSent += calls[i].value;
            }
        }

        if (valueSent != msg.value) {
            revert InvalidValue(valueSent, msg.value);
        }
    }

    function _call(address payable to, bytes memory data, uint256 value) private {
        if (data.length == 0) {
            to.sendValue(value);
        } else {
            to.functionCallWithValue(data, value);
        }
    }

    function _setFulfillmentInfo(bytes32 requestHash, FulfillmentInfo memory fulfillmentInfo) private {
        MainStorage storage $ = _getMainStorage();
        $.fulfillmentInfo[requestHash] = fulfillmentInfo;
    }

    function _runPrecheck(
        string calldata sourceChain, // [CAIP-2] chain identifier
        string calldata sender, // [CAIP-10] account address
        bytes calldata payload,
        bytes[] calldata attributes
    ) private view {
        (bool found, bytes calldata precheckAttribute) =
            _locateAttributeUnchecked(attributes, _PRECHECK_ATTRIBUTE_SELECTOR);

        if (!found) {
            return;
        }

        address precheckContract = abi.decode(precheckAttribute[4:], (address));
        IPrecheckContract(precheckContract).precheckCall(sourceChain, sender, payload, attributes, msg.sender);
    }

    function _getFulfillmentInfo(bytes32 requestHash) private view returns (FulfillmentInfo memory) {
        MainStorage storage $ = _getMainStorage();
        return $.fulfillmentInfo[requestHash];
    }

    function _getFulfiller(bytes[] calldata attributes) private view returns (address) {
        (bool found, bytes calldata fulfillerAttribute) =
            _locateAttributeUnchecked(attributes, _FULFILLER_ATTRIBUTE_SELECTOR);

        if (!found) {
            return msg.sender;
        }

        return abi.decode(fulfillerAttribute[4:], (address));
    }

    function _getMainStorage() private pure returns (MainStorage storage $) {
        assembly {
            $.slot := _MAIN_STORAGE_LOCATION
        }
    }
}
