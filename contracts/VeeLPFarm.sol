// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interface/IPangolinERC20.sol";
import "./interface/IVeeERC20.sol";
import "./interface/IVeeHub.sol";
contract VeeLPFarm is Initializable, OwnableUpgradeable{
    using SafeERC20 for IERC20;
    using Math for uint256;
    bool internal _notEntered;

    // Info of each user.
    struct UserInfo {
        uint amount;     // How many LP tokens the user has provided.
        uint lockingAmount;     // How many LP tokens the user has provided.
        uint unlockedAmount;     // How many LP tokens the user has provided.
        uint rewardDebt; // Reward debt. See explanation below.
        bool inBlackList;
    }

    // Info of each pool.
    struct PoolInfo {
        address lpToken;           // Address of LP token contract.
        uint allocPoint;       // How many allocation points assigned to this pool. CAKEs to distribute per block.
        uint lastRewardBlock;  // Last block number that CAKEs distribution occurs.
        uint accRewardsPerShare; // Accumulated CAKEs per share, times 1e12. See below.
    }

    address public vee;
    address payable public veeHub;

    // vee tokens created per block.
    uint public rewardsPerBlock;
    // Bonus muliplier for early vee makers.
    uint public BONUS_MULTIPLIER;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint public totalAllocPoint;
    // The block number when vee mining starts.
    uint public startBlock;
    uint public endBlock;
    mapping (address => bool) tokenAddedList;
    mapping (address => uint) public lpTokenTotal;

    event Deposit(address indexed payer, address indexed user, uint indexed pid, uint amount);
    event Withdraw(address indexed user, uint indexed pid, uint amount);
    event EmergencyWithdraw(address indexed user, uint indexed pid, uint amount, uint unlockedAmount, uint lockingAmount);
    event ClaimVee(address indexed user,uint256 indexed pid,uint256 veeReward);
    event NewVeeHub(address newVeeHub, address oldVeeHub);
    event NewRewardsPerBlock(uint newRewardsPerBlock, uint oldRewardsPerBlock);

    modifier nonReentrant() {
        require(_notEntered, "re-entered!");
        _notEntered = false;
        _;
        _notEntered = true;
    }
    function initialize(
        address _vee,
        uint _rewardsPerBlock,
        uint _startBlock,
        uint _endBlock
    ) public initializer {
        vee = _vee;
        rewardsPerBlock = _rewardsPerBlock;
        startBlock = _startBlock;
        endBlock = _endBlock;
        totalAllocPoint = 0;
        BONUS_MULTIPLIER = 1;
        _notEntered = true;
        __Ownable_init();
    }

    function updateMultiplier(uint multiplierNumber) public onlyOwner {
        BONUS_MULTIPLIER = multiplierNumber;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint _allocPoint, address _lpToken, bool _withUpdate) public onlyOwner {
        require(!tokenAddedList[_lpToken], "token exists");
        if (_withUpdate) {
            _updateAllPools();
        }
        uint lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint + _allocPoint;
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accRewardsPerShare: 0
        }));
        tokenAddedList[_lpToken] = true;
        updateStakingPool();
    }

    // Update the given pool's vee allocation point. Can only be called by the owner.
    function set(uint _pid, uint _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            _updateAllPools();
        }
        uint prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint - prevAllocPoint + _allocPoint;
            updateStakingPool();
        }
    }

    function updateStakingPool() internal {
        uint length = poolInfo.length;
        uint points = 0;
        for (uint pid = 0; pid < length; ++pid) {
            points = points + poolInfo[pid].allocPoint;
        }
        totalAllocPoint = points;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint _from, uint _to) internal view returns (uint) {
        // return (_to - _from) * BONUS_MULTIPLIER;
        if (_to <= endBlock) {
            return (_to - _from) * BONUS_MULTIPLIER;
        } else if (_from >= endBlock) {
            return 0;
        } else {
            return (endBlock - _from) * BONUS_MULTIPLIER;
        }
    }

    // View function to see pending vee on frontend.
    function pendingRewards(uint _pid, address _user) external view returns (uint) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint accRewardsPerShare = pool.accRewardsPerShare;
        uint lpSupply = IPangolinERC20(pool.lpToken).balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint rewardsReward = multiplier * rewardsPerBlock * pool.allocPoint / totalAllocPoint;
            accRewardsPerShare = accRewardsPerShare + rewardsReward * 1e12 / lpSupply;
        }
        return user.amount * accRewardsPerShare / 1e12 - user.rewardDebt;
    }

    function updateAllPools() external {
        _updateAllPools();
    }

    function _updateAllPools() internal {
        uint length = poolInfo.length;
        for (uint pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    function updatePool(uint _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint lpSupply = IPangolinERC20(pool.lpToken).balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint veeReward = multiplier * rewardsPerBlock * pool.allocPoint / totalAllocPoint;
        pool.accRewardsPerShare = pool.accRewardsPerShare + veeReward * 1e12 / lpSupply;
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for vee allocation.
    function deposit(uint _pid, uint _amount) external {

        // require (_pid != 0, 'deposit vee by staking');

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint pending = user.amount * pool.accRewardsPerShare / 1e12 - user.rewardDebt;
            if(pending > 0) {
                safeRewardsTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            IERC20(pool.lpToken).safeTransferFrom(msg.sender, address(this), _amount);
            user.amount += _amount;
            user.unlockedAmount += _amount;
        }
        user.rewardDebt = user.amount * pool.accRewardsPerShare / 1e12;
        lpTokenTotal[pool.lpToken] += _amount;
        emit Deposit(msg.sender, msg.sender, _pid, _amount);
    }

    function claimVee(address _account) external nonReentrant {
        uint pending;
        for(uint256 i = 0; i < poolInfo.length; i++){ 
            PoolInfo storage pool = poolInfo[i];
            UserInfo storage user = userInfo[i][_account];
            updatePool(i);
            if (user.amount > 0) {
                uint256 reward = user.amount * pool.accRewardsPerShare / 1e12 - user.rewardDebt;
                pending += reward;
                emit ClaimVee(_account, i, reward);
            }
            user.rewardDebt = user.amount * pool.accRewardsPerShare / 1e12;
        }
        uint256 balance = IERC20(vee).balanceOf(address(this));
        if(pending > 0 && pending <= balance) {
            safeRewardsTransfer(_account, pending);
        }
    }
    function depositBehalf(address _account, uint _pid, uint _amount) external {

        // require (_pid != 0, 'deposit vee by staking');
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_account];
        updatePool(_pid);
        if (user.amount > 0) {
            uint pending = user.amount * pool.accRewardsPerShare / 1e12 - user.rewardDebt;
            if(pending > 0) {
                safeRewardsTransfer(_account, pending);
            }
        }
        if (_amount > 0) {
            IERC20(pool.lpToken).safeTransferFrom(msg.sender, address(this), _amount);
            user.amount += _amount;
            user.lockingAmount += _amount;
        }
        user.rewardDebt = user.amount * pool.accRewardsPerShare / 1e12;
        lpTokenTotal[pool.lpToken] += _amount;
        emit Deposit(msg.sender, _account, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint _pid, uint _amount) external {

        // require (_pid != 0, 'withdraw vee by unstaking');
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "lpToken insufficient");

        updatePool(_pid);
        uint pending = user.amount * pool.accRewardsPerShare / 1e12 - user.rewardDebt;
        if(_amount > 0) {
            user.amount = user.amount - _amount;
            uint walletFirst = _amount.min(user.unlockedAmount);
            uint chargeAmount = _amount - walletFirst;
            if (walletFirst > 0) {
                user.unlockedAmount -= walletFirst;
                IERC20(pool.lpToken).safeTransfer(msg.sender, walletFirst);
            }
            user.lockingAmount -= chargeAmount;
            IERC20(pool.lpToken).safeApprove(veeHub, chargeAmount);
            IVeeHub(veeHub).depositLPToken(msg.sender, pool.lpToken, chargeAmount);
        }
        if(pending > 0) {
            safeRewardsTransfer(msg.sender, pending);
        }
        user.rewardDebt = user.amount * pool.accRewardsPerShare / 1e12;
        lpTokenTotal[pool.lpToken] -= _amount;
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint _pid) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint unlockedAmount = user.unlockedAmount;
        uint lockingAmount = user.lockingAmount;
        user.unlockedAmount = 0;
        user.lockingAmount = 0;
        lpTokenTotal[pool.lpToken] -= user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        if (unlockedAmount > 0) {
            IERC20(pool.lpToken).safeTransfer(msg.sender, unlockedAmount);
        }
        if (lockingAmount > 0) {
            IERC20(pool.lpToken).safeApprove(veeHub, lockingAmount);
            IVeeHub(veeHub).depositLPToken(msg.sender, pool.lpToken, lockingAmount);
        }
        emit EmergencyWithdraw(msg.sender, _pid, user.amount, unlockedAmount, lockingAmount);
    }

    // Safe vee transfer function, just in case if rounding error causes pool to not have enough VEEs.
    function safeRewardsTransfer(address to, uint amount) internal {
        IERC20(vee).safeApprove(veeHub, amount);
        IVeeHub(veeHub).deposit(to, amount);
    }

    function getPoolSize() external view returns(uint) {
        return poolInfo.length;
    }

    function setVeeHub(address _veeHub) external onlyOwner {
        address oldVeeHub = veeHub;
        veeHub = payable(_veeHub);
        emit NewVeeHub(veeHub, oldVeeHub);
    }

    function setRewardsPerBlock(uint _rewardsPerBlock) external onlyOwner {
        uint oldRewardsPerBlock = rewardsPerBlock;
        rewardsPerBlock = _rewardsPerBlock;
        emit NewRewardsPerBlock(rewardsPerBlock, oldRewardsPerBlock);
    }
}