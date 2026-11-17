// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {BoostDistributor} from "../src/BoostDistributor.sol";

/// @notice Deploys the BoostDistributor (boosted pools payout). Owner: the 48-hour timelock, so setting the first
///         round's start and changing the operator are public two days before they happen. Operator: the keeper wallet.
///         Environment: TIMELOCK, KEEPER, FACTORY, FACTORY_OLD (optional, comma-free: one address), ROUND_DAYS (default 14).
contract DeployBoost is Script {
    function run() external returns (BoostDistributor d) {
        address timelock = vm.envAddress("TIMELOCK");
        address keeper = vm.envAddress("KEEPER");
        uint256 days_ = vm.envOr("ROUND_DAYS", uint256(14));
        address factory = vm.envAddress("FACTORY");
        address old = vm.envOr("FACTORY_OLD", address(0));
        address[] memory f = new address[](old == address(0) ? 1 : 2);
        f[0] = factory;
        if (old != address(0)) f[1] = old;
        // The boost reserve and the burner come from the saved mainnet addresses (deployments/mainnet.json).
        string memory saved = vm.readFile(vm.envOr("MAINNET_JSON", string("../deployments/mainnet.json")));
        address reserve = vm.parseJsonAddress(saved, ".boostReserve");
        address burner = vm.parseJsonAddress(saved, ".burner");
        vm.startBroadcast();
        d = new BoostDistributor(timelock, keeper, days_ * 1 days, f, reserve, burner);
        vm.stopBroadcast();
        console.log("BoostDistributor", address(d));
        string memory k = "boost";
        vm.serializeAddress(k, "timelock", timelock);
        vm.serializeAddress(k, "keeper", keeper);
        vm.serializeAddress(k, "reserve", reserve);
        vm.serializeAddress(k, "burner", burner);
        string memory json = vm.serializeAddress(k, "boostDistributor", address(d));
        vm.writeJson(json, vm.envOr("BOOST_OUT", string("../deployments/mainnet-boost.json")));
    }
}
