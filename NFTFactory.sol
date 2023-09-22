// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {Address} from "@openzeppelin/utils/Address.sol";

import {BuggyNFT} from "./BuggyNFT.sol";

contract NFTFactory is UpgradeableBeacon {
    using Address for address;

    address[] public NFTs;
    mapping(address => bool) private mediators;

    constructor(address implementation) UpgradeableBeacon(implementation) {}

    /**
     * @notice deploys a new NFT contract
     * @param initializer should be abi encoded call initialize(string memory name, string memory symbol)
     */
    function deployNFT(bytes calldata initializer) public payable {
        address[] storage nfts = NFTs;
        address proxy;

        proxy = address(new BeaconProxy(address(this), ""));
        nfts.push(proxy);

        // Deployed NFT contracts should never not be initialized since
        // we atomically call it here
        proxy.functionCallWithValue(initializer, msg.value);
    }

    function addMediator(address account) public returns (bool) {
        if (!mediators[account]) mediators[account] = true;
        return mediators[account];
    }

    function isMediator(address sender) public view returns (bool) {
        return mediators[sender];
    }
}
