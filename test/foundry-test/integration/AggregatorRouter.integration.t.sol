// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IAggregatorRouter, AggregatorRouter} from "../../../contracts/AggregatorRouter.sol";
import {Governable} from "flashliquidity-acs/contracts/Governable.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {ERC20} from "../../mocks/ERC20Mock.sol";
import {IWETH} from "../../../contracts/interfaces/IWETH.sol";
import {UniswapV2Adapter} from "../../../contracts/adapters/UniswapV2Adapter.sol";
import {UniswapV3Adapter} from "../../../contracts/adapters/UniswapV3Adapter.sol";
import {FlashLiquidityAdapter} from "../../../contracts/adapters/FlashLiquidityAdapter.sol";

contract AggregatorRouterTest is Test {
    AggregatorRouter router;
    FlashLiquidityAdapter flAdapter;
    UniswapV2Adapter uniV2Adapter;
    UniswapV3Adapter uniV3Adapter;
    address governor = address(0x95E05C9870718cb171C04080FDd186571475027E);
    address bob = makeAddr("bob");
    address alice = makeAddr("alice");
    address feeRecipient = makeAddr("feeRecipient");
    address feeClaimer = makeAddr("feeClaimer");
    address flFactory = address(0x6e553d5f028bD747a27E138FA3109570081A23aE);
    address uniV3Factory = address(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    address uniV3Quoter = address(0xc80f61d1bdAbD8f5285117e1558fDDf8C64870FE);
    address uniV3ForkFactory = address(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    address uniV2ForkFactory = address(0xd394E9CC20f43d2651293756F8D320668E850F1b);
    uint24[] uniV3Fees = [500, 3000];
    address flEthUsdc = address(0xdE67c936D87455A77BAeF8Ab7e6c26Eb3D828735);
    address WETH = address(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    address USDC = address(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);

    function createTradeParams(address tokenIn, address tokenOut, address to, uint256 amountIn, uint256 amountOutMin)
        private
        pure
        returns (IAggregatorRouter.TradeParams memory)
    {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        return IAggregatorRouter.TradeParams({path: path, to: to, amountIn: amountIn, amountOutMin: amountOutMin});
    }

    function setUp() public {
        vm.createSelectFork("https://arb1.arbitrum.io/rpc");
        router = new AggregatorRouter(governor, WETH, 0, feeRecipient, feeClaimer);
        uniV2Adapter = new UniswapV2Adapter(governor, "UniswapV2 Adapter 0.0.1");
        uniV3Adapter = new UniswapV3Adapter(governor, "UniswapV3 Adapter 0.0.1");
        flAdapter = new FlashLiquidityAdapter(governor, "FlashLiquidity Adapter 0.0.1");
        address[] memory supportedInputTokens = new address[](1);
        bool[] memory isSupportedToken = new bool[](1);
        supportedInputTokens[0] = USDC;
        isSupportedToken[0] = true;
        vm.startPrank(governor);
        router.setSupportedInputTokens(supportedInputTokens, isSupportedToken);
        router.pushDexAdapter(address(uniV2Adapter));
        router.pushDexAdapter(address(uniV3Adapter));
        router.pushDexAdapter(address(flAdapter));
        uniV2Adapter.addFactory(uniV2ForkFactory, 997, 1000);
        uniV3Adapter.addFactory(uniV3Factory, uniV3Quoter, uniV3Fees);
        flAdapter.addFactory(flFactory, 997, 1000);
        vm.stopPrank();
    }

    function testIntegration__AggregatorRouter_findBestRouteAndSwap() public {
        assertEq(ERC20(USDC).balanceOf(bob), 0);
        IAggregatorRouter.TradeParams memory trade = createTradeParams(address(0), USDC, bob, 0, 1);
        router.findBestRouteAndSwap{value: 1 ether}(trade);
        uint256 balanceUSDC = ERC20(USDC).balanceOf(bob);
        assertGt(ERC20(USDC).balanceOf(bob), 0);
        trade = createTradeParams(USDC, address(0), alice, balanceUSDC, 1);
        uint256 aliceNativeBalance = alice.balance;
        vm.startPrank(bob);
        ERC20(USDC).approve(address(router), balanceUSDC);
        router.findBestRouteAndSwap(trade);
        vm.stopPrank();
        assertGt(alice.balance, aliceNativeBalance);
    }

    function testIntegration__AggregatorRouter_swapSingleRoute() public {
        assertEq(ERC20(USDC).balanceOf(bob), 0);
        address[] memory path = new address[](2);
        path[0] = address(0);
        path[1] = USDC;
        (uint256 maxOutput, IAggregatorRouter.AdapterParams[] memory params) = router.getBestRoute(path, 1 ether);
        IAggregatorRouter.TradeParams memory trade = createTradeParams(address(0), USDC, bob, 0, maxOutput);
        router.swapSingleRoute{value: 1 ether}(trade, params);
        assertGt(ERC20(USDC).balanceOf(bob), 0);
        uint256 balanceUSDC = ERC20(USDC).balanceOf(bob);
        trade = createTradeParams(USDC, address(0), alice, balanceUSDC, maxOutput);
        uint256 aliceNativeBalance = alice.balance;
        path[0] = USDC;
        path[1] = address(0);
        vm.startPrank(bob);
        (maxOutput, params) = router.getBestRoute(path, 1 ether);
        ERC20(USDC).approve(address(router), balanceUSDC);
        router.swapSingleRoute(trade, params);
        vm.stopPrank();
        assertGt(alice.balance, aliceNativeBalance);
    }

    function testIntegration__AggregatorRouter_swapSplitRoutes() public {
        assertEq(ERC20(USDC).balanceOf(bob), 0);
        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = 5e17;
        amountsIn[1] = 5e17;
        (, bytes[][] memory adaptersArgs) = router.getAllAdapterOutputsAndArgs(WETH, USDC, 1 ether);
        IAggregatorRouter.TradeParams memory trade = createTradeParams(address(0), USDC, bob, 0, 1);
        IAggregatorRouter.AdapterParams[][] memory adaptersParams = new IAggregatorRouter.AdapterParams[][](2);
        adaptersParams[0] = new IAggregatorRouter.AdapterParams[](1);
        adaptersParams[1] = new IAggregatorRouter.AdapterParams[](1);
        adaptersParams[0][0].index = 0;
        adaptersParams[0][0].extraArgs = adaptersArgs[0][0];
        adaptersParams[1][0].index = 1;
        adaptersParams[1][0].extraArgs = adaptersArgs[1][0];
        router.swapSplitRoutes{value: 1 ether}(trade, adaptersParams, amountsIn);
        assertGt(ERC20(USDC).balanceOf(bob), 0);
        uint256 balanceUSDC = ERC20(USDC).balanceOf(bob);
        trade = createTradeParams(USDC, address(0), alice, balanceUSDC, 1);
        amountsIn[0] = balanceUSDC / 2;
        amountsIn[1] = balanceUSDC - amountsIn[0];
        (, adaptersArgs) = router.getAllAdapterOutputsAndArgs(WETH, USDC, 1 ether);
        adaptersParams[0][0].extraArgs = adaptersArgs[0][0];
        adaptersParams[1][0].extraArgs = adaptersArgs[1][0];
        uint256 aliceNativeBalance = alice.balance;
        vm.startPrank(bob);
        ERC20(USDC).approve(address(router), balanceUSDC);
        router.swapSplitRoutes(trade, adaptersParams, amountsIn);
        vm.stopPrank();
        assertGt(alice.balance, aliceNativeBalance);
    }
}
