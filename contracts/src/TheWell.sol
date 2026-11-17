// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IFeeDiscount} from "./interfaces/ITidewell.sol";

/// @title TheWell
/// @notice Stake TIDE without a lock. Your tier (how much, and how long without interruption) sets your discount on
///         the protocol fee, from the moment you stake. The staking share of protocol revenue (30%) arrives here in ETH
///         and is paid out as a steady stream: every amount that comes in is spread over the next 30 days, and each
///         second every staker earns a share in proportion to their weight (staked amount × tier boost). Claim any time.
/// @dev Also the factory's fee-discount source: it adds the referral discount of invited users, capped at 50%.
///      Rewards: a per-weight accumulator (as in Synthetix StakingRewards) with a rolling 30-day stream. While nobody
///      stakes, the stream waits instead of paying out to no one. A weight is updated whenever its owner stakes,
///      unstakes or claims, and anyone may call refresh() so a boost that grew with time counts (the keeper does).
///      The owner (the 48-hour timelock of the admin Safe) can only adjust the tier table within limits; it can never
///      touch staked TIDE or the ETH.
contract TheWell is IFeeDiscount, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_DISCOUNT_BPS = 5000;
    uint256 public constant TIERS = 4;

    IERC20 public immutable tide;
    IFeeDiscount public immutable referrals;

    /// Minimum stake per amount tier, in TIDE (18 decimals).
    uint256[TIERS] public amountTiers;
    /// Minimum uninterrupted staking time per duration tier, in seconds. The first is zero: discount right away.
    uint256[TIERS] public durationTiers;
    /// Discount on the protocol fee in basis points, [amount tier][duration tier].
    uint16[TIERS][TIERS] public discounts;
    /// Reward weight in basis points (10000 = 1x), for when rewards go live.
    uint16[TIERS][TIERS] public boosts;

    struct StakeInfo {
        uint256 amount;
        uint64 since; // amount-weighted start time; reset only when everything is unstaked
    }

    mapping(address user => StakeInfo) public stakes;
    uint256 public totalStaked;

    // ---- rewards
    /// Every amount that arrives is paid out over this period (rolling: what is still to come is added to it).
    uint256 public constant DURATION = 30 days;
    uint256 internal constant SCALE = 1e18;
    /// ETH per second, times 1e18.
    uint256 public rewardRate;
    uint256 public periodFinish;
    uint256 public lastUpdate;
    /// Rewards per unit of weight so far, times 1e18.
    uint256 public rewardPerWeightStored;
    uint256 public totalWeight;
    mapping(address user => uint256) public weightOf;
    mapping(address user => uint256) public paidPerWeight;
    mapping(address user => uint256) public owed;
    uint256 public totalPaid;

    event Staked(address indexed user, uint256 amount, uint256 total, uint64 since);
    event Unstaked(address indexed user, uint256 amount, uint256 total);
    event TiersSet();
    event ReserveIn(address indexed from, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    event WeightSet(address indexed user, uint256 weight);

    error ZeroAmount();
    error TooMuch();
    error BadTiers();
    error ZeroAddress();
    error TransferFailed();

    constructor(address owner_, address tide_, address referrals_) Ownable(owner_) {
        if (tide_ == address(0)) revert ZeroAddress();
        tide = IERC20(tide_);
        referrals = IFeeDiscount(referrals_);
        _setTiers(
            [uint256(50_000e18), 200_000e18, 750_000e18, 2_000_000e18],
            [uint256(0), 30 days, 90 days, 180 days],
            [[uint16(300), 500, 800, 1200], [uint16(600), 1000, 1500, 2000], [uint16(1000), 1600, 2400, 3200], [uint16(1500), 2500, 3700, 5000]],
            [[uint16(10500), 11000, 12000, 13000], [uint16(11000), 12000, 13500, 15000], [uint16(12000), 13500, 15500, 17500], [uint16(13000), 15000, 17500, 20000]]
        );
    }

    /// Protocol revenue for stakers arrives here in ETH and joins the stream: what is still to be paid plus this,
    /// spread over the next 30 days.
    receive() external payable {
        _accrue();
        uint256 left = periodFinish > block.timestamp ? (periodFinish - block.timestamp) * rewardRate : 0;
        rewardRate = (msg.value * SCALE + left) / DURATION;
        periodFinish = block.timestamp + DURATION;
        emit ReserveIn(msg.sender, msg.value);
    }

    // ---------------------------------------------------------------- rewards

    /// @notice Rewards per unit of weight up to now (times 1e18).
    function rewardPerWeight() public view returns (uint256) {
        uint256 t = _until();
        if (totalWeight == 0 || t <= lastUpdate) return rewardPerWeightStored;
        return rewardPerWeightStored + ((t - lastUpdate) * rewardRate) / totalWeight;
    }

    /// @notice ETH a staker can claim right now.
    function earned(address user) public view returns (uint256) {
        return owed[user] + (weightOf[user] * (rewardPerWeight() - paidPerWeight[user])) / SCALE;
    }

    /// @notice ETH per second the whole stream pays out right now, in wei (0 when nothing is streaming).
    function ratePerSecond() external view returns (uint256) {
        return block.timestamp < periodFinish ? rewardRate / SCALE : 0;
    }

    /// @notice Sends everything you have earned, in ETH. Also brings your boost up to date.
    function claim() external nonReentrant returns (uint256 amount) {
        _settle(msg.sender);
        amount = owed[msg.sender];
        owed[msg.sender] = 0;
        _reweigh(msg.sender);
        if (amount > 0) {
            totalPaid += amount;
            (bool ok,) = msg.sender.call{value: amount}("");
            if (!ok) revert TransferFailed();
            emit RewardPaid(msg.sender, amount);
        }
    }

    /// @notice Brings stakers' weights up to date (a boost grows by itself as time passes). Anyone may call it.
    function refresh(address[] calldata users) external {
        for (uint256 i; i < users.length; ++i) {
            _settle(users[i]);
            _reweigh(users[i]);
        }
    }

    /// @dev The stream runs until periodFinish.
    function _until() internal view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /// @dev Books the stream up to now. With nobody staking, the time is added to the end instead: nothing is lost.
    function _accrue() internal {
        uint256 t = _until();
        if (t > lastUpdate) {
            if (totalWeight == 0) {
                uint256 rest = periodFinish > t ? periodFinish - t : 0;
                periodFinish = block.timestamp + rest + (t - lastUpdate);
            } else {
                rewardPerWeightStored += ((t - lastUpdate) * rewardRate) / totalWeight;
            }
        }
        lastUpdate = block.timestamp;
    }

    function _settle(address user) internal {
        _accrue();
        owed[user] = earned(user);
        paidPerWeight[user] = rewardPerWeightStored;
    }

    function _reweigh(address user) internal {
        uint256 w = (stakes[user].amount * boostBps(user)) / 10_000;
        uint256 old = weightOf[user];
        if (w == old) return;
        totalWeight = totalWeight - old + w;
        weightOf[user] = w;
        emit WeightSet(user, w);
    }

    // ---------------------------------------------------------------- staking

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _settle(msg.sender);
        uint256 before = tide.balanceOf(address(this));
        tide.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = tide.balanceOf(address(this)) - before;
        StakeInfo storage s = stakes[msg.sender];
        uint256 total = s.amount + received;
        // Adding to a stake moves its start time forward in proportion, so a small top-up keeps most of the time.
        s.since = s.amount == 0
            ? uint64(block.timestamp)
            : uint64((s.amount * s.since + received * block.timestamp) / total);
        s.amount = total;
        totalStaked += received;
        _reweigh(msg.sender);
        emit Staked(msg.sender, received, total, s.since);
    }

    /// @notice Unstake any time. A partial unstake keeps your time; unstaking everything starts it over.
    function unstake(uint256 amount) external nonReentrant {
        StakeInfo storage s = stakes[msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (amount > s.amount) revert TooMuch();
        _settle(msg.sender);
        s.amount -= amount;
        if (s.amount == 0) s.since = 0;
        totalStaked -= amount;
        _reweigh(msg.sender);
        tide.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount, s.amount);
    }

    // ---------------------------------------------------------------- tiers and discount

    /// @notice Tier of a user: amount row and duration column, or -1 when below the first tier.
    function tierOf(address user) public view returns (int256 row, int256 col) {
        StakeInfo memory s = stakes[user];
        row = -1;
        col = -1;
        if (s.amount == 0) return (row, col);
        uint256 age = block.timestamp - s.since;
        for (uint256 i; i < TIERS; ++i) {
            if (s.amount >= amountTiers[i]) row = int256(i);
            if (age >= durationTiers[i]) col = int256(i);
        }
    }

    function stakingDiscountBps(address user) public view returns (uint256) {
        (int256 r, int256 c) = tierOf(user);
        if (r < 0 || c < 0) return 0;
        return discounts[uint256(r)][uint256(c)];
    }

    function boostBps(address user) public view returns (uint256) {
        (int256 r, int256 c) = tierOf(user);
        if (r < 0 || c < 0) return 10_000;
        return boosts[uint256(r)][uint256(c)];
    }

    /// @inheritdoc IFeeDiscount
    /// @dev Staking discount plus the referral discount of invited users, capped at 50%.
    function discountBps(address user) external view returns (uint256 d) {
        d = stakingDiscountBps(user);
        if (address(referrals) != address(0)) d += referrals.discountBps(user);
        if (d > MAX_DISCOUNT_BPS) d = MAX_DISCOUNT_BPS;
    }

    // ---------------------------------------------------------------- owner (timelocked)

    function setTiers(
        uint256[TIERS] calldata amounts,
        uint256[TIERS] calldata durations,
        uint16[TIERS][TIERS] calldata discounts_,
        uint16[TIERS][TIERS] calldata boosts_
    ) external onlyOwner {
        _setTiers(amounts, durations, discounts_, boosts_);
    }

    function _setTiers(
        uint256[TIERS] memory amounts,
        uint256[TIERS] memory durations,
        uint16[TIERS][TIERS] memory discounts_,
        uint16[TIERS][TIERS] memory boosts_
    ) internal {
        if (amounts[0] == 0 || durations[0] != 0) revert BadTiers();
        for (uint256 i = 1; i < TIERS; ++i) {
            if (amounts[i] <= amounts[i - 1] || durations[i] <= durations[i - 1]) revert BadTiers();
        }
        for (uint256 r; r < TIERS; ++r) {
            for (uint256 c; c < TIERS; ++c) {
                if (discounts_[r][c] > MAX_DISCOUNT_BPS || boosts_[r][c] < 10_000 || boosts_[r][c] > 30_000) {
                    revert BadTiers();
                }
            }
        }
        amountTiers = amounts;
        durationTiers = durations;
        discounts = discounts_;
        boosts = boosts_;
        emit TiersSet();
    }
}
