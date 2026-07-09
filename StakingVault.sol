// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract StakingVault is Ownable, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");

    IERC20 public immutable stakingToken;
    uint256 public minStakeAmount = 10 * 10**18; 
    uint256 public baseRewardRate = 100; 
    enum UserTier { Bronze, Silver, Gold, Diamond }

    struct UserInfo {
        uint256 stakedAmount;
        uint256 startTime;
        uint256 lastClaimTime;
        uint256 totalRewardsClaimed;
        uint256 lockDuration;
        uint256 unlockTime;
    }

    mapping(address => UserInfo) public users;
    uint256 public totalUsers;
    uint256 public totalStaked;
    uint256 public totalUnstaked;
    uint256 public totalRewardsPaid;
    uint256 public stakeCount;
    uint256 public unstakeCount;
    uint256 public claimCount;

    mapping(address => bool) private hasStakedBefore;
    event StakeCreated(address indexed user, uint256 amount, uint256 lockDays);
    event StakeIncreased(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event ContractPaused(address indexed admin);
    event ContractUnpaused(address indexed admin);
    event MinStakeChanged(uint256 oldValue, uint256 newValue);
    event RewardRateChanged(uint256 oldValue, uint256 newValue);
    event RoleGrantedCustom(bytes32 indexed role, address indexed account);
    event RoleRevokedCustom(bytes32 indexed role, address indexed account);

    constructor(address _tokenAddress) Ownable(msg.sender) {
        require(_tokenAddress != address(0), "Invalid token address");
        stakingToken = IERC20(_tokenAddress);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(AUDITOR_ROLE, msg.sender);
    }

    function stake(uint256 _amount, uint256 _lockDays) external whenNotPaused nonReentrant {
        require(_amount > 0, "Cannot stake 0 tokens");
        
        UserInfo storage user = users[msg.sender];

        if (user.stakedAmount == 0) {
            require(_amount >= minStakeAmount, "Amount below minimum stake");
            require(_lockDays == 7 || _lockDays == 30 || _lockDays == 90, "Invalid lock duration");

            user.stakedAmount = _amount;
            user.startTime = block.timestamp;
            user.lastClaimTime = block.timestamp;
            user.lockDuration = _lockDays * 1 days;
            user.unlockTime = block.timestamp + user.lockDuration;
            if (!hasStakedBefore[msg.sender]) {
                hasStakedBefore[msg.sender] = true;
                totalUsers++;
            }

            emit StakeCreated(msg.sender, _amount, _lockDays);
        } else {
            uint256 pending = calculateReward(msg.sender);
            if (pending > 0) {
                user.totalRewardsClaimed += pending;
                totalRewardsPaid += pending;
                stakingToken.safeTransfer(msg.sender, pending);
                emit RewardClaimed(msg.sender, pending);
                claimCount++;
            }

            user.stakedAmount += _amount;
            user.lastClaimTime = block.timestamp;

            emit StakeIncreased(msg.sender, _amount);
        }

        totalStaked += _amount;
        stakeCount++;
        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
    }

    function unstake(uint256 _amount) external whenNotPaused nonReentrant {
        UserInfo storage user = users[msg.sender];

        require(_amount > 0, "Cannot unstake 0");
        require(user.stakedAmount >= _amount, "Not enough staked balance");
        require(block.timestamp >= user.unlockTime, "Tokens are still locked");
        require(block.timestamp >= user.lastClaimTime + 5 minutes, "Allowed once in 5 minutes");

        uint256 pending = calculateReward(msg.sender);
        
        user.stakedAmount -= _amount;
        user.lastClaimTime = block.timestamp;

        uint256 totalToTransfer = _amount;
        if (pending > 0) {
            user.totalRewardsClaimed += pending;
            totalRewardsPaid += pending;
            totalToTransfer += pending;
            emit RewardClaimed(msg.sender, pending);
            claimCount++;
        }

        totalUnstaked += _amount;
        unstakeCount++;

        if (user.stakedAmount == 0) {
            user.startTime = 0;
            user.unlockTime = 0;
            user.lockDuration = 0;
        }

        emit Unstaked(msg.sender, _amount);
        
        stakingToken.safeTransfer(msg.sender, totalToTransfer);
    }

    function claimReward() external whenNotPaused nonReentrant {
        UserInfo storage user = users[msg.sender];
        require(user.stakedAmount > 0, "No active stake");

        uint256 pending = calculateReward(msg.sender);
        require(pending > 0, "No rewards accrued");

        user.lastClaimTime = block.timestamp;
        user.totalRewardsClaimed += pending;
        totalRewardsPaid += pending;
        claimCount++;

        emit RewardClaimed(msg.sender, pending);

        stakingToken.safeTransfer(msg.sender, pending);
    }


    function getUserTier(address _user) public view returns (UserTier) {
        uint256 amount = users[_user].stakedAmount / 10**18; 
        if (amount >= 1000) return UserTier.Diamond;
        if (amount >= 500) return UserTier.Gold;
        if (amount >= 100) return UserTier.Silver;
        return UserTier.Bronze;
    }
    function calculateReward(address _user) public view returns (uint256) {
        UserInfo memory user = users[_user];
        if (user.stakedAmount == 0) return 0;
        uint256 timePassed = block.timestamp - user.lastClaimTime;
        uint256 minutesPassed = timePassed / 60; 

        if (minutesPassed == 0) return 0;

        uint256 tierMultiplier = 100;
        UserTier tier = getUserTier(_user);
        if (tier == UserTier.Silver) tierMultiplier = 120;
        if (tier == UserTier.Gold) tierMultiplier = 150;  
        if (tier == UserTier.Diamond) tierMultiplier = 200; 

        uint256 lockMultiplier = 100;
        if (user.lockDuration == 7 days) lockMultiplier = 110;  
        if (user.lockDuration == 30 days) lockMultiplier = 130; 
        if (user.lockDuration == 90 days) lockMultiplier = 160; 


        uint256 reward = (user.stakedAmount * baseRewardRate * minutesPassed * tierMultiplier * lockMultiplier) / (10000 * 10000);
        
        return reward;
    }


    function setMinStakeAmount(uint256 _newMin) external onlyRole(ADMIN_ROLE) {
        uint256 old = minStakeAmount;
        minStakeAmount = _newMin;
        emit MinStakeChanged(old, _newMin);
    }

    function setBaseRewardRate(uint256 _newRate) external onlyRole(ADMIN_ROLE) {
        uint256 old = baseRewardRate;
        baseRewardRate = _newRate;
        emit RewardRateChanged(old, _newRate);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
        emit ContractPaused(msg.sender);
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
        emit ContractUnpaused(msg.sender);
    }

    function customGrantRole(bytes32 _role, address _account) external onlyRole(ADMIN_ROLE) {
        grantRole(_role, _account);
        emit RoleGrantedCustom(_role, _account);
    }

    function customRevokeRole(bytes32 _role, address _account) external onlyRole(ADMIN_ROLE) {
        revokeRole(_role, _account);
        emit RoleRevokedCustom(_role, _account);
    }

    function getFullUserInfo(address _user) external view onlyRole(AUDITOR_ROLE) returns (UserInfo memory) {
        return users[_user];
    }

    function getGlobalStats() external view onlyRole(AUDITOR_ROLE) returns (
        uint256 _totalUsers, uint256 _totalStaked, uint256 _totalUnstaked, 
        uint256 _totalRewardsPaid, uint256 _stakeCount, uint256 _unstakeCount, uint256 _claimCount
    ) {
        return (totalUsers, totalStaked, totalUnstaked, totalRewardsPaid, stakeCount, unstakeCount, claimCount);
    }
}
