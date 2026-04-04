// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Re-export Chainlink's official VRF v2.5 mock so Hardhat compiles the artifact
// and deploy/test scripts can reference it by name "VRFCoordinatorV2_5Mock".
//
// Constructor:  VRFCoordinatorV2_5Mock(uint96 _baseFee, uint96 _gasPriceLink, int256 _weiPerUnitLink)
// Key methods:
//   createSubscription()                              → uint256 subId
//   fundSubscription(uint256 subId, uint96 amount)
//   addConsumer(uint256 subId, address consumer)
//   fulfillRandomWords(uint256 requestId, address consumer)
//   fulfillRandomWordsWithOverride(uint256 requestId, address consumer, uint256[] words)

import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
