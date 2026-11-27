// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {TidewellFactory} from "../src/TidewellFactory.sol";
import {TidewellSwapper} from "../src/TidewellSwapper.sol";
import {TidewellBundleFactory} from "../src/bundles/TidewellBundleFactory.sol";
import {TidewellBundleVault} from "../src/bundles/TidewellBundleVault.sol";
import {TidewellBundler} from "../src/bundles/TidewellBundler.sol";

/// @notice Deploys LP Bundles: the bundle vault, its factory, a swapper for it and the bundler, with every setting
///         copied from the current (shapes) factory. Everything starts PAUSED and owned by the deploy wallet, so the
///         app, keeper and Tidewell bundles can be finished and tested before launch without waiting 48 hours each
///         time; at launch the factory and bundler are handed to the 48-hour timelock.
///         The revenue router must know the new factory before its vaults can pay the protocol fee: that is a
///         timelock batch for the admin Safe (the workflow writes it), which can run while the rest is finished.
///         Environment: FACTORY (the shapes factory to copy), TIDE, USDG (optional).
contract DeployBundles is Script {
    address constant UNIVERSAL_ROUTER = 0x204FAca1764B154221e35c0d20aBb3c525710498;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    function run() external {
        TidewellFactory old = TidewellFactory(vm.envAddress("FACTORY"));
        address tide = vm.envAddress("TIDE");
        address usdg = vm.envOr("USDG", USDG);
        address weth = old.weth();
        vm.startBroadcast();
        address me = msg.sender;
        address impl = address(new TidewellBundleVault());
        TidewellBundleFactory f = new TidewellBundleFactory(
            me,
            TidewellBundleFactory.Addresses({
                implementationV3: impl,
                implementationV4: impl,
                positionManager: old.positionManager(),
                uniswapFactory: old.uniswapFactory(),
                poolManager: old.poolManager(),
                positionManagerV4: old.positionManagerV4(),
                permit2: old.permit2(),
                weth: weth
            }),
            old.keeper(),
            old.guardian(),
            old.feeRecipient()
        );
        // Paused until launch: nothing can be deposited yet.
        f.setPaused(true);
        f.setSwapper(address(new TidewellSwapper(address(f), old.poolManager(), old.permit2(), UNIVERSAL_ROUTER)));
        f.setFee(old.feeRecipient(), old.protocolFeeBps(), old.feeDiscount());
        f.setLimits(old.maxSlippageBps(), old.maxPriceDeviationBps(), old.maxTickDeviation(), old.minCooldown());
        f.setGasRefund(old.maxGasPrice(), old.maxRefundWei(), old.refundOverheadGas());
        f.setCardinalityTarget(old.cardinalityTarget());
        f.setFeeRank(usdg, old.feeRank(usdg));
        address[2] memory tokens = [weth, usdg];
        for (uint256 i; i < 2; ++i) {
            (address feed, uint32 maxAge) = old.feeds(tokens[i]);
            if (feed != address(0)) f.setFeed(tokens[i], feed, maxAge);
        }
        f.setOpenMode(true);
        TidewellBundler b = new TidewellBundler(me, address(f), usdg, tide);
        f.setBundler(address(b));
        vm.stopBroadcast();

        require(f.paused(), "not paused");
        require(f.bundler() == address(b), "bundler not set");
        console.log("bundleFactory", address(f));
        console.log("bundleVault", impl);
        console.log("bundleSwapper", f.swapper());
        console.log("bundler", address(b));
        string memory k = "bundles";
        vm.serializeAddress(k, "bundleFactory", address(f));
        vm.serializeAddress(k, "bundleVault", impl);
        vm.serializeAddress(k, "bundleSwapper", f.swapper());
        vm.serializeBool(k, "live", false);
        string memory json = vm.serializeAddress(k, "bundler", address(b));
        vm.writeJson(json, vm.envOr("BUNDLES_OUT", string("../deployments/mainnet-bundles.json")));
    }
}
