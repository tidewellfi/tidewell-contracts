// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

interface IBoostFactory {
    function isVault(address vault) external view returns (bool);
}

interface IBoostVault {
    function owner() external view returns (address);
}

/// @title BoostDistributor
/// @notice Pays the extra ETH rewards of boosted pools. It is funded from the boost reserve (which pays out only
///         through the 48-hour timelock). Each round it commits 30% of what it holds to three pools; an operator
///         (the keeper) credits liquidity providers as the round runs. What a round did not credit is split when the
///         round is released: half stays here for the next rounds, half goes to the buyback-and-burn contract. The
///         owner (the timelock) can also send free ETH back to the boost reserve. The contract limits the operator:
///         - the credited total of a pool can never pass that pool's round budget,
///         - it streams: at any moment at most the elapsed part of the round can be credited,
///         - one wallet gets at most `CAP_BPS` of a pool's round budget (also streamed over the round).
///         Nobody, the owner included, can take ETH out other than as credits claimed by the wallets they belong to,
///         unused ETH sent to the burner, and free ETH sent back to the boost reserve (owner only).
contract BoostDistributor is Ownable2Step, ReentrancyGuardTransient {
    uint256 public constant SLOTS = 3;
    uint256 public constant CAP_BPS = 2000; // 20% of a pool's round budget per wallet
    uint256 public constant ROUND_SHARE_BPS = 3000; // a round commits 30% of what is free
    uint256 public constant MIN_BUDGET = 0.01 ether; // below this a round is not started
    uint256 public constant GRACE = 2 days; // credits for a round are accepted this long after it ends
    uint256[3] public SHARE_BPS = [3000, 3000, 4000]; // bluechip, stock token, project

    uint256 public immutable roundLength;
    IBoostFactory[] public factories;
    /// @notice Where the owner can send free ETH back to (the boost reserve), and where half of every round's unused ETH goes.
    address public immutable reserve;
    address public immutable burner;

    struct Round {
        uint64 start;
        uint64 end;
        bool released;
        bytes32[3] pool;
        uint256[3] budget;
        uint256[3] credited;
    }

    uint256 public roundCount;
    mapping(uint256 round => Round) internal _rounds;
    mapping(uint256 round => mapping(uint256 slot => mapping(address wallet => uint256))) public walletCredited;
    mapping(address wallet => uint256) public claimable;
    mapping(address wallet => uint256) public claimedTotal;
    /// @notice ETH that is committed to rounds or owed to wallets, and so not free for a new round.
    uint256 public committed;
    address public operator;
    /// @notice When round 1 starts; set by the owner (before round 1), the later rounds follow each other from it.
    uint64 public firstStart;

    event Funded(address indexed from, uint256 amount);
    event RoundStarted(uint256 indexed round, uint64 start, uint64 end, bytes32[3] pool, uint256[3] budget);
    event Credited(uint256 indexed round, uint256 indexed slot, address indexed wallet, uint256 amount);
    event Claimed(address indexed wallet, address indexed to, uint256 amount);
    event Released(uint256 indexed round, uint256 unused);
    event Burned(uint256 indexed round, uint256 amount);
    event ReturnedToReserve(uint256 amount);
    event OperatorSet(address operator);
    event FirstStartSet(uint64 start);

    error NotOperator();
    error TooEarly();
    error TooSmall();
    error BadInput();
    error OverBudget();
    error OverStream();
    error OverCap();
    error Closed();
    error NothingToClaim();
    error NotYourVault();
    error TransferFailed();

    constructor(
        address owner_,
        address operator_,
        uint256 roundLength_,
        address[] memory factories_,
        address reserve_,
        address burner_
    ) Ownable(owner_) {
        if (roundLength_ == 0 || reserve_ == address(0) || burner_ == address(0)) revert BadInput();
        reserve = reserve_;
        burner = burner_;
        roundLength = roundLength_;
        operator = operator_;
        for (uint256 i; i < factories_.length; i++) factories.push(IBoostFactory(factories_[i]));
        emit OperatorSet(operator_);
    }

    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }

    function setOperator(address o) external onlyOwner {
        operator = o;
        emit OperatorSet(o);
    }

    function setFirstStart(uint64 start) external onlyOwner {
        if (roundCount != 0 || start < block.timestamp) revert BadInput();
        firstStart = start;
        emit FirstStartSet(start);
    }

    // ---------------------------------------------------------------- views

    function getRound(uint256 id) external view returns (Round memory) {
        return _rounds[id];
    }

    /// @notice ETH that is not committed to anything: what the next round draws from.
    function free() public view returns (uint256) {
        uint256 bal = address(this).balance;
        return bal > committed ? bal - committed : 0;
    }

    /// @notice The most that may be credited so far in a pool for a given total (budget or wallet cap), by time.
    function streamed(uint256 id, uint256 amount) public view returns (uint256) {
        Round storage r = _rounds[id];
        if (block.timestamp >= r.end) return amount;
        if (block.timestamp <= r.start) return 0;
        return (amount * (block.timestamp - r.start)) / (r.end - r.start);
    }

    // ---------------------------------------------------------------- rounds

    /// @notice Starts the next round, once the last one has ended. Anyone can call it. The budget is 30% of the free
    ///         ETH, split 30/30/40 over the three pools. The pools come from the vote (the keeper reads it).
    function startRound(bytes32[3] calldata pool) external {
        if (msg.sender != operator) revert NotOperator();
        uint256 prevEnd = roundCount == 0 ? firstStart : _rounds[roundCount].end;
        if (prevEnd == 0 || block.timestamp < prevEnd) revert TooEarly();
        uint256 total = (free() * ROUND_SHARE_BPS) / 10_000;
        if (total < MIN_BUDGET) revert TooSmall();
        for (uint256 i; i < SLOTS; i++) if (pool[i] == bytes32(0)) revert BadInput();
        uint256 id = ++roundCount;
        Round storage r = _rounds[id];
        // A round starts where the last one ended, so rounds follow each other without a gap.
        uint64 start = uint64(prevEnd);
        r.start = start;
        r.end = start + uint64(roundLength);
        uint256 sum;
        for (uint256 i; i < SLOTS; i++) {
            r.pool[i] = pool[i];
            r.budget[i] = (total * SHARE_BPS[i]) / 10_000;
            sum += r.budget[i];
        }
        committed += sum;
        emit RoundStarted(id, r.start, r.end, r.pool, r.budget);
    }

    /// @notice What a finished round did not credit: half stays here as free ETH for the next rounds, half goes to the
    ///         buyback-and-burn contract. Anyone can call it, once the grace has passed.
    function release(uint256 id) external {
        Round storage r = _rounds[id];
        if (r.end == 0 || r.released) revert BadInput();
        if (block.timestamp < r.end + GRACE) revert TooEarly();
        r.released = true;
        uint256 unused;
        for (uint256 i; i < SLOTS; i++) unused += r.budget[i] - r.credited[i];
        committed -= unused;
        emit Released(id, unused);
        uint256 toBurn = unused / 2;
        if (toBurn > 0) {
            // If the burner cannot take it, the ETH simply stays here as free ETH. It can never block the release.
            (bool ok,) = burner.call{value: toBurn}("");
            if (ok) emit Burned(id, toBurn);
        }
    }

    /// @notice The owner (the 48-hour timelock) sends free ETH back to the boost reserve. Committed ETH cannot leave.
    function returnToReserve(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0 || amount > free()) revert BadInput();
        (bool ok,) = reserve.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit ReturnedToReserve(amount);
    }

    // ---------------------------------------------------------------- credits

    /// @notice The keeper credits wallets for a pool of a round. Amounts are what was earned since the last call.
    function credit(uint256 id, uint256 slot, address[] calldata wallets, uint256[] calldata amounts) external {
        if (msg.sender != operator) revert NotOperator();
        if (wallets.length != amounts.length || slot >= SLOTS) revert BadInput();
        Round storage r = _rounds[id];
        if (r.end == 0 || r.released || block.timestamp > r.end + GRACE) revert Closed();
        uint256 budget = r.budget[slot];
        uint256 walletCap = streamed(id, (budget * CAP_BPS) / 10_000);
        uint256 added;
        for (uint256 i; i < wallets.length; i++) {
            address w = wallets[i];
            uint256 a = amounts[i];
            if (w == address(0)) revert BadInput();
            uint256 now_ = walletCredited[id][slot][w] + a;
            if (now_ > walletCap) revert OverCap();
            walletCredited[id][slot][w] = now_;
            claimable[w] += a;
            added += a;
            emit Credited(id, slot, w, a);
        }
        uint256 total = r.credited[slot] + added;
        if (total > budget) revert OverBudget();
        if (total > streamed(id, budget)) revert OverStream();
        r.credited[slot] = total;
    }

    // ---------------------------------------------------------------- claim / compound

    /// @notice Sends all your credited ETH to your wallet.
    function claim() external nonReentrant returns (uint256 amount) {
        amount = _take(msg.sender);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Claimed(msg.sender, msg.sender, amount);
    }

    /// @notice Sends your credited ETH into one of your own Tidewell vaults, where it waits as ETH ready to claim and
    ///         can be reinvested with the vault's compound (the app does both in a row).
    function claimToVault(address vault) external nonReentrant returns (uint256 amount) {
        if (!_isVaultOf(vault, msg.sender)) revert NotYourVault();
        amount = _take(msg.sender);
        (bool ok,) = vault.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Claimed(msg.sender, vault, amount);
    }

    function _take(address w) internal returns (uint256 amount) {
        amount = claimable[w];
        if (amount == 0) revert NothingToClaim();
        claimable[w] = 0;
        claimedTotal[w] += amount;
        committed -= amount;
    }

    function _isVaultOf(address vault, address user) internal view returns (bool) {
        for (uint256 i; i < factories.length; i++) {
            if (factories[i].isVault(vault)) return IBoostVault(vault).owner() == user;
        }
        return false;
    }
}
