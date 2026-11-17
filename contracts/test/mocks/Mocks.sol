// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "../../src/interfaces/IUniswapV3.sol";

contract MockERC20 is ERC20 {
    uint8 internal immutable _dec;

    constructor(string memory n, uint8 d) ERC20(n, n) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFeed {
    int256 public answer;
    uint256 public updatedAt;
    uint8 public decimals = 8;

    function set(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract MockSink {
    address public lastUser;
    address public lastToken;
    uint256 public total;
    bool public broken;

    receive() external payable {}

    function setBroken(bool b) external {
        broken = b;
    }

    function onProtocolFee(address user, address token, uint256 amount) external {
        require(!broken, "sink broken");
        lastUser = user;
        lastToken = token;
        total += amount;
    }
}

contract MockDiscount {
    uint256 public bps;

    function set(uint256 b) external {
        bps = b;
    }

    function discountBps(address) external view returns (uint256) {
        return bps;
    }
}

/// Trades directly against a pool, to create fees and move the price in tests.
contract Trader {
    function swap(address pool, bool zeroForOne, int256 amount) external {
        uint160 limit = zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341;
        IUniswapV3Pool(pool).swap(address(this), zeroForOne, amount, limit, "");
    }

    /// Like swap, but the price may move at most about 5%, so a thin pool is never drained.
    function swapCapped(address pool, bool zeroForOne, int256 amount) external {
        (uint160 p,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint160 limit = zeroForOne ? uint160((uint256(p) * 975) / 1000) : uint160((uint256(p) * 1025) / 1000);
        IUniswapV3Pool(pool).swap(address(this), zeroForOne, amount, limit, "");
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        if (a0 > 0) IERC20(IUniswapV3Pool(msg.sender).token0()).transfer(msg.sender, uint256(a0));
        if (a1 > 0) IERC20(IUniswapV3Pool(msg.sender).token1()).transfer(msg.sender, uint256(a1));
    }
}

/// Pays out what was credited to the caller, like the Pons fee escrow.
contract MockPonsEscrow {
    mapping(address => uint256) public balanceOf;

    function credit(address recipient) external payable {
        balanceOf[recipient] += msg.value;
    }

    function claim() external returns (uint256 amount) {
        amount = balanceOf[msg.sender];
        balanceOf[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "pay");
    }

    function claimToken(address) external pure returns (uint256) {
        return 0;
    }

    function balanceOfToken(address, address) external pure returns (uint256) {
        return 0;
    }
}

/// WETH with deposit and withdraw. Give it ETH in tests so withdraw can pay out minted balances.
contract MockWETH is MockERC20 {
    constructor() MockERC20("WETH", 18) {}

    receive() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "eth");
    }
}

/// Pons launch factory: reports one launched token, its curve and its graduation phase.
contract MockPonsLaunches {
    struct Launched {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        uint8 phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    Launched internal l;
    address public memeHook;

    function launch(address token, address curve, uint24 fee, int24 spacing, address hook) external {
        l.token = token;
        l.curve = curve;
        l.poolFee = fee;
        l.tickSpacing = spacing;
        l.exists = true;
        memeHook = hook;
    }

    function setPhase(uint8 phase) external {
        l.phase = phase;
    }

    function getLaunchedToken(address token) external view returns (Launched memory out) {
        if (token == l.token) out = l;
    }
}

/// Pons bonding curve: constant product on a virtual ETH reserve, 1% fee and 1% creator tax on the ETH leg.
contract MockPonsCurve {
    MockERC20 public immutable token;
    uint256 public quote = 1.5 ether; // virtual + real ETH
    uint256 public tokens = 1_000_000_000e18;
    uint256 public constant feeBps = 100;
    uint256 public constant creatorTaxBps = 100;
    uint256 public snipe;
    bool public graduated;

    constructor(MockERC20 token_) {
        token = token_;
    }

    function setSnipe(uint256 bps) external {
        snipe = bps;
    }

    function setGraduated(bool g) external {
        graduated = g;
    }

    function currentSnipeTaxBps(address) external view returns (uint256) {
        return snipe;
    }

    function getReserves() external view returns (uint256, uint256) {
        return (quote, tokens);
    }

    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256 out) {
        require(msg.value == quoteIn && !graduated, "buy");
        uint256 net = (quoteIn * (10_000 - feeBps - creatorTaxBps - snipe)) / 10_000;
        out = (net * tokens) / (quote + net);
        require(out >= minTokensOut, "slippage");
        quote += net;
        tokens -= out;
        token.mint(recipient, out);
    }
}

interface IPermit2Pull {
    function transferFrom(address from, address to, uint160 amount, address token) external;
}

/// Stands in for Uniswap's Universal Router: the "route" is (tokenIn, tokenOut, amountIn, amountOut). It takes the
/// input from the caller as the real router does (ETH as value, a token through the caller's Permit2 allowance) and
/// pays out amountOut of tokenOut (minted, or ETH it holds) to the caller.
contract MockRouter {
    address public immutable permit2;

    constructor(address permit2_) {
        permit2 = permit2_;
    }

    receive() external payable {}

    fallback() external payable {
        (address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) =
            abi.decode(msg.data, (address, address, uint256, uint256));
        if (tokenIn == address(0)) require(msg.value == amountIn, "value");
        else IPermit2Pull(permit2).transferFrom(msg.sender, address(this), uint160(amountIn), tokenIn);
        if (tokenOut == address(0)) {
            (bool ok,) = msg.sender.call{value: amountOut}("");
            require(ok, "eth out");
        } else {
            MockERC20(tokenOut).mint(msg.sender, amountOut);
        }
    }
}
