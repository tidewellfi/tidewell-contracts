// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IFeeDiscount, IRevenueSink, ITidewellFactory} from "./interfaces/ITidewell.sol";

/// @title TidewellVaultBase
/// @notice What every Tidewell vault shares: one owner, the owner's settings per position, the protocol fee, gas
///         refunds for the keeper, and claiming. The Uniswap v3 and v4 vaults build on this.
/// @dev Everything in a vault that is not inside a Uniswap position belongs to the owner and is "ready to claim".
///      Address zero stands for native ETH.
abstract contract TidewellVaultBase is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 internal constant MAX_DISCOUNT_BPS = 5000;
    uint8 public constant MAX_RULE = 4;

    struct Settings {
        int24 minWidth; // smallest allowed range width, in ticks
        int24 maxWidth; // largest allowed range width, in ticks
        uint32 cooldown; // minimum time between two range moves
        uint16 compoundBps; // share of earned fees that is reinvested, the rest stays ready to claim
        uint16 slippageBps; // maximum price impact of the swap during a range move
        /// How the keeper places a new range, always within [minWidth, maxWidth]: 0 keep the same range, 1 narrow as
        /// the price rises, 2 widen when volatile, 3 follow the average price, 4 wait for the stock market.
        uint8 rule;
    }

    ITidewellFactory public factory;
    address public owner;

    uint256 public nextPositionId;
    uint256[] internal _ids;
    mapping(uint256 id => uint256) internal _idIndex; // index + 1
    /// Per position: tokens that belong in the position but are not in it (yet): what a range move, a reinvest or a
    /// swap could not place. They are not fees: every compound puts them back, whatever the reinvest setting.
    mapping(uint256 id => uint256[2]) internal _unplaced;

    event FeesCollected(uint256 indexed id, uint256 fee0, uint256 fee1, uint256 protocolFee0, uint256 protocolFee1);
    event Compounded(uint256 indexed id, uint256 amount0, uint256 amount1);
    event Rebalanced(uint256 indexed id, uint256 oldTokenId, uint256 newTokenId, int24 tickLower, int24 tickUpper);
    event Swapped(uint256 indexed id, bool zeroForOne, uint256 amountIn, uint256 amountOut);
    event SettingsChanged(uint256 indexed id, Settings settings);
    event Closed(uint256 indexed id);
    event Claimed(address indexed token, uint256 amount);
    event GasRefunded(address indexed keeper, uint256 amount);

    error AlreadyInitialized();
    error NotOwner();
    error NotAllowed();
    error Paused();
    error UnknownPosition();
    error UnknownPool();
    error BadRange();
    error BadSettings();
    error TooSoon();
    error SwapTooLarge();
    error BadSwap();
    error TransferFailed();

    constructor() {
        owner = address(1); // the implementation itself can never be initialized
    }

    function initialize(address owner_) external {
        if (owner != address(0)) revert AlreadyInitialized();
        owner = owner_;
        factory = ITidewellFactory(msg.sender);
    }

    receive() external payable {}

    // ---------------------------------------------------------------- modifiers

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// The owner, or the factory acting for the owner: factory.openWithPermit only reaches the vault of the wallet that
    /// sends that transaction.
    modifier onlyOwnerOrFactory() {
        if (msg.sender != owner && msg.sender != address(factory)) revert NotOwner();
        _;
    }

    modifier onlyOwnerOrKeeper() {
        if (msg.sender != owner && msg.sender != factory.keeper()) revert NotAllowed();
        _;
    }

    modifier whenNotPaused() {
        if (factory.paused()) revert Paused();
        _;
    }

    /// Refunds the keeper's gas from this vault's ETH, or WETH if there is no ETH. Capped by the factory.
    modifier refundGas() {
        uint256 start = gasleft();
        _;
        if (msg.sender == factory.keeper()) _refund(start);
    }

    // ---------------------------------------------------------------- views

    function positionIds() external view returns (uint256[] memory) {
        return _ids;
    }

    /// @notice Tokens of a position waiting in the vault to go back into it (see _unplaced); never more than the vault
    ///         holds. Everything else of the pair in the vault is ready to claim.
    function unplaced(uint256 id) public view returns (uint256 amount0, uint256 amount1) {
        (address t0, address t1) = _pairOf(id);
        amount0 = Math.min(_unplaced[id][0], _balance(t0));
        amount1 = Math.min(_unplaced[id][1], _balance(t1));
    }

    // ---------------------------------------------------------------- owner: claiming (never paused)

    /// @notice Sends ready-to-claim tokens to the owner (address zero: native ETH). Amount zero means all of them.
    ///         What waits to go back into a position (unplaced) is not ready to claim; closing the position returns it.
    function claim(address token, uint256 amount) external onlyOwner nonReentrant {
        uint256 ready = _balance(token) - _reserved(token);
        if (amount == 0 || amount > ready) amount = ready;
        _send(token, amount);
        emit Claimed(token, amount);
    }


    // ---------------------------------------------------------------- internals: fees

    /// Takes the protocol fee on fees earned in two tokens. Returns the fee taken in each token.
    /// @dev When one token ranks higher (ETH above stablecoins above the rest), the whole fee is taken in that token,
    ///      valued at the pool price, so protocol revenue arrives in ETH or dollars without a swap. That needs a
    ///      trustworthy price, so it is only done in the keeper's checked paths (strict). In the owner's withdrawal
    ///      paths each token pays its own share, and nothing there can block the withdrawal: if the fee cannot be
    ///      sent, it is simply not taken.
    function _takeFees(address t0, address t1, uint256 c0, uint256 c1, uint160 sqrtP, bool strict)
        internal
        returns (uint256 p0, uint256 p1)
    {
        if (c0 == 0 && c1 == 0) return (0, 0);
        uint256 bps = factory.protocolFeeBps();
        if (bps == 0) return (0, 0);
        uint256 rate = bps * (10_000 - _discount(strict)); // fee per 1e8
        p0 = (c0 * rate) / 1e8;
        p1 = (c1 * rate) / 1e8;

        if (strict && sqrtP != 0) {
            uint8 r0 = factory.feeRank(t0);
            uint8 r1 = factory.feeRank(t1);
            if (r1 > r0 && p0 > 0) {
                // Move token0's fee to token1, at the pool price.
                uint256 want = p1 + Math.mulDiv(Math.mulDiv(p0, sqrtP, 1 << 96), sqrtP, 1 << 96);
                if (want <= c1) {
                    (p0, p1) = (0, want);
                } else {
                    uint256 rest = want - c1;
                    p1 = c1;
                    p0 = Math.mulDiv(Math.mulDiv(rest, 1 << 96, sqrtP), 1 << 96, sqrtP);
                    if (p0 > c0) p0 = c0;
                }
            } else if (r0 > r1 && p1 > 0) {
                uint256 want = p0 + Math.mulDiv(Math.mulDiv(p1, 1 << 96, sqrtP), 1 << 96, sqrtP);
                if (want <= c0) {
                    (p0, p1) = (want, 0);
                } else {
                    uint256 rest = want - c0;
                    p0 = c0;
                    p1 = Math.mulDiv(Math.mulDiv(rest, sqrtP, 1 << 96), sqrtP, 1 << 96);
                    if (p1 > c1) p1 = c1;
                }
            }
        }
        p0 = _sendFee(t0, p0, strict);
        p1 = _sendFee(t1, p1, strict);
    }

    function _sendFee(address token, uint256 fee, bool strict) internal returns (uint256) {
        if (fee == 0) return 0;
        address recipient = factory.feeRecipient();
        if (strict) {
            if (!_trySend(token, recipient, fee)) revert TransferFailed();
            if (recipient.code.length > 0) IRevenueSink(recipient).onProtocolFee(owner, token, fee);
        } else {
            if (!_trySend(token, recipient, fee)) return 0;
            if (recipient.code.length > 0) {
                try IRevenueSink(recipient).onProtocolFee(owner, token, fee) {} catch {}
            }
        }
        return fee;
    }

    function _discount(bool strict) internal view returns (uint256 d) {
        address src = factory.feeDiscount();
        if (src == address(0)) return 0;
        if (strict) {
            d = IFeeDiscount(src).discountBps(owner);
        } else {
            try IFeeDiscount(src).discountBps(owner) returns (uint256 v) {
                d = v;
            } catch {
                return 0;
            }
        }
        if (d > MAX_DISCOUNT_BPS) d = MAX_DISCOUNT_BPS;
    }

    // ---------------------------------------------------------------- internals: transfers

    function _balance(address token) internal view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    /// Pulls a deposit from the owner. Native ETH must arrive as msg.value and is checked by the caller.
    function _pull(address token, uint256 amount) internal returns (uint256 received) {
        if (amount == 0) return 0;
        factory.checkDeposit(token == address(0) ? factory.weth() : token, amount);
        if (token == address(0)) return amount;
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(owner, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - before;
    }

    /// A deposit that is already in the vault (put there by the factory through Permit2 in the same transaction, or
    /// the owner's own ready-to-claim balance). Native ETH must arrive as msg.value and is checked by the caller.
    function _fromBalance(address token, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        factory.checkDeposit(token == address(0) ? factory.weth() : token, amount);
        if (_balance(token) < amount) revert TransferFailed();
        return amount;
    }

    function _send(address token, uint256 amount) internal {
        if (amount == 0) return;
        if (!_trySend(token, owner, amount)) revert TransferFailed();
    }

    function _trySend(address token, address to, uint256 amount) internal returns (bool ok) {
        if (token == address(0)) {
            (ok,) = to.call{value: amount}("");
            return ok;
        }
        bytes memory ret;
        (ok, ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || abi.decode(ret, (bool))) && (ret.length > 0 || token.code.length > 0);
    }

    function _refund(uint256 startGas) internal {
        uint256 used = startGas - gasleft() + factory.refundOverheadGas();
        uint256 price = tx.gasprice < factory.maxGasPrice() ? tx.gasprice : factory.maxGasPrice();
        uint256 amount = used * price;
        uint256 cap = factory.maxRefundWei();
        if (amount > cap) amount = cap;
        if (amount == 0) return;
        address token;
        if (address(this).balance < amount) {
            token = factory.weth();
            if (IERC20(token).balanceOf(address(this)) < amount) return; // nothing to refund from
        }
        if (!_trySend(token, msg.sender, amount)) revert TransferFailed();
        emit GasRefunded(msg.sender, amount);
    }

    // ---------------------------------------------------------------- internals: tokens not placed yet

    /// The position's two tokens (as the vault holds them; address zero is native ETH).
    function _pairOf(uint256 id) internal view virtual returns (address t0, address t1);

    /// Takes what waits to go back into a position (to add it now); what is not placed again is set anew after.
    function _takeUnplaced(uint256 id) internal returns (uint256 u0, uint256 u1) {
        (u0, u1) = unplaced(id);
        delete _unplaced[id];
    }

    function _setUnplaced(uint256 id, uint256 a0, uint256 a1) internal {
        _unplaced[id] = [a0, a1];
    }

    /// How much of a token waits to go back into positions (so is not ready to claim); never more than the vault holds.
    function _reserved(address token) internal view returns (uint256 r) {
        for (uint256 i; i < _ids.length; ++i) {
            uint256 id = _ids[i];
            (address t0, address t1) = _pairOf(id);
            if (t0 == token) r += _unplaced[id][0];
            if (t1 == token) r += _unplaced[id][1];
        }
        r = Math.min(r, _balance(token));
    }

    // ---------------------------------------------------------------- internals: bookkeeping and checks

    function _addId(uint256 id) internal {
        _ids.push(id);
        _idIndex[id] = _ids.length;
    }

    function _removeId(uint256 id) internal {
        uint256 idx = _idIndex[id];
        uint256 last = _ids[_ids.length - 1];
        _ids[idx - 1] = last;
        _idIndex[last] = idx;
        _ids.pop();
        delete _idIndex[id];
    }

    function _checkSettings(Settings memory s, int24 spacing) internal view {
        if (
            s.minWidth < spacing || s.maxWidth < s.minWidth || s.minWidth % spacing != 0 || s.maxWidth % spacing != 0
                || s.cooldown < factory.minCooldown() || s.compoundBps > 10_000 || s.slippageBps == 0
                || s.slippageBps > factory.maxSlippageBps() || s.rule > MAX_RULE
        ) revert BadSettings();
    }

    function _checkRange(int24 lower, int24 upper, int24 spacing, Settings memory s) internal pure {
        if (lower >= upper || lower % spacing != 0 || upper % spacing != 0) revert BadRange();
        int24 width = upper - lower;
        if (width < s.minWidth || width > s.maxWidth) revert BadRange();
    }

    function _slippage(Settings memory s) internal view returns (uint256 slip) {
        slip = s.slippageBps;
        uint256 cap = factory.maxSlippageBps();
        if (slip > cap) slip = cap;
    }
}
