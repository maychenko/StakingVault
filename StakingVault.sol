// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract TokenStaking is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");

    IERC20 public immutable stakingToken;

    uint256 public rewardRate = 100; 
    uint256 public minStakeAmount = 10 * 10**18;

    uint256 constant REWARD_INTERVAL = 60 seconds; 
    uint256 constant UNSTAKE_COOLDOWN = 5 minutes; 

    enum UserTier { Bronze, Silver, Gold, Diamond }

    struct UserInfo {
        uint256 amount;
        uint256 depositTime;
        uint256 lastClaimTime;    
        uint256 totalRewardsClaimed; 
        uint256 lockDuration;
        uint256 lockUntil;
        bool hasActiveStake;
    }

    struct GlobalStats {
        uint256 totalUsers;
        uint256 totalTokensStaked;
        uint256 totalTokensWithdrawn;
        uint256 totalRewardsPaid;
        uint256 stakeOperations;
        uint256 unstakeOperations;
        uint256 claimOperations;
    }

    GlobalStats public stats;

    mapping(address => UserInfo) public users;
    
    address[] private userAddresses;
    mapping(address => bool) private hasRegisteredAddress;

    event Staked(address indexed user, uint256 amount, uint256 lockDuration);
    event StakeIncreased(address indexed user, uint256 additionalAmount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 rewardAmount);
    event ContractPaused(address account);
    event ContractUnpaused(address account);
    event ConfigChanged(string param, uint256 newValue);
    event RoleGrantedCustom(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevokedCustom(bytes32 indexed role, address indexed account, address indexed sender);

    constructor(address _stakingToken) {
        require(_stakingToken != address(0), "Invalid token address");
        stakingToken = IERC20(_stakingToken);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender); 
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(AUDITOR_ROLE, msg.sender);
    }

    function stake(uint256 _amount, uint256 _lockDays) external whenNotPaused nonReentrant {
        require(_amount > 0, "Cannot stake 0 tokens");
        
        UserInfo storage user = users[msg.sender];

        if (!user.hasActiveStake) {
            require(_amount >= minStakeAmount, "Amount below minimum limit");
            require(_lockDays == 0 || _lockDays == 7 || _lockDays == 30 || _lockDays == 90, "Invalid lock duration");

            user.amount = _amount;
            user.depositTime = block.timestamp;
            user.lastClaimTime = block.timestamp;
            user.lockDuration = _lockDays * 1 days;
            user.lockUntil = block.timestamp + (_lockDays * 1 days);
            user.hasActiveStake = true;

            if (!hasRegisteredAddress[msg.sender]) {
                hasRegisteredAddress[msg.sender] = true;
                userAddresses.push(msg.sender);
                stats.totalUsers++;
            }

            emit Staked(msg.sender, _amount, _lockDays);
        } else {
            require(_lockDays == 0, "Cannot change lock period on additional stake");
            
            _claimReward(msg.sender);

            user.amount += _amount;
            if (user.lockDuration > 0) {
                user.lockUntil = block.timestamp + user.lockDuration;
            }

            emit StakeIncreased(msg.sender, _amount);
        }

        stats.totalTokensStaked += _amount;
        stats.stakeOperations++;

        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
    }

    function unstake(uint256 _amount) external whenNotPaused nonReentrant {
        UserInfo storage user = users[msg.sender];
        
        require(user.hasActiveStake, "No active stake found");
        require(_amount > 0, "Cannot withdraw 0");
        require(user.amount >= _amount, "Insufficient staked balance");
        require(block.timestamp >= user.lockUntil, "Tokens are still locked");
        require(block.timestamp >= user.lastClaimTime + UNSTAKE_COOLDOWN, "Withdraw cooldown active (5 mins)");

        _claimReward(msg.sender);

        user.amount -= _amount;
        stats.totalTokensWithdrawn += _amount;
        stats.unstakeOperations++;

        if (user.amount == 0) {
            user.hasActiveStake = false;
            user.lockUntil = 0;
            user.lockDuration = 0;
        }

        emit Unstaked(msg.sender, _amount);
        stakingToken.safeTransfer(msg.sender, _amount);
    }

    function claimReward() external whenNotPaused nonReentrant {
        require(users[msg.sender].hasActiveStake, "No active stake");
        _claimReward(msg.sender);
    }

    function _claimReward(address _userAddress) internal {
        UserInfo storage user = users[_userAddress];
        
        uint256 timePassed = block.timestamp - user.lastClaimTime;
        uint256 periods = timePassed / REWARD_INTERVAL;
        
        if (periods > 0) {
            uint256 reward = calculateReward(_userAddress);
            
            user.lastClaimTime += periods * REWARD_INTERVAL;

            if (reward > 0) {
                user.totalRewardsClaimed += reward;
                stats.totalRewardsPaid += reward;
                stats.claimOperations++;

                emit RewardClaimed(_userAddress, reward);
                stakingToken.safeTransfer(_userAddress, reward);
            }
        }
    }

    function calculateReward(address _userAddress) public view returns (uint256) {
        UserInfo memory user = users[_userAddress];
        if (!user.hasActiveStake) return 0;

        uint256 timePassed = block.timestamp - user.lastClaimTime;
        uint256 periods = timePassed / REWARD_INTERVAL; 
        
        if (periods == 0) return 0;

        uint256 baseReward = (user.amount * periods * rewardRate) / 10000;
        UserTier tier = getUserTier(_userAddress);
        uint256 tierMultiplier = 100; 
        
        if (tier == UserTier.Silver) tierMultiplier = 110; 
        else if (tier == UserTier.Gold) tierMultiplier = 125;   
        else if (tier == UserTier.Diamond) tierMultiplier = 150;

        baseReward = (baseReward * tierMultiplier) / 100;

        uint256 lockMultiplier = 100;
        if (user.lockDuration == 7 days) lockMultiplier = 120;   
        else if (user.lockDuration == 30 days) lockMultiplier = 150; 
        else if (user.lockDuration == 90 days) lockMultiplier = 200; 

        return (baseReward * lockMultiplier) / 100;
    }

    function getUserTier(address _userAddress) public view returns (UserTier) {
        uint256 amount = users[_userAddress].amount;
        
        if (amount >= 1000 * 10**18) return UserTier.Diamond;
        if (amount >= 500 * 10**18) return UserTier.Gold;
        if (amount >= 100 * 10**18) return UserTier.Silver;
        return UserTier.Bronze;
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
        emit ContractPaused(msg.sender);
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
        emit ContractUnpaused(msg.sender);
    }

    function setMinStakeAmount(uint256 _newMin) external onlyRole(ADMIN_ROLE) {
        minStakeAmount = _newMin;
        emit ConfigChanged("minStakeAmount", _newMin);
    }

    function setRewardRate(uint256 _newRate) external onlyRole(ADMIN_ROLE) {
        rewardRate = _newRate;
        emit ConfigChanged("rewardRate", _newRate);
    }

    function grantRoleCustom(bytes32 _role, address _account) external onlyRole(ADMIN_ROLE) {
        _grantRole(_role, _account);
        emit RoleGrantedCustom(_role, _account, msg.sender);
    }

    function revokeRoleCustom(bytes32 _role, address _account) external onlyRole(ADMIN_ROLE) {
        _revokeRole(_role, _account);
        emit RoleRevokedCustom(_role, _account, msg.sender);
    }

    function getPlayerStats(address _userAddress) external view onlyRole(AUDITOR_ROLE) returns (UserInfo memory) {
        return users[_userAddress];
    }

    function getAllPlayers() external view onlyRole(AUDITOR_ROLE) returns (address[] memory) {
        return userAddresses;
    }

    function getGlobalStats() external view onlyRole(AUDITOR_ROLE) returns (GlobalStats memory) {
        return stats;
    }
}
