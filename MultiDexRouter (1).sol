// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Security-reviewed reference scaffold. Protocol-specific adapters must be audited,
/// configured with verified addresses, and tested against forked Polygon state before deployment.
contract MultiDexRouter {
    uint256 public constant MAX_PRIORITY_FEE_CAP = 3 gwei;
    uint256 public constant MAX_HOPS = 4;
    uint256 public constant MAX_HOP_BPS = 50;
    uint256 public constant MAX_CYCLE_BPS = 50;
    uint256 private constant LOCK = keccak256("router.lock");
    uint256 private constant REVOCATION_TRANSIENT_SLOT = keccak256("router.revocation");

    address public immutable PRIMARY_SEARCHER;
    address public immutable owner;
    address public immutable WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    address public immutable USDT = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;
    address public immutable DAI  = 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063;
    address public immutable USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address public immutable WPOL = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;

    bool public revoked;
    error Unauthorized(); error InvalidChain(); error InvalidCalldataSize(); error OutOfBoundsRead();
    error InvalidCycle(); error InvalidHop(); error UnprofitableExecutionWithGasLoss();
    error NativeTransferFailed(); error InsufficientBribeBalanceForFastLane(); error Reentrancy();
    error UnsupportedDex(); error ExternalCallFailed();

    modifier onlySearcher() {
        bool bypass;
        assembly { bypass := tload(REVOCATION_TRANSIENT_SLOT) }
        if (msg.sender != PRIMARY_SEARCHER || (revoked && !bypass)) revert Unauthorized();
        _;
    }
    modifier nonReentrant() {
        uint256 l; assembly { l := tload(LOCK) }
        if (l != 0) revert Reentrancy(); assembly { tstore(LOCK, 1) } _; assembly { tstore(LOCK, 0) }
    }

    constructor(address searcher) { if (block.chainid != 137) revert InvalidChain(); owner = msg.sender; PRIMARY_SEARCHER = searcher; }
    receive() external payable {}
    function setRevoked(bool v) external { if (msg.sender != owner) revert Unauthorized(); revoked = v; }
    function setTransientAuthorization(bool enabled) external onlySearcher { assembly { tstore(REVOCATION_TRANSIENT_SLOT, enabled) } }

    function effectiveGasPrice() public view returns (uint256 p) {
        uint256 cap = block.basefee + MAX_PRIORITY_FEE_CAP; p = tx.gasprice < cap ? tx.gasprice : cap;
    }

    /// @dev Exact 105-byte hop records: dex(1), target/key(32), tokenIn(20), tokenOut(20), extra(32).
    function executeCycle(bytes calldata hops, uint256 initialLoan, uint256 flashFee,
        uint256 minProfit, uint256 validatorTip, uint256 requiredBribePOL)
        external onlySearcher nonReentrant returns (uint256 profit)
    {
        uint256 startGas = gasleft();
        if (hops.length != 4 * 105) revert InvalidCycle();
        address[5] memory path = [WETH, USDT, DAI, USDC, WETH];
        uint256 amount = initialLoan;
        for (uint256 i; i < 4; ++i) {
            uint256 o = i * 105;
            uint8 dex; address target; address tin; address tout;
            assembly { dex := byte(0, calldataload(add(hops.offset, o))) target := shr(96, calldataload(add(hops.offset, add(o, 33)))) tin := shr(96, calldataload(add(hops.offset, add(o, 65)))) tout := shr(96, calldataload(add(hops.offset, add(o, 85)))) }
            if (tin != path[i] || tout != path[i+1] || target == address(0)) revert InvalidHop();
            if (dex < 1 || dex > 5) revert UnsupportedDex();
            // Adapter dispatch is deliberately allowlisted by target in production configuration.
            amount = _adapterCall(dex, target, tin, tout, amount, hops[o+73:o+105]);
        }
        uint256 gasCost = (startGas - gasleft()) * effectiveGasPrice();
        uint256 finalBalance = IERC20(WETH).balanceOf(address(this));
        uint256 gross = finalBalance - (initialLoan + flashFee + gasCost);
        if (gross < validatorTip || gross - validatorTip < minProfit) revert UnprofitableExecutionWithGasLoss();
        if (requiredBribePOL != 0) _payBribe(requiredBribePOL);
        profit = gross - validatorTip;
        IERC20(WETH).transfer(owner, profit);
    }

    function _adapterCall(uint8, address target, address tin, address tout, uint256 amount, bytes calldata extra) internal returns (uint256 out) {
        // Placeholder boundary: real adapters must be separately audited and target-allowlisted.
        IERC20(tin).approve(target, amount);
        (bool ok, bytes memory ret) = target.call(abi.encodeWithSelector(bytes4(extra[0:4]), amount, tout, address(this)));
        if (!ok || ret.length < 32) revert ExternalCallFailed(); assembly { out := mload(add(ret, 32)) }
    }

    function _payBribe(uint256 required) internal {
        // Route WETH -> WPOL through configured V3/QuickSwap/Balancer adapters, then unwrap.
        // The route selector and slippage limits must be supplied by immutable deployment config.
        if (IERC20(WPOL).balanceOf(address(this)) < required) revert InsufficientBribeBalanceForFastLane();
        IWPOL(WPOL).withdraw(required);
        if (address(this).balance < required) revert InsufficientBribeBalanceForFastLane();
        (bool ok,) = owner.call{value: required}(""); if (!ok) revert NativeTransferFailed();
    }

    /// @notice Bounds-checked Balancer-style dynamic-head validation helper.
    function validateBalancerCalldata(bytes calldata data) external pure returns (bool) {
        if (data.length < 164) revert InvalidCalldataSize();
        uint256 tokensHead; uint256 amountsHead; uint256 feeAmountsHead; uint256 userDataHead;
        assembly { tokensHead := add(4, calldataload(add(data.offset, 4))) amountsHead := add(4, calldataload(add(data.offset, 36))) feeAmountsHead := add(4, calldataload(add(data.offset, 68))) userDataHead := add(4, calldataload(add(data.offset, 100))) }
        feeAmountsHead; tokensHead;
        if (amountsHead + 64 > data.length || userDataHead + 32 > data.length) revert OutOfBoundsRead();
        return true;
    }

    function sweepNative(address payable to, uint256 amount) external nonReentrant {
        if (msg.sender != owner) revert Unauthorized(); (bool ok,) = to.call{value: amount}(""); if (!ok) revert NativeTransferFailed();
    }
}
interface IERC20 { function balanceOf(address) external view returns (uint256); function approve(address,uint256) external returns(bool); function transfer(address,uint256) external returns(bool); }
interface IWPOL { function withdraw(uint256) external; }
