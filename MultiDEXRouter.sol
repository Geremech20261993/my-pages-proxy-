// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IDexInterfaces.sol";

/// @title MultiDEXRouter
/// @notice Stateless dispatcher that executes a single hop on whichever DEX
///         the caller specifies. Deliberately holds no funds between calls —
///         it is called by FlashLoanArbitrage in a loop, one hop at a time,
///         so a bug here can't strand tokens.
/// @dev "V4" for Uniswap/QuickSwap is intentionally NOT wired up: as of this
///      writing Uniswap V4's hook-based singleton architecture has a materially
///      different integration surface (PoolManager + hooks, not a simple router
///      call) and QuickSwap V4 addresses were not something I could verify.
///      Wire these in only after confirming the deployed ABI on PolygonScan.
contract MultiDEXRouter {
    using SafeERC20 for IERC20;

    enum DexType {
        UNISWAP_V2_STYLE, // covers QuickSwap V2, Uniswap V2, SushiSwap V2
        UNISWAP_V3_STYLE, // covers QuickSwap V3, Uniswap V3, SushiSwap V3
        CURVE,
        BALANCER_V2
    }

    struct Hop {
        DexType dexType;
        address router;        // router/pool/vault address for this hop
        address tokenIn;
        address tokenOut;
        uint256 minAmountOut;  // slippage floor for THIS hop, computed off-chain
        // dex-specific extras, ABI-encoded per dexType:
        //  UNISWAP_V2_STYLE: unused
        //  UNISWAP_V3_STYLE: abi.encode(uint24 fee)
        //  CURVE:            abi.encode(int128 i, int128 j)
        //  BALANCER_V2:      abi.encode(bytes32 poolId)
        bytes extra;
    }

    error UnsupportedDex();
    error HopReturnedZero();

    /// @notice Executes one hop, pulling `amountIn` of tokenIn from msg.sender
    ///         (the arbitrage executor must have approved this contract, or
    ///         more commonly, the executor calls this via delegatecall / holds
    ///         the router as a trusted internal component — see integration
    ///         note in FlashLoanArbitrage).
    function executeHop(Hop calldata hop, uint256 amountIn, address recipient)
        external
        returns (uint256 amountOut)
    {
        IERC20(hop.tokenIn).forceApprove(hop.router, amountIn);

        if (hop.dexType == DexType.UNISWAP_V2_STYLE) {
            address[] memory path = new address[](2);
            path[0] = hop.tokenIn;
            path[1] = hop.tokenOut;
            uint256[] memory amounts = IUniswapV2Router(hop.router).swapExactTokensForTokens(
                amountIn, hop.minAmountOut, path, recipient, block.timestamp
            );
            amountOut = amounts[amounts.length - 1];
        } else if (hop.dexType == DexType.UNISWAP_V3_STYLE) {
            uint24 fee = abi.decode(hop.extra, (uint24));
            amountOut = IUniswapV3Router(hop.router).exactInputSingle(
                IUniswapV3Router.ExactInputSingleParams({
                    tokenIn: hop.tokenIn,
                    tokenOut: hop.tokenOut,
                    fee: fee,
                    recipient: recipient,
                    amountIn: amountIn,
                    amountOutMinimum: hop.minAmountOut,
                    sqrtPriceLimitX96: 0
                })
            );
        } else if (hop.dexType == DexType.CURVE) {
            (int128 i, int128 j) = abi.decode(hop.extra, (int128, int128));
            amountOut = ICurvePool(hop.router).exchange(i, j, amountIn, hop.minAmountOut);
            if (recipient != address(this)) {
                IERC20(hop.tokenOut).safeTransfer(recipient, amountOut);
            }
        } else if (hop.dexType == DexType.BALANCER_V2) {
            bytes32 poolId = abi.decode(hop.extra, (bytes32));
            amountOut = IBalancerVault(hop.router).swap(
                IBalancerVault.SingleSwap({
                    poolId: poolId,
                    kind: IBalancerVault.SwapKind.GIVEN_IN,
                    assetIn: hop.tokenIn,
                    assetOut: hop.tokenOut,
                    amount: amountIn,
                    userData: ""
                }),
                IBalancerVault.FundManagement({
                    sender: address(this),
                    fromInternalBalance: false,
                    recipient: payable(recipient),
                    toInternalBalance: false
                }),
                hop.minAmountOut,
                block.timestamp
            );
        } else {
            revert UnsupportedDex();
        }

        if (amountOut == 0) revert HopReturnedZero();
    }
}
