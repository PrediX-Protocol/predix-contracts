// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

/// @notice Minimal interface for TestUSDC owner operations used during wiring.
interface ITestUSDC {
    function setWhitelistBatch(address[] calldata accounts, bool status) external;
    function mint(address to, uint256 amount) external;
    function owner() external view returns (address);
    function whitelisted(address) external view returns (bool);
}

/// @title PostDeployWiring
/// @notice Post-deploy wiring for a fresh testnet deployment. Run after `DeployAll` +
///         `DeployFaucet` + `DeployMarketFactory`. Single broadcast that:
///
///         1. Whitelists all protocol contracts on TestUSDC
///         2. Grants `CREATOR_ROLE` to deployer + MarketFactory on Diamond
///         3. Mints USDC to Faucet (for user claims)
///         4. Mints USDC to deployer (for market seeding)
///
///         The deployer must be:
///         - Owner of TestUSDC (to mint and whitelist)
///         - Holder of `DEFAULT_ADMIN_ROLE` on Diamond (to grant CREATOR_ROLE)
///
///         For production deploys with real USDC: skip this script — whitelisting and
///         minting are testnet-only. CREATOR_ROLE grants should go through multisig.
///
///         Usage:
///           forge script packages/diamond/script/PostDeployWiring.s.sol:PostDeployWiring \
///               --rpc-url $RPC_URL --broadcast
contract PostDeployWiring is Script {
    // Loại A — documented testnet defaults. Override via env var, 0 = skip.
    uint256 internal constant DEFAULT_FAUCET_FUND = 10_000_000e6;
    uint256 internal constant DEFAULT_DEPLOYER_FUND = 1_000_000e6;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address usdc = vm.envAddress("USDC_ADDRESS");
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address exchangeProxy = vm.envAddress("EXCHANGE_ADDRESS");
        address router = vm.envAddress("ROUTER_ADDRESS");
        address hookProxy = vm.envAddress("HOOK_PROXY_ADDRESS");
        address faucet = vm.envAddress("FAUCET_ADDRESS");
        address factory = vm.envAddress("MARKET_FACTORY_ADDRESS");
        address lpTest = vm.envAddress("LP_TEST_ADDRESS");

        // Loại A: testnet funding amounts, documented defaults above. 0 = skip minting.
        uint256 faucetFund = vm.envOr("FAUCET_FUND_AMOUNT", DEFAULT_FAUCET_FUND);
        uint256 deployerFund = vm.envOr("DEPLOYER_FUND_AMOUNT", DEFAULT_DEPLOYER_FUND);

        _preflightChecks(usdc, diamond, deployer);

        vm.startBroadcast(deployerKey);

        _whitelistProtocol(usdc, diamond, exchangeProxy, router, hookProxy, faucet, factory, lpTest);
        _grantCreatorRoles(diamond, deployer, factory);

        if (faucetFund > 0) {
            ITestUSDC(usdc).mint(faucet, faucetFund);
            console2.log("step 3: minted", faucetFund / 1e6, "USDC to faucet");
        }

        if (deployerFund > 0) {
            ITestUSDC(usdc).mint(deployer, deployerFund);
            console2.log("step 4: minted", deployerFund / 1e6, "USDC to deployer");
        }

        vm.stopBroadcast();

        _postChecks(usdc, diamond, deployer, factory, faucet);
        _logSummary(diamond, exchangeProxy, router, hookProxy, faucet, factory, lpTest);
    }

    function _preflightChecks(address usdc, address diamond, address deployer) internal view {
        require(ITestUSDC(usdc).owner() == deployer, "deployer is not TestUSDC owner");
        require(
            IAccessControlFacet(diamond).hasRole(Roles.DEFAULT_ADMIN_ROLE, deployer),
            "deployer missing DEFAULT_ADMIN_ROLE on Diamond"
        );
    }

    function _whitelistProtocol(
        address usdc,
        address diamond,
        address exchangeProxy,
        address router,
        address hookProxy,
        address faucet,
        address factory,
        address lpTest
    ) internal {
        address[] memory addrs = new address[](7);
        addrs[0] = diamond;
        addrs[1] = exchangeProxy;
        addrs[2] = router;
        addrs[3] = hookProxy;
        addrs[4] = faucet;
        addrs[5] = factory;
        addrs[6] = lpTest;
        ITestUSDC(usdc).setWhitelistBatch(addrs, true);
        console2.log("step 1: whitelisted 7 protocol contracts on TestUSDC");
    }

    function _grantCreatorRoles(address diamond, address deployer, address factory) internal {
        IAccessControlFacet ac = IAccessControlFacet(diamond);
        ac.grantRole(Roles.CREATOR_ROLE, deployer);
        ac.grantRole(Roles.CREATOR_ROLE, factory);
        console2.log("step 2: granted CREATOR_ROLE to deployer + factory");
    }

    function _postChecks(address usdc, address diamond, address deployer, address factory, address faucet)
        internal
        view
    {
        require(ITestUSDC(usdc).whitelisted(diamond), "post-check: diamond not whitelisted");
        require(ITestUSDC(usdc).whitelisted(faucet), "post-check: faucet not whitelisted");
        require(ITestUSDC(usdc).whitelisted(factory), "post-check: factory not whitelisted");
        require(
            IAccessControlFacet(diamond).hasRole(Roles.CREATOR_ROLE, deployer),
            "post-check: deployer missing CREATOR_ROLE"
        );
        require(
            IAccessControlFacet(diamond).hasRole(Roles.CREATOR_ROLE, factory),
            "post-check: factory missing CREATOR_ROLE"
        );
        console2.log("post-checks: all passed");
    }

    function _logSummary(
        address diamond,
        address exchangeProxy,
        address router,
        address hookProxy,
        address faucet,
        address factory,
        address lpTest
    ) internal pure {
        console2.log("============================================================");
        console2.log("PostDeployWiring complete");
        console2.log("============================================================");
        console2.log("Whitelisted on TestUSDC:");
        console2.log("  Diamond:       ", diamond);
        console2.log("  Exchange:      ", exchangeProxy);
        console2.log("  Router:        ", router);
        console2.log("  Hook:          ", hookProxy);
        console2.log("  Faucet:        ", faucet);
        console2.log("  MarketFactory: ", factory);
        console2.log("  LP Test:       ", lpTest);
        console2.log("CREATOR_ROLE granted to deployer + MarketFactory");
    }
}
