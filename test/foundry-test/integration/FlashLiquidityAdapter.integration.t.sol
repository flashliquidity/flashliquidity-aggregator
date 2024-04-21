// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {FlashLiquidityAdapter} from "../../../contracts/adapters/FlashLiquidityAdapter.sol";
import {IFlashLiquidityPair} from "../../../contracts/interfaces/IFlashLiquidityPair.sol";
import {IFlashLiquidityFactory} from "../../../contracts/interfaces/IFlashLiquidityFactory.sol";
import {Governable} from "flashliquidity-acs/contracts/Governable.sol";
import {IWETH} from "@uniswap/v2-periphery/contracts/interfaces/IWETH.sol";
import {ERC20} from "../../mocks/ERC20Mock.sol";

contract FlashLiquidityAdapterIntegrationTest is Test {
    FlashLiquidityAdapter adapter;
    IWETH WETH = IWETH(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    address flFactory = address(0x6e553d5f028bD747a27E138FA3109570081A23aE);
    address governor = makeAddr("governor");
    address USDC = address(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);

    function setUp() public {
        vm.createSelectFork("https://arb1.arbitrum.io/rpc");
        adapter = new FlashLiquidityAdapter(governor, "FlashLiquidityAdapter 1.0");
        vm.prank(governor);
        adapter.addFactory(flFactory, 997, 1000);
    }

    function testIntegration__FlashLiquidityAdapter_getMaxOutput() public view {
        address pair = IFlashLiquidityFactory(flFactory).getPair(address(WETH), USDC);
        if(IFlashLiquidityPair(pair).manager() == address(0)) {
            (uint256 maxOutput, bytes memory extraArgs) = adapter.getMaxOutput(address(WETH), USDC, 1000000000);
            assertTrue(maxOutput > 0 && abi.decode(extraArgs, (address)) == flFactory);
        }
    }

    function testIntegration__FlashLiquidityAdapter_swap() public {
        address pair = IFlashLiquidityFactory(flFactory).getPair(address(WETH), USDC);
        if(IFlashLiquidityPair(pair).manager() == address(0)) {
            (uint256 maxOutput, bytes memory extraArgs) = adapter.getMaxOutput(address(WETH), USDC, 1 ether);
            assertFalse(ERC20(USDC).balanceOf(msg.sender) > 0);
            WETH.deposit{value: 1 ether}();
            ERC20(address(WETH)).approve(address(adapter), 1 ether);
            adapter.swap(address(WETH), USDC, msg.sender, 1 ether, maxOutput, extraArgs);
            assertTrue(ERC20(USDC).balanceOf(msg.sender) == maxOutput);
        }
    }
}
