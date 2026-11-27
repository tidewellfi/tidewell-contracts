// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {TidewellBundleFactory} from "../src/bundles/TidewellBundleFactory.sol";
import {TidewellBundler} from "../src/bundles/TidewellBundler.sol";

/// @notice Replaces the bundler of the (still paused) LP Bundles factory with the current code, before launch.
///         Only while nothing depends on the old one: the factory is paused, owned by the deploy wallet, and the old
///         bundler holds no bundles. The bundler keeps no other state (keeper, pause, fees come from the factory).
///         Environment: BUNDLES (deployments/mainnet-bundles.json), TIDE, USDG (optional), BUNDLES_OUT (optional).
contract RedeployBundler is Script {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    function run() external {
        string memory path = vm.envOr("BUNDLES", string("../deployments/mainnet-bundles.json"));
        string memory json = vm.readFile(path);
        TidewellBundleFactory f = TidewellBundleFactory(payable(vm.parseJsonAddress(json, ".bundleFactory")));
        TidewellBundler old = TidewellBundler(payable(vm.parseJsonAddress(json, ".bundler")));
        address tide = vm.envAddress("TIDE");
        address usdg = vm.envOr("USDG", USDG);

        require(f.paused(), "factory is live: no bundler swap after launch");
        require(f.bundler() == address(old), "factory bundler differs from the file");
        require(old.bundleCount() == 0, "old bundler already holds bundles");

        vm.startBroadcast();
        require(f.owner() == msg.sender, "not the factory owner");
        TidewellBundler b = new TidewellBundler(msg.sender, address(f), usdg, tide);
        f.setBundler(address(b));
        vm.stopBroadcast();

        require(f.bundler() == address(b), "bundler not set");
        require(f.paused(), "not paused");
        console.log("old bundler", address(old));
        console.log("new bundler", address(b));

        string memory k = "bundles";
        vm.serializeAddress(k, "bundleFactory", address(f));
        vm.serializeAddress(k, "bundleVault", vm.parseJsonAddress(json, ".bundleVault"));
        vm.serializeAddress(k, "bundleSwapper", vm.parseJsonAddress(json, ".bundleSwapper"));
        vm.serializeAddress(k, "bundlerOld", address(old));
        vm.serializeBool(k, "live", false);
        string memory out = vm.serializeAddress(k, "bundler", address(b));
        vm.writeJson(out, vm.envOr("BUNDLES_OUT", path));
    }
}
