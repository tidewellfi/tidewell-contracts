// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFeeDiscount} from "./interfaces/ITidewell.sol";

interface IVaultLookup {
    function vaultOf(address user, uint8 kind) external view returns (address);
}

/// @title ReferralRegistry
/// @notice Remembers who invited whom. A new user links to the wallet that invited them once, before their first
///         vault exists, and that link never changes. Invited users pay 10% less protocol fee for their first three
///         months. The inviter's reward (a share of the fee) is paid by the RevenueRouter.
///         Inviters can register one short invite code (8 characters, a-z and 2-9), so an invite link does not have
///         to show their wallet address. Codes are permanent and first come, first served.
/// @dev No owner and no settings: the rules are fixed in this contract.
contract ReferralRegistry is IFeeDiscount {
    uint256 public constant FRIEND_DISCOUNT_BPS = 1000; // 10% off the protocol fee
    uint256 public constant FRIEND_PERIOD = 90 days;

    IVaultLookup public immutable factory;

    mapping(address user => address) public referrerOf;
    mapping(address user => uint64) public joinedAt;
    mapping(bytes8 code => address) public ownerOfCode;
    mapping(address user => bytes8) public codeOf;

    event Referred(address indexed user, address indexed referrer);
    event CodeRegistered(address indexed user, bytes8 code);

    error AlreadyLinked();
    error InvalidReferrer();
    error NotNewUser();
    error BadCode();
    error CodeTaken();
    error HasCode();
    error UnknownCode();
    error NotFactory();

    constructor(address factory_) {
        factory = IVaultLookup(factory_);
    }

    /// @notice Registers the caller's invite code. One per wallet, permanent. Allowed characters: a-z and 2-9.
    function registerCode(bytes8 code) external {
        if (codeOf[msg.sender] != bytes8(0)) revert HasCode();
        for (uint256 i; i < 8; ++i) {
            bytes1 ch = code[i];
            if (!((ch >= 0x61 && ch <= 0x7a) || (ch >= 0x32 && ch <= 0x39))) revert BadCode();
        }
        if (ownerOfCode[code] != address(0)) revert CodeTaken();
        ownerOfCode[code] = msg.sender;
        codeOf[msg.sender] = code;
        emit CodeRegistered(msg.sender, code);
    }

    /// @notice Links the caller to the owner of an invite code. Only possible before the caller's first vault.
    function setReferrerByCode(bytes8 code) external {
        _link(msg.sender, _ownerOf(code));
    }

    /// @notice The factory links a new user's code in the same transaction as their first position
    ///         (factory.openWithPermit). Same rules as setReferrerByCode.
    function setReferrerByCodeFor(address user, bytes8 code) external {
        if (msg.sender != address(factory)) revert NotFactory();
        _link(user, _ownerOf(code));
    }

    /// @notice Links the caller to the wallet that invited them. Only possible before the caller's first vault.
    function setReferrer(address referrer) external {
        _link(msg.sender, referrer);
    }

    function _ownerOf(bytes8 code) internal view returns (address referrer) {
        referrer = ownerOfCode[code];
        if (referrer == address(0)) revert UnknownCode();
    }

    function _link(address user, address referrer) internal {
        if (referrerOf[user] != address(0)) revert AlreadyLinked();
        if (referrer == address(0) || referrer == user || referrerOf[referrer] == user) {
            revert InvalidReferrer();
        }
        if (factory.vaultOf(user, 0) != address(0) || factory.vaultOf(user, 1) != address(0)) {
            revert NotNewUser();
        }
        referrerOf[user] = referrer;
        joinedAt[user] = uint64(block.timestamp);
        emit Referred(user, referrer);
    }

    /// @notice The invited user's discount on the protocol fee, in basis points.
    function discountBps(address user) external view returns (uint256) {
        if (referrerOf[user] == address(0)) return 0;
        return block.timestamp < uint256(joinedAt[user]) + FRIEND_PERIOD ? FRIEND_DISCOUNT_BPS : 0;
    }
}
