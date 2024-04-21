// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {FlashLiquidityAdapter} from "../../../contracts/adapters/FlashLiquidityAdapter.sol";
import {Governable} from "flashliquidity-acs/contracts/Governable.sol";

contract FlashLiquidityAdapterTest is Test {
    FlashLiquidityAdapter adapter;
    address governor = makeAddr("governor");
    address bob = makeAddr("bob");
    address factory0 = makeAddr("factory0");
    address factory1 = makeAddr("factory1");

    function setUp() public {
        adapter = new FlashLiquidityAdapter(governor, "FlashLiquidityAdapter 1.0");
    }

    function test__FlashLiquidityAdapter_addFactory() public {
        uint48 feeNumeratorVal = 997;
        uint48 feeDenominatorVal = 1000;
        vm.expectRevert(Governable.Governable__NotAuthorized.selector);
        adapter.addFactory(factory0, feeNumeratorVal, feeDenominatorVal);
        vm.prank(governor);
        adapter.addFactory(factory0, feeNumeratorVal, feeDenominatorVal);
        (address factory, uint48 feeNumerator, uint48 feeDenominator) = adapter.getFactoryAtIndex(0);
        assertEq(factory, factory0);
        assertEq(feeNumerator, feeNumeratorVal);
        assertEq(feeDenominator, feeDenominatorVal);
    }

    function test__FlashLiquidityAdapter_removeFactory() public {
        uint48 feeNumeratorVal0 = 997;
        uint48 feeNumeratorVal1 = 998;
        uint48 feeDenominatorVal = 1000;
        vm.startPrank(governor);
        adapter.addFactory(factory0, feeNumeratorVal0, feeDenominatorVal);
        adapter.addFactory(factory1, feeNumeratorVal1, feeDenominatorVal);
        vm.stopPrank();
        vm.expectRevert(Governable.Governable__NotAuthorized.selector);
        adapter.removeFactory(0);
        vm.prank(governor);
        adapter.removeFactory(0);
        (address factory, uint48 feeNumerator, uint48 feeDenominator) = adapter.getFactoryAtIndex(0);
        assertEq(factory, factory1);
        assertEq(feeNumerator, feeNumeratorVal1);
        assertEq(feeDenominator, feeDenominatorVal);
    }
}
