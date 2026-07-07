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
                
            }
            
        }
    }
}