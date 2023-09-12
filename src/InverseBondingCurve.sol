// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "openzeppelin/token/ERC20/IERC20.sol";
import "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "oz-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "oz-upgradeable/security/PausableUpgradeable.sol";
import "oz-upgradeable/access/OwnableUpgradeable.sol";
import "oz-upgradeable/proxy/utils/Initializable.sol";
import "oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./interface/IInverseBondingCurve.sol";
import "./interface/IInverseBondingCurveToken.sol";
import "./lib/balancer/FixedPoint.sol";
import "./Constants.sol";
import "./Errors.sol";
import "./CurveParameter.sol";
import "./FeeState.sol";
import "./Enums.sol";

//TODO: add logic for transfer owner: we need to change owner of inversetoken contract
contract InverseBondingCurve is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ERC20Upgradeable,
    IInverseBondingCurve
{
    using FixedPoint for uint256;
    using SafeERC20 for IERC20;
    /// ERRORS ///

    /// EVENTS ///
    event CurveInitialized(
        address indexed from,
        uint256 virtualReserve,
        uint256 virtualSupply,
        uint256 initialPrice,
        uint256 parameterUtilization,
        uint256 parameterInvariant
    );
    event LiquidityAdded(
        address indexed from,
        address indexed recipient,
        uint256 amountIn,
        uint256 amountOut,
        uint256 newParameterUtilization,
        uint256 newParameterInvariant
    );
    event LiquidityRemoved(
        address indexed from,
        address indexed recipient,
        uint256 amountIn,
        uint256 amountOut,
        uint256 newParameterUtilization,
        uint256 newParameterInvariant
    );

    event LiquidityStaked(address indexed from, uint256 amount);
    event LiquidityUnstaked(address indexed from, uint256 amount);

    event TokenBought(address indexed from, address indexed recipient, uint256 amountIn, uint256 amountOut);

    event TokenSold(address indexed from, address indexed recipient, uint256 amountIn, uint256 amountOut);

    event RewardClaimed(
        address indexed from, address indexed recipient, uint256 inverseTokenAmount, uint256 reserveAmount
    );

    event FeeConfigChanged(ActionType actionType, uint256 lpFee, uint256 stakingFee, uint256 protocolFee);

    event FeeOwnerChanged(address feeOwner);

    /// STATE VARIABLES ///
    address private _protocolFeeOwner;
    //TODO: there will be tiny errors accumulated and some balance left after user claim reward,
    // need to handle this properly to protocol
    uint256 private _protocolFee;
    uint256 private _totalStaked;

    uint256 private _parameterInvariant;
    uint256 private _parameterUtilization;
    uint256 private _globalLpFeeIndex;
    uint256 private _globalStakingFeeIndex;

    // swap fee percent = _lpFeePercent + _stakingFeePercent + _protocolFeePercent
    uint256[MAX_ACTION_COUNT] private _lpFeePercent;
    uint256[MAX_ACTION_COUNT] private _stakingFeePercent;
    uint256[MAX_ACTION_COUNT] private _protocolFeePercent;

    IInverseBondingCurveToken private _inverseToken;
    mapping(address => uint256) private _userLpFeeIndexState;
    mapping(address => uint256) private _userLpPendingReward;
    mapping(address => uint256) private _userStakingFeeIndexState;
    mapping(address => uint256) private _userStakingPendingReward;

    mapping(address => uint256) private _stakingBalance;

    // Used for curve calculation
    uint256 private _reserveBalance;
    // To capture fee in reserve, if contract reserve balance > _reserveBalance + _reserveFeeBalance, then it will be distributed to protocol
    uint256 private _reserveFeeBalance;
    // The initial virtual reserve and supply
    uint256 private _virtualReserveBalance;
    uint256 private _virtualSupply;

    FeeState[MAX_FEE_TYPE_COUNT] private _feeState;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        uint256 virtualReserve,
        uint256 supply,
        uint256 price,
        address inverseTokenContractAddress,
        address protocolFeeOwner
    ) external initializer {
        require(virtualReserve > 0 && supply > 0 && price > 0, ERR_PARAM_ZERO);
        require(inverseTokenContractAddress != address(0), ERR_EMPTY_ADDRESS);
        require(protocolFeeOwner != address(0), ERR_EMPTY_ADDRESS);

        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();
        __ERC20_init("IBCLP", "IBCLP");

        for (uint8 i = 0; i < MAX_ACTION_COUNT; i++) {
            _lpFeePercent[i] = FEE_PERCENT;
            _stakingFeePercent[i] = FEE_PERCENT;
            _protocolFeePercent[i] = FEE_PERCENT;
        }

        _inverseToken = IInverseBondingCurveToken(inverseTokenContractAddress);
        _protocolFeeOwner = protocolFeeOwner;
        _virtualReserveBalance = virtualReserve;
        _virtualSupply = supply;
        _reserveBalance = virtualReserve;

        _parameterUtilization = price.mulDown(supply).divDown(_reserveBalance);
        require(_parameterUtilization < ONE_UINT, ERR_PARAM_ZERO);
        _parameterInvariant = _reserveBalance.divDown(supply.powDown(_parameterUtilization));

        _updateLpReward(msg.sender);

        emit FeeOwnerChanged(protocolFeeOwner);
        emit CurveInitialized(msg.sender, virtualReserve, supply, price, _parameterUtilization, _parameterInvariant);
    }

    function updateFeeConfig(ActionType actionType, uint256 lpFee, uint256 stakingFee, uint256 protocolFee)
        external
        onlyOwner
    {
        require((lpFee + stakingFee + protocolFee) < MAX_FEE_PERCENT, ERR_FEE_PERCENT_OUT_OF_RANGE);
        _lpFeePercent[uint256(actionType)] = lpFee;
        _stakingFeePercent[uint256(actionType)] = stakingFee;
        _protocolFeePercent[uint256(actionType)] = protocolFee;

        emit FeeConfigChanged(actionType, lpFee, stakingFee, protocolFee);
    }

    function updateFeeOwner(address protocolFeeOwner) public onlyOwner {
        require(protocolFeeOwner != address(0), ERR_EMPTY_ADDRESS);
        _protocolFeeOwner = protocolFeeOwner;

        emit FeeOwnerChanged(protocolFeeOwner);
    }

    function pause() external onlyOwner {
        _pause();
        _inverseToken.pause();
    }

    function unpause() external onlyOwner {
        _unpause();
        _inverseToken.unpause();
    }

    function addLiquidity(address recipient, uint256 minPriceLimit) external payable whenNotPaused {
        require(msg.value > MIN_LIQUIDITY, ERR_LIQUIDITY_TOO_SMALL);
        require(recipient != address(0), ERR_EMPTY_ADDRESS);

        uint256 currentIbcSupply = _virtualInverseTokenTotalSupply();

        uint256 fee = _calculateAndUpdateFee(msg.value, ActionType.ADD_LIQUIDITY);
        _reserveFeeBalance += fee;

        uint256 reserveAdded = msg.value - fee;
        uint256 newBalance = _reserveBalance + reserveAdded;
        uint256 mintToken = _virtualTotalSupply().mulDown(reserveAdded).divDown(
            ONE_UINT.sub(_parameterUtilization).mulDown(_reserveBalance)
        );

        _updateLpReward(recipient);
        _mint(recipient, mintToken);

        _parameterUtilization = _reserveBalance.mulDown(_parameterUtilization).divDown(newBalance);
        require(_parameterUtilization < ONE_UINT, ERR_PARAM_ZERO);
        _parameterInvariant = newBalance.divDown(currentIbcSupply.powDown(_parameterUtilization));
        _reserveBalance = newBalance;

        uint256 currentPrice = priceOf(currentIbcSupply);
        require(currentPrice >= minPriceLimit, ERR_PRICE_OUT_OF_LIMIT);

        emit LiquidityAdded(msg.sender, recipient, msg.value, mintToken, _parameterUtilization, _parameterInvariant);
    }

    function removeLiquidity(address recipient, uint256 amount, uint256 maxPriceLimit) external whenNotPaused {
        require(balanceOf(msg.sender) >= amount, ERR_INSUFFICIENT_BALANCE);
        require(recipient != address(0), ERR_EMPTY_ADDRESS);

        uint256 currentIbcSupply = _virtualInverseTokenTotalSupply();

        uint256 reserveRemoved =
            _reserveBalance.mulDown(ONE_UINT.sub(_parameterUtilization)).mulDown(amount).divDown(_virtualTotalSupply());
        if (reserveRemoved > _reserveBalance - _virtualReserveBalance) {
            reserveRemoved = _reserveBalance - _virtualReserveBalance;
        }
        uint256 fee = _calculateAndUpdateFee(reserveRemoved, ActionType.REMOVE_LIQUIDITY);
        _reserveFeeBalance += fee;
        uint256 reserveToUser = reserveRemoved - fee;

        uint256 newBalance = _reserveBalance - reserveRemoved;
        _parameterUtilization = _reserveBalance.mulDown(_parameterUtilization).divDown(newBalance);
        _parameterInvariant = newBalance.divDown(currentIbcSupply.powDown(_parameterUtilization));
        _reserveBalance = newBalance;
        uint256 currentPrice = priceOf(currentIbcSupply);
        require(currentPrice <= maxPriceLimit, ERR_PRICE_OUT_OF_LIMIT);

        _updateLpReward(msg.sender);
        _burn(msg.sender, amount);

        emit LiquidityRemoved(msg.sender, recipient, amount, reserveToUser, _parameterUtilization, _parameterInvariant);

        (bool sent,) = recipient.call{value: reserveToUser}("");
        require(sent, ERR_FAIL_SEND_ETHER);        
    }

    function _calculateAndUpdateFee(uint256 amount, ActionType action) private returns (uint256 totalFee) {
        uint256 lpFee = amount.mulDown(_lpFeePercent[uint256(action)]);
        uint256 stakingFee = amount.mulDown(_stakingFeePercent[uint256(action)]);
        uint256 protocolFee = amount.mulDown(_protocolFeePercent[uint256(action)]);

        FeeState storage state = (action == ActionType.BUY_TOKEN || action == ActionType.SELL_TOKEN)
            ? _feeState[uint256(FeeType.INVERSE_TOKEN)]
            : _feeState[uint256(FeeType.RESERVE)];

        if (totalSupply() > 0) {
            state.globalLpFeeIndex += lpFee.divDown(totalSupply());
        } else {
            state.protocolFee += lpFee;
        }

        if (_totalStaked > 0) {
            state.globalStakingFeeIndex += stakingFee.divDown(_totalStaked);
        } else {
            state.feeForFirstStaker = stakingFee;
        }

        state.protocolFee += protocolFee;

        return lpFee + stakingFee + protocolFee;
    }

    function buyTokens(address recipient, uint256 maxPriceLimit) external payable whenNotPaused {
        require(recipient != address(0), ERR_EMPTY_ADDRESS);
        require(msg.value > MIN_LIQUIDITY, ERR_LIQUIDITY_TOO_SMALL);

        uint256 newToken = _calcMintToken(msg.value);

        uint256 fee = _calculateAndUpdateFee(newToken, ActionType.BUY_TOKEN);
        uint256 mintToken = newToken.sub(fee);
        _reserveBalance += msg.value;
        require(msg.value.divDown(mintToken) <= maxPriceLimit, ERR_PRICE_OUT_OF_LIMIT);
        require(
            _isInvariantChanged(_reserveBalance, _virtualInverseTokenTotalSupply() + newToken), ERR_INVARIANT_CHANGED
        );

        _inverseToken.mint(recipient, mintToken);
        _inverseToken.mint(address(this), fee);

        emit TokenBought(msg.sender, recipient, msg.value, mintToken);
    }

    function sellTokens(address recipient, uint256 amount, uint256 minPriceLimit) external whenNotPaused {
        require(_inverseToken.balanceOf(msg.sender) >= amount, ERR_INSUFFICIENT_BALANCE);
        // require(amount >= MIN_SUPPLY, ERR_LIQUIDITY_TOO_SMALL);
        require(recipient != address(0), ERR_EMPTY_ADDRESS);

        uint256 fee = _calculateAndUpdateFee(amount, ActionType.SELL_TOKEN);
        uint256 burnToken = amount.sub(fee);

        uint256 returnLiquidity = _calcBurnToken(burnToken);
        // require(returnLiquidity <= _reserveBalance - _virtualReserveBalance, ERR_INSUFFICIENT_BALANCE);
        if (returnLiquidity > _reserveBalance - _virtualReserveBalance) {
            returnLiquidity = _reserveBalance - _virtualReserveBalance;
        }
        _reserveBalance -= returnLiquidity;

        require(returnLiquidity.divDown(burnToken) >= minPriceLimit, ERR_PRICE_OUT_OF_LIMIT);
        require(
            _isInvariantChanged(_reserveBalance, _virtualInverseTokenTotalSupply() - burnToken), ERR_INVARIANT_CHANGED
        );

        _inverseToken.burnFrom(msg.sender, burnToken);
        IERC20(_inverseToken).safeTransferFrom(msg.sender, address(this), fee);

        emit TokenSold(msg.sender, recipient, amount, returnLiquidity);

        (bool sent,) = recipient.call{value: returnLiquidity}("");
        require(sent, ERR_FAIL_SEND_ETHER);        
    }

    function stake(uint256 amount) external whenNotPaused {
        require(amount > MIN_SUPPLY, ERR_LIQUIDITY_TOO_SMALL);
        require(_inverseToken.balanceOf(msg.sender) >= amount, ERR_INSUFFICIENT_BALANCE);

        _updateStakingReward(msg.sender);

        _rewardFirstStaker();
        _stakingBalance[msg.sender] += amount;
        _totalStaked += amount;
        IERC20(_inverseToken).safeTransferFrom(msg.sender, address(this), amount);

        emit LiquidityStaked(msg.sender, amount);
    }

    function unstake(uint256 amount) external whenNotPaused {
        require(_stakingBalance[msg.sender] >= amount && _totalStaked >= amount, ERR_INSUFFICIENT_BALANCE);

        _updateStakingReward(msg.sender);
        _stakingBalance[msg.sender] -= amount;
        _totalStaked -= amount;
        IERC20(_inverseToken).safeTransfer(msg.sender, amount);

        emit LiquidityUnstaked(msg.sender, amount);
    }

    function claimReward(address recipient) external whenNotPaused {
        require(recipient != address(0), ERR_EMPTY_ADDRESS);

        _updateLpReward(msg.sender);
        _updateStakingReward(msg.sender);

        uint256 inverseTokenReward = _claimReward(_feeState[uint256(FeeType.INVERSE_TOKEN)]);

        uint256 reserveReward = _claimReward(_feeState[uint256(FeeType.RESERVE)]);

        if (inverseTokenReward > 0) {
            uint256 maxReward = _inverseToken.balanceOf(address(this)).sub(
                _feeState[uint256(FeeType.INVERSE_TOKEN)].protocolFee.add(
                    _feeState[uint256(FeeType.INVERSE_TOKEN)].feeForFirstStaker
                )
            );
            if (inverseTokenReward > maxReward) {
                inverseTokenReward = maxReward;
            }
            IERC20(_inverseToken).safeTransfer(recipient, inverseTokenReward);
        }

        emit RewardClaimed(msg.sender, recipient, inverseTokenReward, reserveReward);
        if (reserveReward > 0) {
            uint256 maxReward = address(this).balance.sub(
                _feeState[uint256(FeeType.RESERVE)].protocolFee.add(
                    _feeState[uint256(FeeType.RESERVE)].feeForFirstStaker
                )
            );
            if (reserveReward > maxReward) {
                reserveReward = maxReward;
            }
            (bool sent,) = recipient.call{value: reserveReward}("");
            require(sent, ERR_FAIL_SEND_ETHER);
        }        
    }

    function claimProtocolReward() external whenNotPaused {
        require(msg.sender == _protocolFeeOwner, ERR_ONLY_OWNER_ALLOWED);

        uint256 inverseTokenReward = _feeState[uint256(FeeType.INVERSE_TOKEN)].protocolFee;
        uint256 reserveReward = _feeState[uint256(FeeType.RESERVE)].protocolFee;

        _feeState[uint256(FeeType.INVERSE_TOKEN)].protocolFee = 0;
        _feeState[uint256(FeeType.RESERVE)].protocolFee = 0;

        if (inverseTokenReward > 0) {
            IERC20(_inverseToken).safeTransfer(_protocolFeeOwner, inverseTokenReward);
        }

        // TODO: Check whether any additional balance left on
        // if (reserveReward < address(this).balance - _reserveBalance) {
        //     reserveReward = address(this).balance - _reserveBalance;
        // }

        emit RewardClaimed(msg.sender, _protocolFeeOwner, inverseTokenReward, reserveReward);
        if (reserveReward > 0) {
            (bool sent,) = _protocolFeeOwner.call{value: reserveReward}("");
            require(sent, ERR_FAIL_SEND_ETHER);
        }
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        // update the sender/recipient rewards state before balances change
        _updateLpReward(msg.sender);
        _updateLpReward(recipient);

        return (super.transfer(recipient, amount));
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        // update the sender/recipient rewards state before balances change
        _updateLpReward(from);
        _updateLpReward(to);

        return (super.transferFrom(from, to, amount));
    }

    function priceOf(uint256 supply) public view returns (uint256) {
        return _parameterInvariant.mulDown(_parameterUtilization).divDown(
            supply.powDown(ONE_UINT.sub(_parameterUtilization))
        );
    }

    function _rewardFirstStaker() private {
        if (_totalStaked == 0) {
            FeeState storage state = _feeState[uint256(FeeType.INVERSE_TOKEN)];
            if (state.feeForFirstStaker > 0) {
                state.userStakingPendingReward[msg.sender] = state.feeForFirstStaker;
                state.feeForFirstStaker = 0;
            }

            state = _feeState[uint256(FeeType.RESERVE)];
            if (state.feeForFirstStaker > 0) {
                state.userStakingPendingReward[msg.sender] = state.feeForFirstStaker;
                state.feeForFirstStaker = 0;
            }
        }
    }

    function _calcMintToken(uint256 amount) private view returns (uint256) {
        uint256 newBalance = _reserveBalance + amount;
        uint256 currentSupply = _virtualInverseTokenTotalSupply();

        return newBalance.divDown(_reserveBalance).powDown(ONE_UINT.divDown(_parameterUtilization)).mulDown(
            currentSupply
        ) - currentSupply;
    }

    function _calcBurnToken(uint256 amount) private view returns (uint256) {
        uint256 currentSupply = _virtualInverseTokenTotalSupply();

        // TODO: feels we need to use divUp, powDown, mulUp,
        return _reserveBalance.sub(
            (currentSupply.sub(amount).divDown(currentSupply)).powDown(_parameterUtilization).mulDown(_reserveBalance)
        );
    }

    function inverseTokenAddress() external view returns (address) {
        return address(_inverseToken);
    }

    function curveParameters() external view returns (CurveParameter memory parameters) {
        uint256 supply = _virtualInverseTokenTotalSupply();
        return CurveParameter(
            _reserveBalance,
            supply,
            _virtualReserveBalance,
            _virtualSupply,
            priceOf(supply),
            _parameterInvariant,
            _parameterUtilization
        );
    }

    function feeConfig()
        external
        view
        returns (
            uint256[MAX_ACTION_COUNT] memory lpFee,
            uint256[MAX_ACTION_COUNT] memory stakingFee,
            uint256[MAX_ACTION_COUNT] memory protocolFee
        )
    {
        return (_lpFeePercent, _stakingFeePercent, _protocolFeePercent);
    }

    function feeOwner() external view returns (address) {
        return _protocolFeeOwner;
    }

    function rewardOf(address recipient)
        external
        view
        returns (
            uint256 inverseTokenForLp,
            uint256 inverseTokenForStaking,
            uint256 reserveForLp,
            uint256 reserveForStaking
        )
    {
        inverseTokenForLp = _calculatePendingReward(recipient, _feeState[uint256(FeeType.INVERSE_TOKEN)], RewardType.LP);
        inverseTokenForStaking =
            _calculatePendingReward(recipient, _feeState[uint256(FeeType.INVERSE_TOKEN)], RewardType.STAKING);
        reserveForLp = _calculatePendingReward(recipient, _feeState[uint256(FeeType.RESERVE)], RewardType.LP);
        reserveForStaking = _calculatePendingReward(recipient, _feeState[uint256(FeeType.RESERVE)], RewardType.STAKING);
    }

    function _calculatePendingReward(address recipient, FeeState storage state, RewardType rewardType)
        internal
        view
        returns (uint256)
    {
        uint256 reward = 0;
        if (rewardType == RewardType.LP) {
            uint256 userLpBalance = balanceOf(recipient);
            reward += state.userLpPendingReward[recipient];
            if (userLpBalance > 0) {
                reward += state.globalLpFeeIndex.sub(state.userLpFeeIndexState[recipient]).mulDown(userLpBalance);
            }
        } else if (rewardType == RewardType.STAKING) {
            uint256 userStakingBalance = _stakingBalance[recipient];
            reward += state.userStakingPendingReward[recipient];
            if (userStakingBalance > 0) {
                reward += state.globalStakingFeeIndex.sub(state.userStakingFeeIndexState[recipient]).mulDown(
                    userStakingBalance
                );
            }
        }
        return reward;
    }

    function stakingBalanceOf(address holder) external view returns (uint256) {
        return _stakingBalance[holder];
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    function _isInvariantChanged(uint256 newLiquidity, uint256 newSupply) internal view returns (bool) {
        uint256 invariant = newLiquidity.divDown(newSupply.powDown(_parameterUtilization));

        return (invariant > _parameterInvariant - ALLOWED_INVARIANT_CHANGE)
            && (invariant < _parameterInvariant + ALLOWED_INVARIANT_CHANGE);
    }

    function _claimReward(FeeState storage state) private returns (uint256) {
        uint256 reward = state.userLpPendingReward[msg.sender] + state.userStakingPendingReward[msg.sender];
        state.userLpPendingReward[msg.sender] = 0;
        state.userStakingPendingReward[msg.sender] = 0;
        return reward;
    }

    function _updateLpReward(address user) private {
        _updateLpReward(user, _feeState[uint256(FeeType.RESERVE)]);
        _updateLpReward(user, _feeState[uint256(FeeType.INVERSE_TOKEN)]);
    }

    function _updateLpReward(address user, FeeState storage state) private {
        uint256 userLpBalance = balanceOf(user);
        if (userLpBalance > 0) {
            uint256 reward = state.globalLpFeeIndex.sub(state.userLpFeeIndexState[user]).mulDown(userLpBalance);
            state.userLpPendingReward[user] += reward;
            state.userLpFeeIndexState[user] = state.globalLpFeeIndex;
        } else {
            state.userLpFeeIndexState[user] = state.globalLpFeeIndex;
        }
    }

    function _updateStakingReward(address user) private {
        _updateStakingReward(user, _feeState[uint256(FeeType.RESERVE)]);
        _updateStakingReward(user, _feeState[uint256(FeeType.INVERSE_TOKEN)]);
    }

    function _updateStakingReward(address user, FeeState storage state) private {
        uint256 userStakingBalance = _stakingBalance[user];
        if (userStakingBalance > 0) {
            uint256 reward =
                state.globalStakingFeeIndex.sub(state.userStakingFeeIndexState[user]).mulDown(userStakingBalance);
            state.userStakingPendingReward[user] += reward;
            state.userStakingFeeIndexState[user] = state.globalStakingFeeIndex;
        } else {
            state.userStakingPendingReward[user] = 0;
            state.userStakingFeeIndexState[user] = state.globalStakingFeeIndex;
        }
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override whenNotPaused {
        super._beforeTokenTransfer(from, to, amount);
    }

    function _virtualTotalSupply() private view returns (uint256) {
        return totalSupply() + _virtualReserveBalance;
    }

    function _virtualReserve() private view returns (uint256) {
        return _reserveBalance;
    }

    function _virtualInverseTokenTotalSupply() private view returns (uint256) {
        return _inverseToken.totalSupply() + _virtualSupply;
    }

    // =============================!!! Do not remove below method !!!=============================
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    // ============================================================================================
}
