// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title VestaLock — linear token vesting with cliff, revocable by funder.
/// Anyone can fund a schedule; beneficiary releases vested tranches; funder
/// can revoke, which pays out vested-to-beneficiary and returns the rest.
contract VestaLock is ReentrancyGuard {
    struct Sched {
        address token;
        address funder;
        address beneficiary;
        uint256 total;
        uint256 released;
        uint64 start;
        uint64 cliff; // seconds after start before anything vests
        uint64 duration; // total seconds
        bool revoked;
    }

    Sched[] private _scheds;

    event Locked(uint256 indexed id, address indexed token, address indexed beneficiary, uint256 total);
    event Released(uint256 indexed id, address indexed beneficiary, uint256 amount);
    event Revoked(uint256 indexed id, uint256 toBeneficiary, uint256 toFunder);

    function lock(
        address token,
        address beneficiary,
        uint256 amount,
        uint64 startDelay,
        uint64 cliffSecs,
        uint64 durationSecs
    ) external nonReentrant returns (uint256) {
        require(token != address(0), "Zero token");
        require(beneficiary != address(0), "Zero beneficiary");
        require(amount > 0, "Bad amount");
        require(durationSecs > 0, "Bad duration");
        require(cliffSecs <= durationSecs, "Cliff over duration");
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Fund failed");
        _scheds.push(Sched({
            token: token,
            funder: msg.sender,
            beneficiary: beneficiary,
            total: amount,
            released: 0,
            start: uint64(block.timestamp) + startDelay,
            cliff: cliffSecs,
            duration: durationSecs,
            revoked: false
        }));
        uint256 id = _scheds.length - 1;
        emit Locked(id, token, beneficiary, amount);
        return id;
    }

    function vested(uint256 id) public view returns (uint256) {
        Sched storage s = _scheds[id];
        uint256 t = block.timestamp;
        if (t < uint256(s.start) + s.cliff) return 0;
        uint256 end = uint256(s.start) + s.duration;
        if (t >= end) return s.total;
        return (s.total * (t - s.start)) / s.duration;
    }

    function release(uint256 id) external nonReentrant {
        Sched storage s = _scheds[id];
        require(!s.revoked, "Revoked");
        uint256 pay = vested(id) - s.released;
        require(pay > 0, "Nothing vested");
        s.released += pay;
        require(IERC20(s.token).transfer(s.beneficiary, pay), "Pay failed");
        emit Released(id, s.beneficiary, pay);
    }

    function revoke(uint256 id) external nonReentrant {
        Sched storage s = _scheds[id];
        require(msg.sender == s.funder, "Not funder");
        require(!s.revoked, "Revoked");
        s.revoked = true;
        uint256 v = vested(id);
        uint256 toBen = v - s.released;
        uint256 toFunder = s.total - v;
        s.released = v;
        if (toBen > 0) require(IERC20(s.token).transfer(s.beneficiary, toBen), "Ben pay failed");
        if (toFunder > 0) require(IERC20(s.token).transfer(s.funder, toFunder), "Funder pay failed");
        emit Revoked(id, toBen, toFunder);
    }

    function totalSchedules() external view returns (uint256) {
        return _scheds.length;
    }

    function getSchedule(uint256 id)
        external
        view
        returns (address token, address funder, address beneficiary, uint256 total, uint256 released, uint64 start, uint64 cliff, uint64 duration, bool revoked)
    {
        Sched storage s = _scheds[id];
        return (s.token, s.funder, s.beneficiary, s.total, s.released, s.start, s.cliff, s.duration, s.revoked);
    }
}
