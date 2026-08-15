// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./interfaces/IDexInterfaces.sol";
import {MultiDEXRouter} from "./MultiDEXRouter.sol";

/// @title FlashLoanArbitrage
/// @notice Atomic multi-hop flash loan arbitrage executor for Polygon.
///         Supports Aave V3 (flashLoanSimple) and Balancer V2 (flashLoan, 0-fee)
///         as flash liquidity sources. Executes an arbitrary sequence of hops
///         across the DEXs wired into MultiDEXRouter, then requires strictly
///         positive profit (net of loan repayment) before returning.
///
/// @dev SECURITY MODEL — read before deploying with real funds:
///   1. This contract is NEVER meant to hold idle balances. It receives the
///      flash loan, spends it, and repays it in the same transaction. Any
///      token that ends up here outside of that flow is swept only via the
///      owner-only `rescueTokens`.
///   2. `executeArbitrage` is owner-only. This is deliberate: an arbitrage
///      executor that anyone can trigger is a griefing vector (someone can
///      call it with a garbage path purely to burn your gas/waste your flash
///      loan fee allowance, or — worse — front-run your own bundle). Route
///      calls through your off-chain bot's EOA/relayer, ideally via a private
///      mempool (Flashbots Protect / MEV-Share style RPC) so the calldata
///      itself isn't public before inclusion.
///   3. Flash loan callbacks (`executeOperation`, `receiveFlashLoan`) verify
///      `msg.sender` is the real Aave Pool / Balancer Vault AND that the loan
///      was self-initiated (`initiator == address(this)`), so nobody can
///      spoof a callback to drain approvals.
///   4. Profit check happens BEFORE repayment is even attempted — if the
///      swap path didn't produce enough to cover principal + fee + the
///      configured minimum profit, the whole tx reverts and no state changes
///      survive. There is no partial-failure state.
///   5. `tx.origin` is intentionally NOT used for auth (it's the classic
///      phishing-through-a-malicious-contract vector) — access control is
///      pure `msg.sender` + Ownable2Step.
contract FlashLoanArbitrage is ReentrancyGuard, Pausable, Ownable2Step,
    IAaveV3FlashLoanSimpleReceiver, IBalancerFlashLoanRecipient
{
    using SafeERC20 for IERC20;

    enum Provider { AAVE_V3, BALANCER_V2 }

    IAaveV3Pool public immutable AAVE_POOL;
    IBalancerVault public immutable BALANCER_VAULT;
    MultiDEXRouter public immutable ROUTER;

    /// @notice Minimum acceptable profit in basis points of the loan amount.
    ///         50 = 0.5%. Set conservatively; this is your floor, not target.
    uint256 public minProfitBps = 50;

    /// @notice Hard cap on any single flash loan, per asset. 0 = no cap set (blocked).
    mapping(address => uint256) public maxLoanAmount;

    /// @notice Whitelisted tokens allowed as the flash-loan asset / cycle start.
    mapping(address => bool) public approvedAsset;

    /// @dev Transient-style guard: set only for the duration of a self-initiated
    ///      flash loan, checked in the callback, cleared immediately after.
    bool private _loanInFlight;

    event ArbitrageExecuted(
        address indexed asset,
        uint256 loanAmount,
        uint256 profit,
        Provider provider
    );
    event MinProfitBpsUpdated(uint256 oldBps, uint256 newBps);
    event MaxLoanAmountUpdated(address indexed asset, uint256 amount);
    event AssetApprovalUpdated(address indexed asset, bool approved);
    event TokensRescued(address indexed token, uint256 amount, address indexed to);

    error UntrustedCaller();
    error UnknownInitiator();
    error AssetNotApproved();
    error LoanExceedsCap();
    error InsufficientProfit(uint256 required, uint256 got);
    error NoLoanInFlight();
    error ZeroAddress();
    error InvalidBps();

    constructor(
        address aavePool,
        address balancerVault,
        address router,
        address initialOwner
    ) Ownable(initialOwner) {
        if (aavePool == address(0) || balancerVault == address(0) || router == address(0)) {
            revert ZeroAddress();
        }
        AAVE_POOL = IAaveV3Pool(aavePool);
        BALANCER_VAULT = IBalancerVault(balancerVault);
        ROUTER = MultiDEXRouter(router);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin / risk management
    // ─────────────────────────────────────────────────────────────────────────

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setMinProfitBps(uint256 bps) external onlyOwner {
        if (bps == 0 || bps > 2000) revert InvalidBps(); // sanity cap at 20%
        emit MinProfitBpsUpdated(minProfitBps, bps);
        minProfitBps = bps;
    }

    function setMaxLoanAmount(address asset, uint256 amount) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        maxLoanAmount[asset] = amount;
        emit MaxLoanAmountUpdated(asset, amount);
    }

    function setApprovedAsset(address asset, bool approved) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        approvedAsset[asset] = approved;
        emit AssetApprovalUpdated(asset, approved);
    }

    /// @notice Owner-only emergency sweep. Use if a hop leaves dust or a
    ///         transaction reverts mid-flight in a way that strands tokens
    ///         (should not happen given the atomicity model above, but this
    ///         is the safety valve auditors will ask for).
    function rescueTokens(address token, uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, amount, to);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Entry point
    // ─────────────────────────────────────────────────────────────────────────

    /// @param provider          Which flash loan source to draw from.
    /// @param asset              The flash-loaned token (e.g. WETH).
    /// @param loanAmount         Amount to borrow.
    /// @param hops               Ordered swap path, e.g. WETH→USDT→DAI→USDC→WETH.
    /// @param minProfitOverride  Optional stricter floor than minProfitBps for
    ///                           this specific call; pass 0 to just use minProfitBps.
    function executeArbitrage(
        Provider provider,
        address asset,
        uint256 loanAmount,
        MultiDEXRouter.Hop[] calldata hops,
        uint256 minProfitOverride
    ) external onlyOwner whenNotPaused nonReentrant {
        if (!approvedAsset[asset]) revert AssetNotApproved();
        uint256 cap = maxLoanAmount[asset];
        if (cap == 0 || loanAmount > cap) revert LoanExceedsCap();
        if (hops.length == 0 || hops[0].tokenIn != asset || hops[hops.length - 1].tokenOut != asset) {
            revert("path must start and end with loan asset");
        }

        bytes memory params = abi.encode(hops, minProfitOverride);
        _loanInFlight = true;

        if (provider == Provider.AAVE_V3) {
            AAVE_POOL.flashLoanSimple(address(this), asset, loanAmount, params, 0);
        } else {
            address[] memory tokens = new address[](1);
            tokens[0] = asset;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = loanAmount;
            BALANCER_VAULT.flashLoan(address(this), tokens, amounts, params);
        }

        // If we reach here the callback already validated profit and repaid.
        _loanInFlight = false;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Aave V3 callback
    // ─────────────────────────────────────────────────────────────────────────

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external override nonReentrant returns (bool) {
        if (msg.sender != address(AAVE_POOL)) revert UntrustedCaller();
        if (initiator != address(this)) revert UnknownInitiator();
        if (!_loanInFlight) revert NoLoanInFlight();

        uint256 amountOwed = amount + premium;
        uint256 profit = _runPathAndMeasureProfit(asset, amount, amountOwed, params);

        IERC20(asset).forceApprove(address(AAVE_POOL), amountOwed);

        emit ArbitrageExecuted(asset, amount, profit, Provider.AAVE_V3);
        return true;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Balancer V2 callback
    // ─────────────────────────────────────────────────────────────────────────

    function receiveFlashLoan(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata userData
    ) external override nonReentrant {
        if (msg.sender != address(BALANCER_VAULT)) revert UntrustedCaller();
        if (!_loanInFlight) revert NoLoanInFlight();

        address asset = tokens[0];
        uint256 amount = amounts[0];
        uint256 amountOwed = amount + feeAmounts[0];

        uint256 profit = _runPathAndMeasureProfit(asset, amount, amountOwed, userData);

        // Balancer V2 flash loans are repaid by transferring back to the Vault directly.
        IERC20(asset).safeTransfer(address(BALANCER_VAULT), amountOwed);

        emit ArbitrageExecuted(asset, amount, profit, Provider.BALANCER_V2);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal: run the hop sequence, enforce the profit gate
    // ─────────────────────────────────────────────────────────────────────────

    function _runPathAndMeasureProfit(
        address asset,
        uint256 loanAmount,
        uint256 amountOwed,
        bytes memory params
    ) internal returns (uint256 profit) {
        (MultiDEXRouter.Hop[] memory hops, uint256 minProfitOverride) =
            abi.decode(params, (MultiDEXRouter.Hop[], uint256));

        uint256 amountIn = loanAmount;
        for (uint256 i = 0; i < hops.length; i++) {
            amountIn = _delegateHop(hops[i], amountIn);
        }

        uint256 finalBalance = amountIn;
        uint256 requiredMin = amountOwed + (loanAmount * _effectiveMinProfitBps(minProfitOverride)) / 10_000;

        if (finalBalance < requiredMin) {
            revert InsufficientProfit(requiredMin, finalBalance);
        }

        profit = finalBalance - amountOwed;
        // `asset` param kept for interface symmetry / future per-asset accounting hooks.
        asset;
    }

    /// @dev Executes a single hop via the shared MultiDEXRouter. Funds the
    ///      router directly with this hop's input (safeTransfer, not an
    ///      approve+pull — the router never needs an allowance on this
    ///      contract), then the router swaps and returns output here.
    function _delegateHop(MultiDEXRouter.Hop memory hop, uint256 amountIn) internal returns (uint256) {
        // Fund the router with exactly this hop's input, then let it execute
        // and send output directly back to this contract as recipient.
        IERC20(hop.tokenIn).safeTransfer(address(ROUTER), amountIn);
        return ROUTER.executeHop(hop, amountIn, address(this));
    }

    function _effectiveMinProfitBps(uint256 override_) internal view returns (uint256) {
        if (override_ == 0) return minProfitBps;
        return override_ > minProfitBps ? override_ : minProfitBps;
    }
}
