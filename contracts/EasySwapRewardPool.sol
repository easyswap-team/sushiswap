// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./EasySwapMakerToken.sol";

interface IMigratorChef {
    // Perform LP token migration from legacy UniswapV2 to EasySwapRewardPool.
    // Take the current LP token address and return the new LP token address.
    // Migrator should have full access to the caller's LP token.
    // Return the new LP token address.
    //
    // XXX Migrator must have allowance access to UniswapV2 LP tokens.
    // EasySwapRewardPool must mint EXACTLY the same amount of EasySwapRewardPool LP tokens or
    // else something bad will happen. Traditional UniswapV2 does not
    // do that so be careful!
    function migrate(IERC20 token) external returns (IERC20);
}

// EasySwapRewardPool is the master of Esm. He can make Esm and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once ESM is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract EasySwapRewardPool is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of ESMs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accEsmPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accEsmPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }
    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. ESMs to distribute per block.
        uint256 lastRewardBlock; // Last block number that ESMs distribution occurs.
        uint256 accEsmPerShare; // Accumulated ESMs per share, times 1e12. See below.
    }
    // Info of each multiplier stage.
    struct Stage {
        uint256 endBlock;
        uint256 esmPerBlock;
        uint256 esgPerBlock;
    }
    // EasySwap MarketMaker token
    EasySwapMakerToken public esm;
    // EasySwap Governance Token
    IERC20 public esg;
    // Dev address.
    address public devaddr;
    // Block number when bonus ESM period ends.
    uint256 public bonusEndBlock;
    // ESM tokens created per block.
    uint256 public esmPerBlock;
    // The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorChef public migrator;
    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when ESM mining starts.
    uint256 public startBlock;
    // Array of stages
    Stage[] public stages;
    //
    event StageAdded(uint256 endBlock, uint256 esmPerBlock, uint256 esgPerBlock);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );

    constructor(
        EasySwapMakerToken _esm,
        IERC20 _esg,
        address _devaddr,
        uint256 _startBlock
    ) public {
        esm = _esm;
        esg = _esg;
        devaddr = _devaddr;
        startBlock = _startBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock =
            _getCurrentBlock() > startBlock ? _getCurrentBlock() : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accEsmPerShare: 0
            })
        );
    }

    // Update the given pool's ESM allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Set the migrator contract. Can only be called by the owner.
    function setMigrator(IMigratorChef _migrator) public onlyOwner {
        migrator = _migrator;
    }

    // Migrate lp token to another lp contract. Can be called by anyone. We trust that migrator contract is good.
    function migrate(uint256 _pid) public {
        require(address(migrator) != address(0), "migrate: no migrator");
        PoolInfo storage pool = poolInfo[_pid];
        IERC20 lpToken = pool.lpToken;
        uint256 bal = lpToken.balanceOf(address(this));
        lpToken.safeApprove(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "migrate: bad");
        pool.lpToken = newLpToken;
    }

    // Add new stage with its own multiplier.
    function addStage(uint256 _endBlock, uint256 _esmPerBlock, uint256 _esgPerBlock) public onlyOwner {
        require(_endBlock > startBlock, "addStage: new endBlock less than startBlock");
        if (stages.length > 0) {
            Stage memory lastStage = stages[stages.length.sub(1)];
            require(_endBlock > lastStage.endBlock, "addStage: new endBlock less than previous");
        }

        stages.push(Stage(_endBlock, _esmPerBlock, _esgPerBlock));
        emit StageAdded(_endBlock, _esmPerBlock, _esgPerBlock);
    }

    // Return total ESM & ESG over the given _from to _to block.
    function getTotalEsxRewards(uint256 _from, uint256 _to)
        public
        view
        returns (uint256 esmReward, uint256 esgReward)
    {
        assert(_from <= _to);

        uint256 stagesLength = stages.length;
        if (stagesLength == 0)
            return (0, 0);

        if (_to <= startBlock)
            return (0, 0);

        esmReward = 0;
        esgReward = 0;

        uint256 tmp_from = _from > startBlock ? _from : startBlock;
        uint256 tmp_to;

        Stage memory stage;

        for (uint256 i = 0; i < stagesLength; i++) {
            stage = stages[i];
            if (tmp_from > stage.endBlock)
                continue;
            tmp_to = stage.endBlock < _to ? stage.endBlock : _to;
            esmReward = esmReward.add(tmp_to.sub(tmp_from).mul(stage.esmPerBlock));
            esgReward = esgReward.add(tmp_to.sub(tmp_from).mul(stage.esgPerBlock));
            if (tmp_to == _to)
                break;
            tmp_from = tmp_to;
        }

        return (esmReward, esgReward);
    }

    // View function to see pending ESMs on frontend.
    function pendingEsm(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accEsmPerShare = pool.accEsmPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (_getCurrentBlock() > pool.lastRewardBlock && lpSupply != 0) {
            (uint256 esmTotalReward,) = getTotalEsxRewards(pool.lastRewardBlock, _getCurrentBlock());
            uint256 esmReward = esmTotalReward.mul(pool.allocPoint).div(totalAllocPoint);
            accEsmPerShare = accEsmPerShare.add(esmReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accEsmPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (_getCurrentBlock() <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = _getCurrentBlock();
            return;
        }
        (uint256 totalEsmReward, uint256 totalEsgReward) =
            getTotalEsxRewards(pool.lastRewardBlock, _getCurrentBlock());
        uint256 esmReward = totalEsmReward.mul(pool.allocPoint).div(totalAllocPoint);
        uint256 esgReward = totalEsgReward.mul(pool.allocPoint).div(totalAllocPoint);

        // todo use setter for fee
        esm.mint(devaddr, esmReward.div(10));
        esm.mint(devaddr, esmReward.mul(9).div(10));
        // todo esg.transfer(address(this), esmReward);
        // todo check this logic
        pool.accEsmPerShare = pool.accEsmPerShare.add(
            esmReward.mul(1e12).div(lpSupply)
        );
        pool.lastRewardBlock = _getCurrentBlock();
    }

    // Deposit LP tokens to EasySwapRewardPool for ESM allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending =
                user.amount.mul(pool.accEsmPerShare).div(1e12).sub(
                    user.rewardDebt
                );
            safeEsmTransfer(msg.sender, pending);
        }
        pool.lpToken.safeTransferFrom(
            address(msg.sender),
            address(this),
            _amount
        );
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accEsmPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from EasySwapRewardPool.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending =
            user.amount.mul(pool.accEsmPerShare).div(1e12).sub(
                user.rewardDebt
            );
        safeEsmTransfer(msg.sender, pending);
        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accEsmPerShare).div(1e12);
        pool.lpToken.safeTransfer(address(msg.sender), _amount);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Returns block.number, overridable for test purposes.
    function _getCurrentBlock() virtual internal view returns (uint256) {
        return block.number;
    }

    // Safe esm transfer function, just in case if rounding error causes pool to not have enough ESMs.
    function safeEsmTransfer(address _to, uint256 _amount) internal {
        uint256 esmBal = esm.balanceOf(address(this));
        if (_amount > esmBal) {
            esm.transfer(_to, esmBal);
        } else {
            esm.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }
}
