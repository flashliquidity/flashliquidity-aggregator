//SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFlashLiquidityPair} from "../interfaces/IFlashLiquidityPair.sol";
import {IFlashLiquidityFactory} from "../interfaces/IFlashLiquidityFactory.sol";
import {Governable} from "flashliquidity-acs/contracts/Governable.sol";
import {DexAdapter} from "./DexAdapter.sol";

/**
 * @title FlashLiquidityAdapter
 * @author Oddcod3 (@oddcod3)
 */
contract FlashLiquidityAdapter is DexAdapter, Governable {
    using SafeERC20 for IERC20;

    error FlashLiquidityAdapter__OutOfBound();
    error FlashLiquidityAdapter__NotRegisteredFactory();
    error FlashLiquidityAdapter__FactoryAlreadyRegistered();
    error FlashLiquidityAdapter__InvalidPool();
    error FlashLiquidityAdapter__InsufficientOutput();

    struct FlashLiquidityFactoryData {
        bool isRegistered;
        uint48 feeNumerator;
        uint48 feeDenominator;
    }

    /// @dev Array of Uniswap V2 Factory interfaces that the contract interacts with.
    IFlashLiquidityFactory[] private s_factories;
    /// @dev A mapping from Uniswap V2 Factory addresses to their respective data structures.
    mapping(address => FlashLiquidityFactoryData) private s_factoryData;

    constructor(address governor, string memory description) DexAdapter(description) Governable(governor) {}

    /**
     * @dev Registers a new factory in the adapter with specific fee parameters. This function can only be called by the contract's governor.
     * @param factory The address of the UniswapV2 factory to be registered.
     * @param feeNumerator The numerator part of the fee fraction for this factory.
     * @param feeDenominator The denominator part of the fee fraction for this factory.
     * @notice This function will revert with 'UniswapV2Adapter__FactoryAlreadyRegistered' if the factory is already registered.
     *         It sets the factory as registered and stores its fee structure.
     */
    function addFactory(address factory, uint48 feeNumerator, uint48 feeDenominator) external onlyGovernor {
        FlashLiquidityFactoryData storage factoryData = s_factoryData[factory];
        if (factoryData.isRegistered) revert FlashLiquidityAdapter__FactoryAlreadyRegistered();
        factoryData.isRegistered = true;
        factoryData.feeNumerator = feeNumerator;
        factoryData.feeDenominator = feeDenominator;
        s_factories.push(IFlashLiquidityFactory(factory));
    }

    /**
     * @dev Removes a factory from the list. This function can only be called by the contract's governor.
     * @param factoryIndex The index of the factory in the s_factories array to be removed.
     * @notice If the factoryIndex is out of bounds of s_factories array, the function will revert with 'UniswapV2Adapter__OutOfBound'.
     *         This function deletes the factory's data and removes it from the s_factories array.
     * @notice Care must be taken to pass the correct factoryIndex, as an incorrect index can result in the removal of the wrong factory.
     */
    function removeFactory(uint256 factoryIndex) external onlyGovernor {
        uint256 factoriesLen = s_factories.length;
        if (factoriesLen == 0 || factoryIndex >= factoriesLen) revert FlashLiquidityAdapter__OutOfBound();
        delete s_factoryData[address(s_factories[factoryIndex])];
        if (factoryIndex < factoriesLen - 1) {
            s_factories[factoryIndex] = s_factories[factoriesLen - 1];
        }
        s_factories.pop();
    }

    /// @inheritdoc DexAdapter
    function _swap(
        address tokenIn,
        address tokenOut,
        address to,
        uint256 amountIn,
        uint256 amountOutMin,
        bytes memory extraArgs
    ) internal override returns (uint256 amountOut) {
        IFlashLiquidityFactory factory = IFlashLiquidityFactory(abi.decode(extraArgs, (address)));
        FlashLiquidityFactoryData memory factoryData = s_factoryData[address(factory)];
        if (!factoryData.isRegistered) revert FlashLiquidityAdapter__NotRegisteredFactory();
        address targetPool = factory.getPair(tokenIn, tokenOut);
        if (targetPool == address(0)) revert FlashLiquidityAdapter__InvalidPool();
        amountOut = _getAmountOut(
            targetPool, amountIn, factoryData.feeNumerator, factoryData.feeDenominator, tokenIn < tokenOut
        );
        if (amountOut < amountOutMin) revert FlashLiquidityAdapter__InsufficientOutput();
        (uint256 amount0Out, uint256 amount1Out) =
            tokenIn < tokenOut ? (uint256(0), amountOut) : (amountOut, uint256(0));
        IERC20(tokenIn).safeTransferFrom(msg.sender, targetPool, amountIn);
        IFlashLiquidityPair(targetPool).swap(amount0Out, amount1Out, to, new bytes(0));
    }

    /// @inheritdoc DexAdapter
    function _getMaxOutput(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        override
        returns (uint256 maxOutput, bytes memory extraArgs)
    {
        IFlashLiquidityFactory targetFactory;
        FlashLiquidityFactoryData memory factoryData;
        address targetPool;
        uint256 factoriesLen = s_factories.length;
        uint256 tempOutput;
        bool zeroToOne = tokenIn < tokenOut;
        for (uint256 i; i < factoriesLen;) {
            targetFactory = s_factories[i];
            targetPool = targetFactory.getPair(tokenIn, tokenOut);
            if (targetPool != address(0) && IFlashLiquidityPair(targetPool).manager() == address(0)) {
                factoryData = s_factoryData[address(targetFactory)];
                tempOutput =
                    _getAmountOut(targetPool, amountIn, factoryData.feeNumerator, factoryData.feeDenominator, zeroToOne);
                if (tempOutput > maxOutput) {
                    maxOutput = tempOutput;
                    extraArgs = abi.encode(address(targetFactory));
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc DexAdapter
    function _getOutputFromArgs(address tokenIn, address tokenOut, uint256 amountIn, bytes memory extraArgs)
        internal
        view
        override
        returns (uint256 amountOut)
    {
        IFlashLiquidityFactory factory = IFlashLiquidityFactory(abi.decode(extraArgs, (address)));
        FlashLiquidityFactoryData memory factoryData = s_factoryData[address(factory)];
        if (!factoryData.isRegistered) revert FlashLiquidityAdapter__NotRegisteredFactory();
        address pool = factory.getPair(tokenIn, tokenOut);
        if (pool == address(0)) return 0;
        return _getAmountOut(pool, amountIn, factoryData.feeNumerator, factoryData.feeDenominator, tokenIn < tokenOut);
    }

    /// @inheritdoc DexAdapter
    function _getAdapterArgs(address tokenIn, address tokenOut)
        internal
        view
        override
        returns (bytes[] memory extraArgs)
    {
        uint256 factoriesLen = s_factories.length;
        bytes[] memory tempArgs = new bytes[](factoriesLen);
        uint256 argsLen;
        IFlashLiquidityFactory factory;
        address pool;
        for (uint256 i; i < factoriesLen;) {
            factory = s_factories[i];
            pool = factory.getPair(tokenIn, tokenOut);
            if (pool != address(0) && IFlashLiquidityPair(pool).manager() == address(0)) {
                tempArgs[argsLen] = abi.encode(address(factory));
                unchecked {
                    ++argsLen;
                }
            }
            unchecked {
                ++i;
            }
        }
        extraArgs = new bytes[](argsLen);
        for (uint256 j; j < argsLen;) {
            extraArgs[j] = tempArgs[j];
            unchecked {
                ++j;
            }
        }
    }

    /**
     * @dev Calculates the amount of output tokens that can be obtained from a given input amount for a swap operation in a Uniswap V2 pool, considering the pool's reserves and fee structure.
     * @param targetPool The address of the Uniswap V2 pool.
     * @param amountIn The amount of input tokens to be swapped.
     * @param feeNumerator The numerator part of the fee fraction for the swap.
     * @param feeDenominator The denominator part of the fee fraction for the swap.
     * @param zeroToOne A boolean flag indicating the direction of the swap (true for swapping token0 to token1, false for token1 to token0).
     * @return amountOut The amount of output tokens that can be received from the swap.
     * @notice This function computes the output amount by applying the Uniswap V2 formula, taking into account the current reserves of the pool and the specified fee structure.
     */
    function _getAmountOut(
        address targetPool,
        uint256 amountIn,
        uint48 feeNumerator,
        uint48 feeDenominator,
        bool zeroToOne
    ) private view returns (uint256 amountOut) {
        uint256 amountInWithFee;
        (uint256 reserveIn, uint256 reserveOut,) = IFlashLiquidityPair(targetPool).getReserves();
        (reserveIn, reserveOut) = zeroToOne ? (reserveIn, reserveOut) : (reserveOut, reserveIn);
        if (reserveIn > 0 && reserveOut > 0) {
            amountInWithFee = amountIn * feeNumerator;
            amountOut = (amountInWithFee * reserveOut) / ((reserveIn * feeDenominator) + amountInWithFee);
        }
    }

    /**
     * @dev Retrieves details of a specific factory identified by its index in the 's_factory' array.
     * @param factoryIndex The index of the factory in the 's_factories' array.
     * @return factory The address of the factory at the specified index.
     * @return feeNumerator The numerator part of the fee fraction associated with this factory.
     * @return feeDenominator The denominator part of the fee fraction associated with this factory.
     * @notice The function will return the address of the factory and its fee structure.
     *         It is important to ensure that the factoryIndex is within the bounds of the array to avoid out-of-bounds errors.
     */
    function getFactoryAtIndex(uint256 factoryIndex)
        external
        view
        returns (address factory, uint48 feeNumerator, uint48 feeDenominator)
    {
        factory = address(s_factories[factoryIndex]);
        FlashLiquidityFactoryData memory factoryData = s_factoryData[address(factory)];
        feeNumerator = factoryData.feeNumerator;
        feeDenominator = factoryData.feeDenominator;
    }

    /// @return factoriesLength The number of factories currently registered
    function allFactoriesLength() external view returns (uint256) {
        return s_factories.length;
    }
}
