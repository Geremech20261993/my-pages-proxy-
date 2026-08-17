// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////
                            ERC20
//////////////////////////////////////////////////////////////*/

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

/*//////////////////////////////////////////////////////////////
                        AAVE V3 POOL (FLASH LOAN)
//////////////////////////////////////////////////////////////*/

interface IAaveV3Pool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IAaveV3FlashLoanSimpleReceiver {
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}

/*//////////////////////////////////////////////////////////////
                    UNISWAP V2 STYLE (QuickSwap V2,
                    SushiSwap V2, Uniswap V2 clones)
//////////////////////////////////////////////////////////////*/

interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

/*//////////////////////////////////////////////////////////////
                    UNISWAP V3 STYLE (QuickSwap V3,
                    Uniswap V3 concentrated liquidity)
//////////////////////////////////////////////////////////////*/

interface IUniswapV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

/*//////////////////////////////////////////////////////////////
                    UNISWAP V4 (PoolManager delta
                    settlement) - minimal surface used
//////////////////////////////////////////////////////////////*/

interface IPoolManagerMinimal {
    /// @dev Real V4 integration requires implementing IUnlockCallback and
    /// settling deltas via the PoolManager's unlock() pattern. This minimal
    /// interface is a placeholder hook point — see README for integration notes.
    function unlock(bytes calldata data) external returns (bytes memory);
}

/*//////////////////////////////////////////////////////////////
                            CURVE
//////////////////////////////////////////////////////////////*/

interface ICurvePool {
    // Standard stableswap / metapool signature (int128 indices)
    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external returns (uint256);

    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
}

/*//////////////////////////////////////////////////////////////
                        BALANCER V2 VAULT
//////////////////////////////////////////////////////////////*/

interface IBalancerV2Vault {
    enum SwapKind { GIVEN_IN, GIVEN_OUT }

    struct SingleSwap {
        bytes32 poolId;
        SwapKind kind;
        address assetIn;
        address assetOut;
        uint256 amount;
        bytes userData;
    }

    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address payable recipient;
        bool toInternalBalance;
    }

    function swap(
        SingleSwap calldata singleSwap,
        FundManagement calldata funds,
        uint256 limit,
        uint256 deadline
    ) external payable returns (uint256 amountCalculated);

    function flashLoan(
        address recipient,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes calldata userData
    ) external;
}

interface IBalancerFlashLoanRecipient {
    function receiveFlashLoan(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata userData
    ) external;
}

/*//////////////////////////////////////////////////////////////
                    DODO SINGLE-ASSET FLASH LOAN
//////////////////////////////////////////////////////////////*/

interface IDODOFlashLoanPool {
    function flashLoan(
        uint256 baseAmount,
        uint256 quoteAmount,
        address assetTo,
        bytes calldata data
    ) external;
}

interface IDODOFlashLoanCallee {
    function DVMFlashLoanCall(
        address sender,
        uint256 baseAmount,
        uint256 quoteAmount,
        bytes calldata data
    ) external;
}
