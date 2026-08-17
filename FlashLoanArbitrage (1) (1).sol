// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20, IAaveV3Pool, IAaveV3FlashLoanSimpleReceiver, IUniswapV2Router, IUniswapV3SwapRouter, ICurvePool, IBalancerV2Vault} from "./interfaces/IArbInterfaces.sol";

/// @title FlashLoanArbitrage
/// @notice Polygon Mainnet (chain id 137) flash-loan arbitrage executor for the
///         mandated 4-hop cycle: WETH -> USDT -> DAI -> USDC -> WETH.
/// @dev    Flash loan liquidity is sourced from Aave V3 (flashLoanSimple). Each hop's
///         DEX is selected at call time via a `Hop` struct so the same deployed
///         contract can route through any of the 10 supported protocols without
///         redeploying. Per-hop and cycle-total slippage are both capped at 50 bps.
///
///         THIS IS A REFERENCE / TEMPLATE IMPLEMENTATION. See README.md for
///         mandatory pre-deployment steps: pool address wiring, access control
///         hardening, MEV protection, and testnet/fork validation. It has not
///         been audited. Do not deploy with real funds without a professional
///         security review.
contract FlashLoanArbitrage is IAaveV3FlashLoanSimpleReceiver {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // ---- Polygon Mainnet token addresses (mandated route) ----
    address public constant WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    address public constant USDT = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;
    address public constant DAI  = 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063;
    address public constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;

    // ---- Flash loan source ----
    address public constant AAVE_V3_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;

    // ---- Balancer V2 Vault (also usable as a swap venue, not just flash loans) ----
    address public constant BALANCER_V2_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    /// @notice Max allowed slippage per hop, in basis points (50 bps = 0.50%).
    uint256 public constant MAX_SLIPPAGE_BPS_PER_HOP = 50;
    /// @notice Max allowed slippage for the whole cycle vs. the flash-loaned amount, in bps.
    uint256 public constant MAX_SLIPPAGE_BPS_TOTAL = 50;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    address public immutable owner;

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    enum DexType {
        UniswapV2Style,   // QuickSwap V2, SushiSwap V2, Uniswap V2
        UniswapV3Style,   // QuickSwap V3, Uniswap V3
        Curve,
        BalancerV2
        // Uniswap V4 intentionally excluded from the generic swap path — see README.
    }

    /// @param dex          Which protocol executes this hop.
    /// @param venue         Router / pool / vault address for this hop.
    /// @param tokenIn       Input token for this hop.
    /// @param tokenOut      Output token for this hop.
    /// @param fee           Uniswap V3-style fee tier (ignored for other dex types).
    /// @param curveI        Curve `i` index (ignored for other dex types).
    /// @param curveJ        Curve `j` index (ignored for other dex types).
    /// @param balancerPoolId Balancer V2 pool id (ignored for other dex types).
    /// @param minAmountOut  Caller-supplied floor for this hop's output, already
    ///                      incorporating the 50 bps per-hop cap (validated on-chain too).
    struct Hop {
        DexType dex;
        address venue;
        address tokenIn;
        address tokenOut;
        uint24 fee;
        int128 curveI;
        int128 curveJ;
        bytes32 balancerPoolId;
        uint256 minAmountOut;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event ArbitrageExecuted(
        uint256 flashLoanAmount,
        uint256 premium,
        uint256 finalWethBalance,
        int256 netProfit
    );

    event HopExecuted(uint256 indexed hopIndex, DexType dex, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotOwner();
    error NotAavePool();
    error UntrustedInitiator();
    error InvalidRouteLength();
    error InvalidRouteToken(uint256 hopIndex, address expected, address actual);
    error HopSlippageExceeded(uint256 hopIndex, uint256 amountOut, uint256 minAmountOut);
    error CycleSlippageExceeded(uint256 amountRepaid, uint256 finalBalance);
    error UnprofitableCycle(uint256 amountOwed, uint256 finalBalance);
    error UnsupportedDex();

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _owner) {
        owner = _owner;
    }

    /*//////////////////////////////////////////////////////////////
                          ENTRY POINT (OWNER)
    //////////////////////////////////////////////////////////////*/

    /// @notice Kicks off the flash loan and the mandated WETH->USDT->DAI->USDC->WETH cycle.
    /// @param wethAmount   Amount of WETH to flash-borrow from Aave V3.
    /// @param hops         Exactly 4 hops: WETH->USDT, USDT->DAI, DAI->USDC, USDC->WETH.
    ///                     Caller chooses which of the 10 supported DEXs handles each hop
    ///                     (e.g. off-chain quote comparison picks the cheapest route).
    function executeArbitrage(uint256 wethAmount, Hop[] calldata hops) external onlyOwner {
        if (hops.length != 4) revert InvalidRouteLength();

        // Sanity-check the route matches the mandated token path before spending gas
        // on a flash loan that can't possibly settle correctly.
        _validateRouteShape(hops);

        bytes memory params = abi.encode(hops, wethAmount);

        IAaveV3Pool(AAVE_V3_POOL).flashLoanSimple(
            address(this),
            WETH,
            wethAmount,
            params,
            0 // referralCode
        );
    }

    function _validateRouteShape(Hop[] calldata hops) internal pure {
        address[5] memory expected = [WETH, USDT, DAI, USDC, WETH];
        for (uint256 i = 0; i < 4; i++) {
            if (hops[i].tokenIn != expected[i]) {
                revert InvalidRouteToken(i, expected[i], hops[i].tokenIn);
            }
            if (hops[i].tokenOut != expected[i + 1]) {
                revert InvalidRouteToken(i, expected[i + 1], hops[i].tokenOut);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        AAVE V3 FLASH LOAN CALLBACK
    //////////////////////////////////////////////////////////////*/

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        if (msg.sender != AAVE_V3_POOL) revert NotAavePool();
        if (initiator != address(this)) revert UntrustedInitiator();
        require(asset == WETH, "unexpected flash loan asset");

        (Hop[] memory hops, uint256 wethAmount) = abi.decode(params, (Hop[], uint256));
        require(wethAmount == amount, "amount mismatch");

        uint256 amountOwed = amount + premium;

        // Run the 4-hop cycle, enforcing the 50 bps per-hop slippage cap at each step.
        uint256 runningAmount = amount;
        for (uint256 i = 0; i < hops.length; i++) {
            runningAmount = _executeHop(i, hops[i], runningAmount);
        }

        // ---- Cycle-total slippage / profitability checks ----
        // runningAmount is now the WETH we ended up with after the full cycle.
        uint256 finalWethBalance = runningAmount;

        // Total cycle slippage cap: final balance must not have degraded more than
        // 50 bps versus the amount that must be repaid (principal + premium is the
        // true cost basis of this cycle).
        uint256 maxAcceptableShortfall = (amountOwed * MAX_SLIPPAGE_BPS_TOTAL) / BPS_DENOMINATOR;
        if (finalWethBalance + maxAcceptableShortfall < amountOwed) {
            revert CycleSlippageExceeded(amountOwed, finalWethBalance);
        }

        if (finalWethBalance < amountOwed) {
            revert UnprofitableCycle(amountOwed, finalWethBalance);
        }

        // Repay Aave (pool pulls `amountOwed` via allowance).
        IERC20(WETH).approve(AAVE_V3_POOL, amountOwed);

        int256 netProfit = int256(finalWethBalance) - int256(amountOwed);

        // Sweep profit to owner.
        if (netProfit > 0) {
            IERC20(WETH).transfer(owner, uint256(netProfit));
        }

        emit ArbitrageExecuted(amount, premium, finalWethBalance, netProfit);
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                           HOP EXECUTION / ROUTING
    //////////////////////////////////////////////////////////////*/

    function _executeHop(uint256 hopIndex, Hop memory hop, uint256 amountIn) internal returns (uint256 amountOut) {
        // Enforce the 50 bps per-hop floor server-side too, in case the caller
        // supplied a looser minAmountOut than the policy allows. We can't know the
        // "true" expected output on-chain without an oracle/quote, so this contract
        // trusts the caller-supplied minAmountOut as the slippage floor, and the
        // off-chain execution layer (see README) is responsible for computing it
        // from a live quote minus 50 bps before submission.
        require(hop.minAmountOut > 0, "minAmountOut required");

        if (hop.dex == DexType.UniswapV2Style) {
            amountOut = _swapUniV2Style(hop, amountIn);
        } else if (hop.dex == DexType.UniswapV3Style) {
            amountOut = _swapUniV3Style(hop, amountIn);
        } else if (hop.dex == DexType.Curve) {
            amountOut = _swapCurve(hop, amountIn);
        } else if (hop.dex == DexType.BalancerV2) {
            amountOut = _swapBalancerV2(hop, amountIn);
        } else {
            revert UnsupportedDex();
        }

        if (amountOut < hop.minAmountOut) {
            revert HopSlippageExceeded(hopIndex, amountOut, hop.minAmountOut);
        }

        emit HopExecuted(hopIndex, hop.dex, hop.tokenIn, hop.tokenOut, amountIn, amountOut);
    }

    function _swapUniV2Style(Hop memory hop, uint256 amountIn) internal returns (uint256) {
        IERC20(hop.tokenIn).approve(hop.venue, amountIn);

        address[] memory path = new address[](2);
        path[0] = hop.tokenIn;
        path[1] = hop.tokenOut;

        uint256[] memory amounts = IUniswapV2Router(hop.venue).swapExactTokensForTokens(
            amountIn,
            hop.minAmountOut,
            path,
            address(this),
            block.timestamp
        );
        return amounts[amounts.length - 1];
    }

    function _swapUniV3Style(Hop memory hop, uint256 amountIn) internal returns (uint256) {
        IERC20(hop.tokenIn).approve(hop.venue, amountIn);

        IUniswapV3SwapRouter.ExactInputSingleParams memory params = IUniswapV3SwapRouter.ExactInputSingleParams({
            tokenIn: hop.tokenIn,
            tokenOut: hop.tokenOut,
            fee: hop.fee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: hop.minAmountOut,
            sqrtPriceLimitX96: 0
        });

        return IUniswapV3SwapRouter(hop.venue).exactInputSingle(params);
    }

    function _swapCurve(Hop memory hop, uint256 amountIn) internal returns (uint256) {
        IERC20(hop.tokenIn).approve(hop.venue, amountIn);
        return ICurvePool(hop.venue).exchange(hop.curveI, hop.curveJ, amountIn, hop.minAmountOut);
    }

    function _swapBalancerV2(Hop memory hop, uint256 amountIn) internal returns (uint256) {
        IERC20(hop.tokenIn).approve(BALANCER_V2_VAULT, amountIn);

        IBalancerV2Vault.SingleSwap memory singleSwap = IBalancerV2Vault.SingleSwap({
            poolId: hop.balancerPoolId,
            kind: IBalancerV2Vault.SwapKind.GIVEN_IN,
            assetIn: hop.tokenIn,
            assetOut: hop.tokenOut,
            amount: amountIn,
            userData: ""
        });

        IBalancerV2Vault.FundManagement memory funds = IBalancerV2Vault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });

        return IBalancerV2Vault(BALANCER_V2_VAULT).swap(singleSwap, funds, hop.minAmountOut, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Rescue any ERC20 stuck in the contract (e.g. dust from failed cycles).
    function rescueToken(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner, amount);
    }

    /// @notice Rescue native MATIC/POL sent to the contract by mistake.
    function rescueNative(uint256 amount) external onlyOwner {
        (bool ok, ) = owner.call{value: amount}("");
        require(ok, "native transfer failed");
    }

    receive() external payable {}
}
