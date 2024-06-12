//SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IAggregatorRouter} from "./interfaces/IAggregatorRouter.sol";
import {IDexAdapter} from "./interfaces/IDexAdapter.sol";
import {Governable} from "flashliquidity-acs/contracts/Governable.sol";

/**
 * @title AggregatorRouter
 * @author Oddcod3 (@oddcod3)
 * @notice This contract serves as a DEX aggregator, routing trades through multiple DEXes to ensure users receive the best possible trade execution. It supports both single and multiple route trades.
 * @dev The contract utilizes adapters for different DEXes to handle token swaps. It also provides detailed views to determine the best trade routes and query DEX adapter outputs based on current liquidity and pricing.
 */
contract AggregatorRouter is IAggregatorRouter, Governable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ///////////////////////
    // Errors            //
    ///////////////////////

    error AggregatorRouter__InconsistentParamsLength();
    error AggregatorRouter__NativeTransferFailed();
    error AggregatorRouter__OutOfBound();
    error AggregatorRouter__InsufficientAmountOut();
    error AggregatorRouter__InsufficientAmountIn();
    error AggregatorRouter__ZeroAmountIn();
    error AggregatorRouter__ZeroAmountOutMin();
    error AggregatorRouter__InvalidTrade();
    error AggregatorRouter__ExcessiveFee();
    error AggregatorRouter__NotFromFeeClaimer();
    error AggregatorRouter__UnsupportedInputToken();
    error AggregatorRouter__InvalidPathLength();

    ///////////////////////
    // State Variables   //
    ///////////////////////

    /// @dev Max value in basis points that fee can be set to
    uint256 public constant MAX_FEE = 10;
    /// @dev Basis points constant
    uint256 private constant BPS = 10_000;
    /// @dev Wrapped native.
    IWETH private immutable i_weth;
    /// @dev Array of DEX adapter interfaces used for handling token swaps.
    IDexAdapter[] private s_adapters;
    /// @dev Fee applyied to input token
    uint24 public s_fee;
    /// @dev Fees claimer address
    address public s_feeClaimer;
    /// @dev Fees recipient
    address public s_feeRecipient;
    /// @dev Mapping of supported tokens.
    mapping(address token => bool isSupported) private s_isSupportedInputToken;

    ///////////////////////
    // Events            //
    ///////////////////////

    event DexAdapterAdded(address adapter);
    event DexAdapterRemoved(address adapter);
    event Swapped(
        address indexed tokenIn, address indexed tokenOut, address indexed to, uint256 amountIn, uint256 amountOut
    );
    event FeeChanged(uint24 newFee);
    event FeeClaimerChanged(address newFeeClaimer);
    event FeeRecipientChanged(address newFeeRecipient);
    event SupportedInputTokensChanged(address[] tokens, bool[] isSupported);

    ////////////////////////
    // Functions          //
    ////////////////////////

    constructor(address governor, address weth, uint24 fee, address feeRecipient, address feeClaimer)
        Governable(governor)
    {
        i_weth = IWETH(weth);
        s_isSupportedInputToken[weth] = true;
        _setFee(fee);
        _setFeeRecipient(feeRecipient);
        _setFeeClaimer(feeClaimer);
        _maxApproveForUnwrapping();
    }

    ////////////////////////
    // External Functions //
    ////////////////////////

    receive() external payable {}

    /// @inheritdoc IAggregatorRouter
    function setFee(uint24 fee) external onlyGovernor {
        _setFee(fee);
    }

    /// @inheritdoc IAggregatorRouter
    function setFeeRecipient(address recipient) external onlyGovernor {
        _setFeeRecipient(recipient);
    }

    /// @inheritdoc IAggregatorRouter
    function setFeeClaimer(address claimer) external onlyGovernor {
        _setFeeClaimer(claimer);
    }

    /// @inheritdoc IAggregatorRouter
    function setSupportedInputTokens(address[] calldata tokens, bool[] calldata isSupported) external onlyGovernor {
        uint256 tokensLen = tokens.length;
        if (tokensLen != isSupported.length) revert AggregatorRouter__InconsistentParamsLength();
        for (uint256 i; i < tokensLen;) {
            s_isSupportedInputToken[tokens[i]] = isSupported[i];
            unchecked {
                ++i;
            }
        }
        emit SupportedInputTokensChanged(tokens, isSupported);
    }

    /// @inheritdoc IAggregatorRouter
    function pushDexAdapter(address adapter) external onlyGovernor {
        s_adapters.push(IDexAdapter(adapter));
        emit DexAdapterAdded(adapter);
    }

    /// @inheritdoc IAggregatorRouter
    function removeDexAdapter(uint256 adapterIndex) external onlyGovernor {
        uint256 adaptersLen = s_adapters.length;
        if (adaptersLen == 0 || adapterIndex >= adaptersLen) revert AggregatorRouter__OutOfBound();
        address dexAdapter = address(s_adapters[adapterIndex]);
        if (adapterIndex < adaptersLen - 1) {
            s_adapters[adapterIndex] = s_adapters[adaptersLen - 1];
        }
        s_adapters.pop();
        emit DexAdapterRemoved(dexAdapter);
    }

    /// @inheritdoc IAggregatorRouter
    function claimFees(address[] memory tokens, uint256[] memory amounts) external {
        address feeClaimer = s_feeClaimer;
        if (feeClaimer != address(0) && feeClaimer != msg.sender) revert AggregatorRouter__NotFromFeeClaimer();
        uint256 tokensLen = tokens.length;
        address feeRecipient = s_feeRecipient;
        if (tokensLen != amounts.length) revert AggregatorRouter__InconsistentParamsLength();
        for (uint256 i; i < tokensLen;) {
            IERC20(tokens[i]).safeTransfer(feeRecipient, amounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IAggregatorRouter
    function recoverNative(address to, uint256 amount) external onlyGovernor {
        (bool success,) = payable(to).call{value: amount}("");
        if (!success) revert AggregatorRouter__NativeTransferFailed();
    }

    /// @inheritdoc IAggregatorRouter
    function maxApproveForUnwrapping() external onlyGovernor {
        _maxApproveForUnwrapping();
    }

    /// @inheritdoc IAggregatorRouter
    function findBestRouteAndSwap(TradeParams memory trade) external payable nonReentrant returns (uint256 amountOut) {
        bool nativeOut;
        address to;
        (trade, nativeOut, to) = _validateTradeAndHandleTokens(trade);
        uint256 amountInWithFee = _applyFee(trade.amountIn, s_fee);
        uint256 pathLen = trade.path.length - 1;
        amountOut = _findBestRouteAndSwap(trade, amountInWithFee, pathLen);
        if (nativeOut) _unwrapNative(amountOut, to);
        emit Swapped(trade.path[0], trade.path[pathLen], to, trade.amountIn, amountOut);
    }

    /// @inheritdoc IAggregatorRouter
    function swapSingleRoute(TradeParams memory trade, AdapterParams[] memory adapterParams)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        bool nativeOut;
        address to;
        (trade, nativeOut, to) = _validateTradeAndHandleTokens(trade);
        uint256 pathLen = trade.path.length - 1;
        if (pathLen != adapterParams.length) revert AggregatorRouter__InconsistentParamsLength();
        uint256 amountInWithFee = _applyFee(trade.amountIn, s_fee);
        amountOut = _executeSwaps(trade, adapterParams, amountInWithFee, pathLen, true);
        if (nativeOut) _unwrapNative(amountOut, to);
        emit Swapped(trade.path[0], trade.path[pathLen], to, trade.amountIn, amountOut);
    }

    /// @inheritdoc IAggregatorRouter
    function swapSplitRoutes(
        TradeParams memory trade,
        AdapterParams[][] memory adaptersParams,
        uint256[] memory amountsIn
    ) external payable nonReentrant returns (uint256 amountOut) {
        bool nativeOut;
        address to;
        (trade, nativeOut, to) = _validateTradeAndHandleTokens(trade);
        uint256 routesLen = amountsIn.length;
        if (routesLen != adaptersParams.length) revert AggregatorRouter__InconsistentParamsLength();
        uint256 pathLen = trade.path.length - 1;
        uint24 fee = s_fee;
        uint256 remainingAmountInWithFee = _applyFee(trade.amountIn, fee);
        uint256 amountInWithFee;
        for (uint256 i; i < routesLen;) {
            amountInWithFee = _applyFee(amountsIn[i], fee);
            if (remainingAmountInWithFee < amountInWithFee) revert AggregatorRouter__InsufficientAmountIn();
            remainingAmountInWithFee = remainingAmountInWithFee - amountInWithFee;
            amountOut += _executeSwaps(trade, adaptersParams[i], amountsIn[i], pathLen, false);
            unchecked {
                ++i;
            }
        }
        if (amountOut < trade.amountOutMin) revert AggregatorRouter__InsufficientAmountOut();
        if (nativeOut) _unwrapNative(amountOut, to);
        emit Swapped(trade.path[0], trade.path[pathLen], to, trade.amountIn, amountOut);
    }

    /**
     * @dev This internal function handles the swap execution through a specific adapter, ensuring that the token has the necessary approvals and that the input token is supported.
     * @param tokenIn The address of the token to be swapped.
     * @param tokenOut The address of the token to receive.
     * @param to The destination address for the output tokens.
     * @param amountIn The amount of the `tokenIn` to swap.
     * @param amountOutMin The minimum acceptable amount of `tokenOut` to receive, protecting against slippage.
     * @param adapterIndex The index in the `s_adapters` array of the DEX adapter to use.
     * @param adapterArg Additional arguments required by the specific DEX adapter, potentially including data such as slippage tolerance or deadline timestamps.
     * @return adapterAmountOut The amount of `tokenOut` received from the swap.
     */
    function _swapWithAdapter(
        address tokenIn,
        address tokenOut,
        address to,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 adapterIndex,
        bytes memory adapterArg
    ) internal returns (uint256 adapterAmountOut) {
        if (!s_isSupportedInputToken[tokenIn]) revert AggregatorRouter__UnsupportedInputToken();
        IDexAdapter adapter = s_adapters[adapterIndex];
        IERC20(tokenIn).forceApprove(address(adapter), amountIn);
        return adapter.swap(tokenIn, tokenOut, to, amountIn, amountOutMin, adapterArg);
    }

    /**
     * @notice Executes a series of token swaps through selected DEX adapters according to the specified route and adapter parameters.
     * @dev This internal function iterates over a trade path and executes swaps using the specified adapters, handling token approvals internally.
     * @param trade The trade parameters structured as a `TradeParams` which includes the path, destination, and slippage details.
     * @param adapterParams An array of `AdapterParams`, with each containing details such as the adapter index and any necessary arguments for the swap.
     * @param amountInWithFee The initial amount of tokens to start the swap sequence, after deducting any applicable fees.
     * @param pathLen The length of the trade path (i.e., the number of swaps to perform).
     * @param checkLastSwapStepAmountOut A boolean to determine if the last swap in the sequence should enforce a minimum amount out check for slippage protection.
     * @return amountOut The final amount of output tokens received after all swaps are executed.
     */
    function _executeSwaps(
        TradeParams memory trade,
        AdapterParams[] memory adapterParams,
        uint256 amountInWithFee,
        uint256 pathLen,
        bool checkLastSwapStepAmountOut
    ) internal returns (uint256 amountOut) {
        address swapStepTo;
        uint256 amountOutMin;
        if (pathLen != adapterParams.length) revert AggregatorRouter__InconsistentParamsLength();
        for (uint256 i = 0; i < pathLen;) {
            if (i == pathLen - 1) {
                swapStepTo = trade.to;
                amountOutMin = checkLastSwapStepAmountOut ? trade.amountOutMin : 0;
            } else {
                swapStepTo = address(this);
                amountOutMin = 0;
            }
            amountInWithFee = _swapWithAdapter(
                trade.path[i],
                trade.path[i + 1],
                swapStepTo,
                amountInWithFee,
                amountOutMin,
                adapterParams[i].index,
                adapterParams[i].extraArgs
            );
            unchecked {
                ++i;
            }
        }
        return amountInWithFee;
    }

    /**
     * @dev Scans all available DEX adapters to determine the best swap route that offers the highest output for a given input amount along a specified path.
     * @param path An array of token addresses defining the swap route.
     * @param amountIn The amount of input tokens available for swapping.
     * @param pathLen The number of swaps in the path.
     * @return maxOutput The maximum amount of output tokens that can be obtained through the best route.
     * @return adaptersParams An array of `AdapterParams` that contains the best adapter index and specific arguments for each swap in the path.
     */
    function _findBestRoute(address[] memory path, uint256 amountIn, uint256 pathLen)
        private
        view
        returns (uint256 maxOutput, AdapterParams[] memory adaptersParams)
    {
        IDexAdapter[] memory adapters = s_adapters;
        uint256 adaptersLen = adapters.length;
        uint256 tempOutput;
        bytes memory tempExtraArgs;
        adaptersParams = new AdapterParams[](pathLen);
        for (uint256 i; i < pathLen;) {
            for (uint256 j; j < adaptersLen;) {
                (tempOutput, tempExtraArgs) = adapters[i].getMaxOutput(path[i], path[i + 1], amountIn);
                if (tempOutput > maxOutput) {
                    maxOutput = tempOutput;
                    adaptersParams[i].index = j;
                    adaptersParams[i].extraArgs = tempExtraArgs;
                }
                unchecked {
                    ++j;
                }
            }
            amountIn = maxOutput;
            unchecked {
                ++i;
            }
        }
        maxOutput = amountIn;
    }

    /**
     * @dev Finds the optimal swap route and then executes the swaps sequentially using the identified adapters and parameters.
     * @param trade The `TradeParams` struct containing trade details such as the path, destination, and minimum required output.
     * @param amountInWithFee The initial amount of input tokens available for swapping, already adjusted for any applicable fees.
     * @param pathLen The number of swaps (transitions between tokens) in the path.
     * @return amountOut The total output received after executing the swaps along the best route.
     */
    function _findBestRouteAndSwap(TradeParams memory trade, uint256 amountInWithFee, uint256 pathLen)
        private
        returns (uint256 amountOut)
    {
        (uint256 maxOutput, AdapterParams[] memory adapterParams) = _findBestRoute(trade.path, amountInWithFee, pathLen);
        if (maxOutput < trade.amountOutMin) revert AggregatorRouter__InsufficientAmountOut();
        amountOut = _executeSwaps(trade, adapterParams, amountInWithFee, pathLen, false);
    }

    /// @param amount The amount of native token to unwrap.
    /// @param to The receiver of the unwrapped native token.
    function _unwrapNative(uint256 amount, address to) internal {
        i_weth.withdraw(amount);
        (bool success,) = payable(to).call{value: amount}("");
        if (!success) revert AggregatorRouter__NativeTransferFailed();
    }

    function _maxApproveForUnwrapping() internal {
        IERC20(address(i_weth)).approve(address(i_weth), type(uint256).max);
    }

    /// @param amount The input token amount to apply the fee
    /// @param fee The fee value in basis points.
    function _applyFee(uint256 amount, uint24 fee) internal pure returns (uint256) {
        return fee == 0 ? amount : amount - amount * fee / BPS;
    }

    /// @param fee The new aggregator fee.
    function _setFee(uint24 fee) private {
        if (fee > MAX_FEE) revert AggregatorRouter__ExcessiveFee();
        s_fee = fee;
        emit FeeChanged(fee);
    }

    /// @param feeClaimer The new fee claimer.
    function _setFeeClaimer(address feeClaimer) private {
        s_feeClaimer = feeClaimer;
        emit FeeClaimerChanged(feeClaimer);
    }

    /// @param feeRecipient The new fee recipient.
    function _setFeeRecipient(address feeRecipient) private {
        s_feeRecipient = feeRecipient;
        emit FeeRecipientChanged(feeRecipient);
    }

    /**
     * @notice Validates trade parameters and adjusts the trade setup based on whether the input or output is the native currency.
     * @param trade The `TradeParams` struct containing the details of the trade.
     * @return TradeParams The modified `TradeParams` struct reflecting any changes made for native currency handling.
     * @return nativeOut Indicates whether the output token is the native currency.
     * @return to The address to which the output tokens will be sent.
     * @notice Reverts if the trade path is less than 2 addresses, indicating an invalid path.
     * @notice Reverts if the input token is the same as the output token, indicating an invalid trade setup.
     * @notice Reverts if the minimum output amount (`amountOutMin`) is zero, as this could expose the user to high slippage.
     * @notice Reverts if the input amount (`amountIn`) is zero, as no trade can be made with zero input.
     */
    function _validateTradeAndHandleTokens(TradeParams memory trade)
        internal
        returns (TradeParams memory, bool nativeOut, address to)
    {
        uint256 pathLen = trade.path.length;
        if (pathLen < 2) revert AggregatorRouter__InvalidPathLength();
        address tokenIn = trade.path[0];
        address tokenOut = trade.path[pathLen - 1];
        if (pathLen == 2 && tokenIn == tokenOut) revert AggregatorRouter__InvalidTrade();
        if (trade.amountOutMin == 0) revert AggregatorRouter__ZeroAmountOutMin();
        bool nativeIn = tokenIn == address(0);
        nativeOut = tokenOut == address(0);
        if (!nativeIn) IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), trade.amountIn);
        to = trade.to;
        if (nativeIn) {
            trade.amountIn = msg.value;
            i_weth.deposit{value: msg.value}();
            trade.path[0] = address(i_weth);
        } if (nativeOut) {
            trade.to = address(this);
            trade.path[pathLen - 1] = address(i_weth);
        }
        if (trade.amountIn == 0) revert AggregatorRouter__ZeroAmountIn();
        return (trade, nativeOut, to);
    }

    /// @inheritdoc IAggregatorRouter
    function getBestRoute(address[] memory path, uint256 amountIn)
        external
        view
        returns (uint256 maxOutput, AdapterParams[] memory params)
    {
        uint256 pathLen = path.length - 1;
        if (path[0] == address(0)) path[0] = address(i_weth);
        if (path[pathLen] == address(0)) path[pathLen] = address(i_weth);
        uint256 amountInWithFee = _applyFee(amountIn, s_fee);
        (maxOutput, params) = _findBestRoute(path, amountInWithFee, pathLen);
    }

    /// @inheritdoc IAggregatorRouter
    function getAdaptersOutputsFromArgs(
        address tokenIn,
        address tokenOut,
        uint256[] memory amountsIn,
        AdapterParams[] memory adaptersParams
    ) external view returns (uint256[] memory amountsOut) {
        uint256 routesLen = amountsIn.length;
        if (routesLen != adaptersParams.length) {
            revert AggregatorRouter__InconsistentParamsLength();
        }
        amountsOut = new uint256[](routesLen);
        AdapterParams memory tempAdapterParams;
        uint24 fee = s_fee;
        for (uint256 i; i < routesLen;) {
            tempAdapterParams = adaptersParams[i];
            (amountsOut[i]) = s_adapters[tempAdapterParams.index].getOutputFromArgs(
                tokenIn, tokenOut, _applyFee(amountsIn[i], fee), tempAdapterParams.extraArgs
            );
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IAggregatorRouter
    function getAdaptersArgs(address tokenIn, address tokenOut, uint256[] memory adapterIndexes)
        external
        view
        returns (bytes[][] memory adaptersArgs)
    {
        uint256 indexesLen = adapterIndexes.length;
        adaptersArgs = new bytes[][](indexesLen);
        for (uint256 i; i < indexesLen;) {
            adaptersArgs[i] = s_adapters[adapterIndexes[i]].getAdapterArgs(tokenIn, tokenOut);
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IAggregatorRouter
    function getAllAdapterOutputsAndArgs(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256[][] memory amountsOut, bytes[][] memory adaptersArgs)
    {
        uint256 allAdaptersLen = s_adapters.length;
        amountsOut = new uint256[][](allAdaptersLen);
        adaptersArgs = new bytes[][](allAdaptersLen);
        uint256 amountInWithFee = _applyFee(amountIn, s_fee);
        bytes[] memory tempAdapterArgs;
        uint256[] memory tempAmountOuts;
        uint256 tempAdapterLen;
        IDexAdapter adapter;
        for (uint256 i; i < allAdaptersLen;) {
            adapter = s_adapters[i];
            tempAdapterArgs = adapter.getAdapterArgs(tokenIn, tokenOut);
            tempAdapterLen = tempAdapterArgs.length;
            tempAmountOuts = new uint256[](tempAdapterLen);
            for (uint256 j; j < tempAdapterLen;) {
                tempAmountOuts[j] = adapter.getOutputFromArgs(tokenIn, tokenOut, amountInWithFee, tempAdapterArgs[j]);
                unchecked {
                    ++j;
                }
            }
            amountsOut[i] = tempAmountOuts;
            adaptersArgs[i] = tempAdapterArgs;
            unchecked {
                ++i;
            }
        }
        return (amountsOut, adaptersArgs);
    }

    /// @inheritdoc IAggregatorRouter
    function isSupportedInputToken(address token) external view returns (bool) {
        return s_isSupportedInputToken[token];
    }

    /// @inheritdoc IAggregatorRouter
    function getDexAdapter(uint256 adapterIndex) external view returns (address) {
        return address(s_adapters[adapterIndex]);
    }

    /// @inheritdoc IAggregatorRouter
    function allAdaptersLength() external view returns (uint256) {
        return s_adapters.length;
    }
}
