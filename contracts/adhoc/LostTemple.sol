// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../library/TransferHelper.sol";
contract LostTemple is Initializable, OwnableUpgradeable{
    address constant AVAX = address(1);
    struct UserBalance {
        mapping(address => uint256) totalBalance;
        mapping(address => uint256) claimedBalance;

    }
    mapping(address => uint256) public depositAmount;
    mapping(address => uint256) public sumBalance;
    mapping(address => UserBalance) private userBalances;

    event Deposit(address token, uint amount, uint totalAmount);
    event Withdraw(address token, uint amount, uint totalAmount);
    event DistributeToken(address token, uint amount);

    function initialize() public initializer {
        __Ownable_init();
    }

    function addApproval(address token, address[] memory accounts, uint[] memory balances) external onlyOwner {
        require(accounts.length == balances.length, "data length not match");
        uint dataLength = accounts.length;
        for(uint i = 0; i < dataLength; i++) {
            UserBalance storage userBalance = userBalances[accounts[i]];
            userBalance.totalBalance[token] += balances[i];
            sumBalance[token] += balances[i];
        }
    }

    function deposit(address token, uint amount) external onlyOwner {
        TransferHelper.safeTransferFrom(token, msg.sender, address(this), amount);
        depositAmount[token] += amount;
        emit Deposit(token, amount, depositAmount[token]);
    }

    function depositAVAX() external payable onlyOwner {
        depositAmount[AVAX] += msg.value;
        emit Deposit(AVAX, msg.value, depositAmount[AVAX]);
    }

    function withdraw(address token, uint amount) external onlyOwner {
        depositAmount[token] -= amount;
        if (token == AVAX) {
            TransferHelper.safeTransferAVAX(payable(msg.sender), amount);
        } else {
            TransferHelper.safeTransfer(token, msg.sender, amount);
        }
        emit Withdraw(token, amount, depositAmount[token]);
    }

    function estimateClaimable(address account, address token) external view returns(uint, uint) {
        UserBalance storage userBalance = userBalances[account];
        uint balance = userBalance.totalBalance[token];
        uint totalClaimable = _min(depositAmount[token] * balance / sumBalance[token], balance);
        if (totalClaimable < userBalance.claimedBalance[token]) {
            return (0, userBalance.claimedBalance[token] - totalClaimable);
        }
        uint remainingClaimable = totalClaimable - userBalance.claimedBalance[token];
        return (remainingClaimable, 0);
    }

    function claimTokens(address[] memory tokens) external {
        uint dataLength = tokens.length;
        for(uint i = 0; i < dataLength; i++) {
            _claimTokens(msg.sender, tokens[i]);
        }

    }

    function _claimTokens(address account, address token) internal {
        UserBalance storage userBalance = userBalances[account];
        uint balance = userBalance.totalBalance[token];
        uint totalClaimable = _min(depositAmount[token] * balance / sumBalance[token], balance);
        require(totalClaimable >= userBalance.claimedBalance[token], "over limited");
        uint remainingClaimable = totalClaimable - userBalance.claimedBalance[token];
        userBalance.claimedBalance[token] = totalClaimable;
        if (remainingClaimable > 0) {
            TransferHelper.safeTransfer(token, account, remainingClaimable);
        }
        emit DistributeToken(token, remainingClaimable);
    }

    function getUserBalance(address account, address token) external view returns(uint, uint) {
        uint totalBalance = userBalances[account].totalBalance[token];
        uint claimedBalance = userBalances[account].claimedBalance[token];
        return (totalBalance, claimedBalance);
    }

    function _min(uint a, uint b) internal pure returns (uint) {
        return a < b ? a : b;
    }
}