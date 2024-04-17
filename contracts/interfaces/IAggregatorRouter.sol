// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @title IAggregatorRouter
 * @author Oddcod3 (@oddcod3)
 */
interface IAggregatorRouter {
    /**
     * @notice This struct defines the parameters necessary to execute a trade.
     * @param path An array of token addresses representing the swap path the trade will take. Each address is a token that is part of the swap sequence.
     * @param to The destination address where the output tokens from the trade should be sent.
     * @param amountIn The amount of the input token to be swapped.
     * @param amountOutMin The minimum amount of the output token that must be received for the trade to succeed. This parameter is used to ensure slippage protection.
     */
    struct TradeParams {
        address[] path;
        address to;
        uint256 amountIn;
        uint256 amountOutMin;
    }

    /**
     * @notice This struct encapsulates the adapter-specific parameters required to execute a trade.
     * @dev Used by trading functions to pass necessary details to the selected DEX adapter.
     * @param index The index of the DEX adapter in the contract's adapter list that should be used for the trade. This helps identify which adapter to invoke.
     * @param extraArgs A dynamic bytes array containing any additional arguments or data required by the specified DEX adapter. This can include signatures, slippage rates, deadlines, etc., depending on the adapter’s needs.
     */
    struct AdapterParams {
        uint256 index;
        bytes extraArgs;
    }

    /**
     * @dev Sets the aggregator fee.
     * @param fee New transaction fee in basis points.
     * @notice Only callable by the governor. Reverts if `fee` exceeds `MAX_FEE`.
     */
    function setFee(uint24 fee) external;

    /**
     * @dev Sets the fee recipient address.
     * @param recipient The address to receive the fees.
     * @notice Only callable by the governor.
     */
    function setFeeRecipient(address recipient) external;

    /**
     * @dev Sets the fee claimer address.
     * @param claimer The address authorized to claim fees.
     * @notice Only callable by the governor.
     */
    function setFeeClaimer(address claimer) external;

    /**
     * @dev Updates the list of supported input tokens.
     * @param tokens Array of token addresses.
     * @param isSupported Array indicating if each token is supported.
     * @notice Only callable by the governor. Reverts if the length of `tokens` does not match the length of `isSupported`.
     */
    function setSupportedInputTokens(address[] calldata tokens, bool[] calldata isSupported) external;

    /**
     * @dev Adds a new adapter to the Aggregator's list of adapters.
     * @param adapter The address of the new adapter to be added.
     */
    function pushDexAdapter(address adapter) external;

    /**
     * @dev Removes an adapter from the Aggregator's list of adapters using its index.
     * @param adapterIndex The index (position) of the adapter in the Aggregator's adapter list that is to be removed.
     * @notice It's important to ensure that the index provided is correct, otherwise the wrong adapter will be removed.
     */
    function removeDexAdapter(uint256 adapterIndex) external;

    /**
     * @dev Allows the fee claimer to transfer collected fees to the fee recipient.
     * @param tokens Array of token addresses for which fees will be transferred.
     * @param amounts Array of amounts to be transferred for each token.
     * @notice Reverts if called by any address other than the fee claimer (if set) or if arrays `tokens` and `amounts` length mismatch.
     */
    function claimFees(address[] memory tokens, uint256[] memory amounts) external;

    /**
     * @dev Recover stucked native currency to a specified address.
     * @param to Address to which the native currency will be sent.
     * @param amount The amount of native currency to send.
     * @notice Only callable by the governor. Reverts if the transfer fails.
     */
    function recoverNative(address to, uint256 amount) external;

    /**
     * @dev Resets approval for maximum token unwrapping.
     * @notice Only callable by the governor.
     */
    function maxApproveForUnwrapping() external;

    /**
     * @dev Finds the best route for a trade and executes it.
     * @param trade A `TradeParams` struct containing trade parameters.
     * @return amountOut The output amount of the trade.
     * @notice Reverts if the final amount out is less than `amountOutMin` field specified in the TradeParams struct.
     */
    function findBestRouteAndSwap(TradeParams memory trade) external payable returns (uint256 amountOut);

    /**
     * @dev Executes a swap via a single route based on pre-specified adapter parameters.
     * @param trade A `TradeParams` struct containing trade parameters.
     * @param adapterParams Array of `AdapterParams` for each step in the trade route.
     * @return amountOut The output amount of the trade.
     * @notice Reverts if the final amount out is less than `amountOutMin` field specified in the TradeParams struct.
     * @notice Reverts if the number of steps in `trade.path` (trade.path.length - 1) does not match the length of `adapterParams`.
     */
    function swapSingleRoute(TradeParams memory trade, AdapterParams[] memory adapterParams)
        external
        payable
        returns (uint256 amountOut);

    /**
     * @dev Executes a swap split across multiple routes.
     * @param trade A `TradeParams` struct containing trade parameters.
     * @param adaptersParams A bi-dimensional array of `AdapterParams` arrays, each corresponding to a route.
     * @param amountsIn Array of input amounts for each route.
     * @return amountOut The total output amount of all trades.
     * @dev Reverts if the sum of specified input amounts exceeds the total input amount or if the final output is below `amountOutMin`.
     */
    function swapSplitRoutes(
        TradeParams memory trade,
        AdapterParams[][] memory adaptersParams,
        uint256[] memory amountsIn
    ) external payable returns (uint256 amountOut);

    /**
     * @notice Returns the best available trade route and the corresponding adapter parameters for a given amount of an input token to an output token.
     * @param path Array of token addresses representing the swap path.
     * @param amountIn The amount of the input token.
     * @return maxOutput The maximum output amount obtainable.
     * @return params Array of `AdapterParams` containing the best route details.
     */
    function getBestRoute(address[] memory path, uint256 amountIn)
        external
        view
        returns (uint256 maxOutput, AdapterParams[] memory params);

    /**
     * @notice Determines supported adapters outputs based on specific arguments for each adapter.
     * @param tokenIn The input token address.
     * @param tokenOut The output token address.
     * @param amountsIn Array of input amounts for each adapter.
     * @param adaptersParams Array of `AdapterParams` detailing each adapter's arguments.
     * @return amountsOut Array of output amounts for each adapter query.
     */
    function getAdaptersOutputsFromArgs(
        address tokenIn,
        address tokenOut,
        uint256[] memory amountsIn,
        AdapterParams[] memory adaptersParams
    ) external view returns (uint256[] memory amountsOut);

    /// @param token The token to check if it's supported
    /// @return isSupported True if the token is supported, false otherwise.
    function isSupportedInputToken(address token) external view returns (bool isSupported);

    /**
     * @dev Retrieves the adapter-specific arguments for each specified adapter given the input and output tokens.
     * @param tokenIn The input token address for which adapter arguments are queried.
     * @param tokenOut The output token address for which adapter arguments are queried.
     * @param adapterIndexes An array of indices representing the specific adapters.
     * @return adaptersArgs A two-dimensional byte array containing adapter-specific arguments.
     * @notice This function provides the necessary arguments that each adapter requires to perform swaps from `tokenIn` to `tokenOut`.
     */
    function getAdaptersArgs(address tokenIn, address tokenOut, uint256[] memory adapterIndexes)
        external
        view
        returns (bytes[][] memory adaptersArgs);

    /**
     * @dev Fetches all potential outputs and corresponding adapter arguments for a given token pair and input amount from all adapters.
     * @param tokenIn The input token address.
     * @param tokenOut The output token address.
     * @param amountIn The input amount of the token.
     * @return amountsOut A two-dimensional array of potential output amounts for each adapter.
     * @return adaptersArgs A two-dimensional byte array containing adapter-specific arguments for each adapter.
     * @notice Calculates potential swap outputs for every registered adapter, accounting for the fee. This helps in comparing which adapter offers the best terms for a swap.
     */
    function getAllAdapterOutputsAndArgs(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256[][] memory amountsOut, bytes[][] memory adaptersArgs);

    /// @param adapterIndex The index (position) of the adapter in the Arbiter's adapters list.
    /// @return adapter The address of the adapter located at the specified 'adapterIndex' in the list.
    function getDexAdapter(uint256 adapterIndex) external view returns (address adapter);

    /// @return adaptersLength The number of adapters currently registered
    function allAdaptersLength() external view returns (uint256 adaptersLength);
}
