//SPDX-License-Identifier:MIT
pragma solidity ^0.8.4;


import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./SushiToken.sol";

import "./interface.sol";


interface IMigratorChef {
    function migrate(IERC20 token) external returns(IERC20);
}



contract MasterChef is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    //每个用户的信息
    struct UserInfo {
        uint256 amount; //用户提供了多少LP代币（这里用MyToken代替）
        uint256 rewardDebt; //奖励债权

        //例如，在任何时间点，用户有权分发但待分发的sushi的数量为：
        //pending reward = (user.amount * pool.accSushiPerShare) - user.rewardDebt

        //每当用户将LP代币存入或提取到池中时。以下时发生的情况：
        //1、 池中的accSushiPerShare(和LastRewardBlock)会更新
        //2、 用户收到发送到他的地址的待处理奖励
        //3、 用户的amount会更新
        //4、 用户的reward得到更新
    }
   
    //每个池子的信息
    struct PoolInfo{
        IERC20 lpToken; //LP代币的合约地址
        uint256 allocPoint; //分配给此池子的分配点数。每个区块分发的sushi
        uint256 lastRewardBlock; //sushi分发发生的最后一个区块号
        uint256 accSushiPerShare; //每股累计的sushi乘上 1e12
    }
    
    //sushi代币
    SushiToken public sushi;
    //开发地址
    address public devaddr;
    //奖励sushi结束时的区块编号
    uint256 public bonusEndBlock;
    //每个区块创建的sushi代币
    uint256 public sushiPerBlock;
    //早期sushi制造商的奖金
    uint256 public constant BOUNS_MULTIPLIER = 10;
    //每个池子的信息
    PoolInfo[] public poolInfo;
    //质押LP代币的每个用户的信息
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    //总分配点数，必须是所有池中所有分配点的总和
    uint256 public totalAllocPoint = 0;
    //sushi挖矿开始时的区块号
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint indexed pid, uint256 amount);

    constructor(SushiToken _sushi)public{
        sushi = _sushi;
    }

    //添加质押物， 添加一个质押池，一个质押池100个分配点位
    function add(IERC20 _lpToken) public {
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(100);
        poolInfo.push(
            PoolInfo({
                lpToken:_lpToken,
                //这个质押池的分配点位
                allocPoint: 100,
                //上一个更新奖励的区块
                lastRewardBlock: lastRewardBlock,
                //质押一个lp token的全局收益
                //用户在质押Lp token的时候，会把当前accsushipershare记下来作为起始点位，
                //当解除质押的时候，可以通过最新的accSushipershare减去起始点位，就可以得到用户实际的收益
                accSushiPerShare: 0
            })
        );
    }

    //将给定_from的奖励乘数返回给_to块
    function getMultiplier(uint256 _from ,uint _to) public view returns(uint256){
        if(_to <= bonusEndBlock){
            return _to.sub(_from).mul(BOUNS_MULTIPLIER);
        }else if(_from >= bonusEndBlock){
            return _to.sub(_from);
        }else{
            return bonusEndBlock.sub(_from).mul(BOUNS_MULTIPLIER).add(
                _to.sub(bonusEndBlock)
            );
        }
    }

    //将给定池的奖励变量更新为最新
    function updatePool(uint256 _pid) public {
         PoolInfo storage pool = poolInfo[_pid];
         if(block.number <= pool.lastRewardBlock){
             return;
         }
         uint256 lpSupply = pool.lpToken.balanceOf(address(this));
         if(lpSupply == 0){
             pool.lastRewardBlock = block.number;
             return;
         }
         uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
         uint256 sushiReward = multiplier.mul(sushiPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
         sushi.mint(devaddr,sushiReward.div(10));
         sushi.mint(address(this),sushiReward);
         pool.accSushiPerShare = pool.accSushiPerShare.add(sushiReward.mul(1e12).div(lpSupply));
         pool.lastRewardBlock = block.number;
    } 

    //将LP代币存入MasterChef以进行sushi的分配
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        //追加质押，先结算之前的奖励
        if(user.amount > 0){
            uint256 pending = user.amount.mul(pool.accSushiPerShare).div(1e12).sub(user.rewardDebt);
            sushi.transfer(msg.sender, pending);
        }
        //把用户的lp。token转移到MasterChef合约中
        pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        user.amount = user.amount.add(_amount);
        //更新不可领取的部分
        user.rewardDebt = user.amount.mul(pool.accSushiPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    //从MasterChef提取LP代币
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount,"withdraw: not good");
        uint256 pending = user.amount.mul(pool.accSushiPerShare).div(1e12).sub(user.rewardDebt);
        sushi.transfer(msg.sender,pending);
        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accSushiPerShare).div(1e12);
        pool.lpToken.safeTransfer(address(msg.sender), _amount);
        emit Withdraw(msg.sender, _pid, _amount);
    } 
}

