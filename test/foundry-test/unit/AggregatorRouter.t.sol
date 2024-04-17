// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {AggregatorRouter} from "../../../contracts/AggregatorRouter.sol";
import {Governable} from "flashliquidity-acs/contracts/Governable.sol";
import {ERC20, ERC20Mock} from "../../mocks/ERC20Mock.sol";

contract AggregatorRouterTest is Test {
    AggregatorRouter router;
    address governor = makeAddr("governor");
    ERC20Mock weth;
    address feeRecipient = makeAddr("feeRecipient");
    address feeClaimer = makeAddr("feeClaimer");
    address bob = makeAddr("bob");
    address alice = makeAddr("alice");
    uint256 supply = 1e9 ether;
    uint24 fee = 0;
    uint32 priceMaxStaleness = 60;
    uint64 minLinkDataStreams = 1e17;

    function setUp() public {
        weth = new ERC20Mock("WETH", "WETH", 1000 ether);
        router = new AggregatorRouter(governor, address(weth), fee, feeRecipient, feeClaimer);
    }

    function test__AggregatorRouter_setFee() public {
        uint24 newFee = 10;
        uint24 MAX_FEE = uint24(router.MAX_FEE());
        vm.expectRevert(Governable.Governable__NotAuthorized.selector);
        router.setFee(newFee);
        assertNotEq(router.s_fee(), newFee);
        vm.startPrank(governor);
        vm.expectRevert(AggregatorRouter.AggregatorRouter__ExcessiveFee.selector);
        router.setFee(MAX_FEE + 1);
        router.setFee(newFee);
        assertEq(router.s_fee(), newFee);
    }

    function test__AggregatorRouter_setFeeRecipient() public {
        vm.expectRevert(Governable.Governable__NotAuthorized.selector);
        router.setFeeRecipient(bob);
        assertNotEq(router.s_feeRecipient(), bob);
        vm.prank(governor);
        router.setFeeRecipient(bob);
        assertEq(router.s_feeRecipient(), bob);
    }

    function test__AggregatorRouter_setFeeClaimer() public {
        vm.expectRevert(Governable.Governable__NotAuthorized.selector);
        router.setFeeClaimer(bob);
        assertNotEq(router.s_feeClaimer(), bob);
        vm.prank(governor);
        router.setFeeClaimer(bob);
        assertEq(router.s_feeClaimer(), bob);
    }

    function test__AggregatorRouter_setSupportedInputTokens() public {
        address[] memory whitelistTokens = new address[](1);
        bool[] memory isSupported = new bool[](1);
        whitelistTokens[0] = bob;
        isSupported[0] = true;
        vm.expectRevert(Governable.Governable__NotAuthorized.selector);
        router.setSupportedInputTokens(whitelistTokens, isSupported);
        assertFalse(router.isSupportedInputToken(bob));
        vm.prank(governor);
        router.setSupportedInputTokens(whitelistTokens, isSupported);
        assertTrue(router.isSupportedInputToken(bob));
    }

    function test__AggregatorRouter_maxApproveForUnwrapping() public {
        vm.expectRevert(Governable.Governable__NotAuthorized.selector);
        router.maxApproveForUnwrapping();
        vm.prank(governor);
        router.maxApproveForUnwrapping();
    }

    function test__AggregatorRouter_claimFees() public {
        weth.transfer(address(router), 1 ether);
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = address(weth);
        amounts[0] = 1 ether;
        vm.expectRevert(AggregatorRouter.AggregatorRouter__NotFromFeeClaimer.selector);
        router.claimFees(tokens, amounts);
        assertEq(weth.balanceOf(feeRecipient), 0);
        vm.prank(feeClaimer);
        router.claimFees(tokens, amounts);
        assertEq(weth.balanceOf(feeRecipient), 1 ether);
    }

    function test__AggregatorRouter_recoverNative() public {
        (bool success,) = payable(router).call{value: 1 ether}("");
        assertTrue(success);
        vm.expectRevert(Governable.Governable__NotAuthorized.selector);
        router.recoverNative(bob, 1 ether);
        vm.prank(governor);
        uint256 bobBalance = bob.balance;
        router.recoverNative(bob, 1 ether);
        assertEq(bob.balance, bobBalance + 1 ether);
    }

    function test__AggregatorRouter_pushDexAdapter() public {
        vm.expectRevert(Governable.Governable__NotAuthorized.selector);
        router.pushDexAdapter(bob);
        vm.prank(governor);
        router.pushDexAdapter(bob);
        assertEq(router.getDexAdapter(0), bob);
    }

    function test__AggregatorRouter_removeDexAdapter() public {
        vm.startPrank(governor);
        router.pushDexAdapter(bob);
        router.pushDexAdapter(alice);
        vm.stopPrank();
        vm.expectRevert(Governable.Governable__NotAuthorized.selector);
        router.removeDexAdapter(0);
        vm.startPrank(governor);
        router.removeDexAdapter(0);
        assertEq(router.getDexAdapter(0), alice);
        vm.expectRevert(AggregatorRouter.AggregatorRouter__OutOfBound.selector);
        router.removeDexAdapter(1);
        router.removeDexAdapter(0);
        vm.expectRevert();
        router.getDexAdapter(0);
    }

    /*     function test__Arbiter_setMinLinkDataStreams() public {
        uint64 newMinLinkDataStreams = 1e18;
        vm.expectRevert(Governable.Governable__NotAuthorized.selector);
        arbiter.setMinLinkDataStreams(newMinLinkDataStreams);
        assertNotEq(arbiter.getMinLinkDataStreams(), newMinLinkDataStreams);
        vm.prank(governor);
        arbiter.setMinLinkDataStreams(newMinLinkDataStreams);
        assertEq(arbiter.getMinLinkDataStreams(), newMinLinkDataStreams);
    }

    function test__Arbiter_setVerifier() public {
        vm.expectRevert(Governable.Governable__NotAuthorized.selector);
        arbiter.setVerifierProxy(alice);
        assertNotEq(arbiter.getVerifierProxy(), alice);
        vm.prank(governor);
        arbiter.setVerifierProxy(alice);
        assertEq(arbiter.getVerifierProxy(), alice);
    }

    function test__Arbiter_setDataFeeds() public {
        address[] memory tokens = new address[](2);
        address[] memory dataFeeds = new address[](2);
        tokens[0] = address(linkToken);
        tokens[1] = alice;
        dataFeeds[0] = rob;
        dataFeeds[1] = bob;
        vm.expectRevert(Governable.Governable__NotAuthorized.selector);
        arbiter.setDataFeeds(tokens, dataFeeds);
        assertNotEq(arbiter.getDataFeed(tokens[0]), dataFeeds[0]);
        assertNotEq(arbiter.getDataFeed(tokens[1]), dataFeeds[1]);
        vm.prank(governor);
        arbiter.setDataFeeds(tokens, dataFeeds);
        assertEq(arbiter.getDataFeed(tokens[0]), dataFeeds[0]);
        assertEq(arbiter.getDataFeed(tokens[1]), dataFeeds[1]);
        tokens = new address[](1);
        vm.prank(governor);
        vm.expectRevert(Arbiter.Arbiter__InconsistentParamsLength.selector);
        arbiter.setDataFeeds(tokens, dataFeeds);
    }

    function test__Arbiter_setDataStreams() public {
        address[] memory tokens = new address[](2);
        string[] memory feedIDs = new string[](2);
        tokens[0] = address(linkToken);
        tokens[1] = alice;
        feedIDs[0] = "feedID0";
        feedIDs[1] = "feedID1";
        vm.expectRevert(Governable.Governable__NotAuthorized.selector);
        arbiter.setDataStreams(tokens, feedIDs);
        assertNotEq(
            keccak256(abi.encodePacked(arbiter.getDataStream(tokens[0]))), keccak256(abi.encodePacked(feedIDs[0]))
        );
        assertNotEq(
            keccak256(abi.encodePacked(arbiter.getDataStream(tokens[1]))), keccak256(abi.encodePacked(feedIDs[1]))
        );
        vm.prank(governor);
        arbiter.setDataStreams(tokens, feedIDs);
        assertEq(keccak256(abi.encodePacked(arbiter.getDataStream(tokens[0]))), keccak256(abi.encodePacked(feedIDs[0])));
        assertEq(keccak256(abi.encodePacked(arbiter.getDataStream(tokens[1]))), keccak256(abi.encodePacked(feedIDs[1])));
        tokens = new address[](1);
        vm.prank(governor);
        vm.expectRevert(Arbiter.Arbiter__InconsistentParamsLength.selector);
        arbiter.setDataStreams(tokens, feedIDs);
    }

    function test__Arbiter_setArbiterJob() public {
        uint96 reserveToMinProfitRatio = 1000;
        uint96 reserveToTriggerProfitRatio = 1050;
        vm.expectRevert(Governable.Governable__NotAuthorized.selector);
        arbiter.setArbiterJob(
            address(pairMock), governor, forwarder, reserveToMinProfitRatio, reserveToTriggerProfitRatio, 0, 0
        );
        vm.startPrank(governor);
        vm.expectRevert(Arbiter.Arbiter__NotManager.selector);
        arbiter.setArbiterJob(
            address(pairMock), governor, forwarder, reserveToMinProfitRatio, reserveToTriggerProfitRatio, 0, 0
        );
        pairMock.setManager(address(arbiter));
        vm.expectRevert(Arbiter.Arbiter__DataFeedNotSet.selector);
        arbiter.setArbiterJob(
            address(pairMock), governor, forwarder, reserveToMinProfitRatio, reserveToTriggerProfitRatio, 0, 0
        );
        setDataFeed(arbiter, address(linkToken), bob);
        setDataFeed(arbiter, address(mockToken), rob);
        vm.expectRevert(Arbiter.Arbiter__InvalidProfitToReservesRatio.selector);
        arbiter.setArbiterJob(address(pairMock), governor, forwarder, reserveToMinProfitRatio, 1112, 0, 0);
        arbiter.setArbiterJob(
            address(pairMock), governor, forwarder, reserveToMinProfitRatio, reserveToTriggerProfitRatio, 0, 0
        );
        (
            address rewardVault,
            uint96 jobMinProfitRatio,
            address automationForwarder,
            uint96 jobTriggerProfitRatio,
            address token0,
            uint8 token0Decimals,
            address token1,
            uint8 token1Decimals
        ) = arbiter.getJobConfig(address(pairMock));
        assertEq(rewardVault, governor);
        assertEq(jobMinProfitRatio, reserveToMinProfitRatio);
        assertEq(automationForwarder, forwarder);
        assertEq(jobTriggerProfitRatio, reserveToTriggerProfitRatio);
        assertEq(token0, address(linkToken));
        assertEq(token1, address(mockToken));
        assertEq(token0Decimals, linkToken.decimals());
        assertEq(token1Decimals, mockToken.decimals());
        arbiter.setArbiterJob(
            address(pairMock), governor, bob, reserveToMinProfitRatio, reserveToTriggerProfitRatio, 8, 0
        );
        (
            rewardVault,
            jobMinProfitRatio,
            automationForwarder,
            jobTriggerProfitRatio,
            token0,
            token0Decimals,
            token1,
            token1Decimals
        ) = arbiter.getJobConfig(address(pairMock));
        assertEq(token0Decimals, 8);
        assertEq(token1Decimals, mockToken.decimals());
        vm.stopPrank();
    }

    function test__Arbiter_deleteArbiterJob() public {
        vm.startPrank(governor);
        pairMock.setManager(address(arbiter));
        setDataFeed(arbiter, address(linkToken), bob);
        setDataFeed(arbiter, address(mockToken), rob);
        arbiter.setArbiterJob(address(pairMock), governor, forwarder, 420, 420, 0, 0);
        vm.stopPrank();
        vm.expectRevert(Governable.Governable__NotAuthorized.selector);
        arbiter.deleteArbiterJob(address(pairMock));
        vm.prank(governor);
        arbiter.deleteArbiterJob(address(pairMock));
        (
            address rewardVault,
            uint96 jobMinProfitUSD,
            address automationForwarder,
            uint96 jobTriggerProfitUSD,
            address token0,
            uint8 token0Decimals,
            address token1,
            uint8 token1Decimals
        ) = arbiter.getJobConfig(address(pairMock));
        assertEq(rewardVault, address(0));
        assertEq(jobMinProfitUSD, uint96(0));
        assertEq(automationForwarder, address(0));
        assertEq(jobTriggerProfitUSD, uint96(0));
        assertEq(token0, address(0));
        assertEq(token1, address(0));
        assertEq(token0Decimals, uint8(0));
        assertEq(token1Decimals, uint8(0));
    }

    function test__Arbiter_pushDexAdapter() public {
        vm.expectRevert(Governable.Governable__NotAuthorized.selector);
        arbiter.pushDexAdapter(bob);
        vm.prank(governor);
        arbiter.pushDexAdapter(bob);
        assertEq(arbiter.getDexAdapter(0), bob);
    }

    function test__Arbiter_removeDexAdapter() public {
        vm.startPrank(governor);
        arbiter.pushDexAdapter(bob);
        arbiter.pushDexAdapter(rob);
        vm.stopPrank();
        vm.expectRevert(Governable.Governable__NotAuthorized.selector);
        arbiter.removeDexAdapter(0);
        vm.startPrank(governor);
        arbiter.removeDexAdapter(0);
        assertEq(arbiter.getDexAdapter(0), rob);
        vm.expectRevert(Arbiter.Arbiter__OutOfBound.selector);
        arbiter.removeDexAdapter(1);
        arbiter.removeDexAdapter(0);
        vm.expectRevert();
        arbiter.getDexAdapter(0);
    }

    function test__Arbiter__performUpkeepRevertIfNotForwarder() public {
        vm.startPrank(governor);
        pairMock.setManager(address(arbiter));
        setDataFeed(arbiter, address(linkToken), bob);
        setDataFeed(arbiter, address(mockToken), rob);
        arbiter.setArbiterJob(address(pairMock), governor, forwarder, 1000, 1000, 0, 0);
        vm.stopPrank();
        Arbiter.ArbiterCall memory call;
        call.selfBalancingPool = address(pairMock);
        vm.expectRevert(Arbiter.Arbiter__NotFromForwarder.selector);
        arbiter.performUpkeep(abi.encode(new bytes[](0), call));
    }

    function test__Arbiter_recoverERC20() public {
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = address(linkToken);
        amounts[0] = 1 ether;
        vm.expectRevert(Governable.Governable__NotAuthorized.selector);
        arbiter.recoverERC20(bob, tokens, amounts);
        vm.startPrank(governor);
        linkToken.transfer(address(arbiter), 1 ether);
        assertEq(linkToken.balanceOf(address(arbiter)), 1 ether);
        assertEq(linkToken.balanceOf(bob), 0);
        arbiter.recoverERC20(bob, tokens, amounts);
        assertEq(linkToken.balanceOf(address(arbiter)), 0);
        assertEq(linkToken.balanceOf(bob), 1 ether);
        vm.stopPrank();
    } */
}
