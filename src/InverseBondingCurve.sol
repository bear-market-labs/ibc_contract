// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "openzeppelin/token/ERC20/IERC20.sol";
import "openzeppelin/token/ERC20/utils/SafeERC20.sol";
// import "oz-upgradeable/token/ERC20/ERC20Upgradeable.sol";
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
import "./LpPosition.sol";

import "./lib/CurveLibrary.sol";

contract InverseBondingCurve is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    // ERC20Upgradeable,
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
        uint256 reserveAmountOut,
        int256 inverseTokenAmountOut,
        uint256 newParameterUtilization,
        uint256 newParameterInvariant
    );

    event TokenStaked(address indexed from, uint256 amount);
    event TokenUnstaked(address indexed from, uint256 amount);

    event TokenBought(address indexed from, address indexed recipient, uint256 amountIn, uint256 amountOut);

    event TokenSold(address indexed from, address indexed recipient, uint256 amountIn, uint256 amountOut);

    event RewardClaimed(
        address indexed from, address indexed recipient, uint256 inverseTokenAmount, uint256 reserveAmount
    );

    event FeeConfigChanged(ActionType actionType, uint256 lpFee, uint256 stakingFee, uint256 protocolFee);

    event FeeOwnerChanged(address feeOwner);

    /// STATE VARIABLES ///
    address private _protocolFeeOwner;
    uint256 private _totalStaked;

    uint256 private _parameterInvariant;
    uint256 private _parameterUtilization;

    // swap fee percent = _lpFeePercent + _stakingFeePercent + _protocolFeePercent
    uint256[MAX_ACTION_COUNT] private _lpFeePercent;
    uint256[MAX_ACTION_COUNT] private _stakingFeePercent;
    uint256[MAX_ACTION_COUNT] private _protocolFeePercent;

    IInverseBondingCurveToken private _inverseToken;
    mapping(address => uint256) private _stakingBalances;
    mapping(address => LpPosition) private _lpPositions;

    // Used for curve calculation
    uint256 private _reserveBalance;
    // The initial virtual reserve and supply
    uint256 private _virtualReserveBalance;
    uint256 private _virtualSupply;
    uint256 private _totalLpSupply;
    uint256 private _virtualLpSupply;
    uint256 private _totalLpCreditToken;

    FeeState[MAX_FEE_TYPE_COUNT] private _feeStates;

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
        if (virtualReserve == 0 || supply == 0 || price == 0) {
            revert ParameterZeroNotAllowed();
        }
        if (inverseTokenContractAddress == address(0) || protocolFeeOwner == address(0)) {
            revert EmptyAddress();
        }

        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();
        // __ERC20_init("IBCLP", "IBCLP");

        for (uint8 i = 0; i < MAX_ACTION_COUNT; i++) {
            _lpFeePercent[i] = LP_FEE_PERCENT;
            _stakingFeePercent[i] = STAKE_FEE_PERCENT;
            _protocolFeePercent[i] = PROTOCOL_FEE_PERCENT;
        }

        _inverseToken = IInverseBondingCurveToken(inverseTokenContractAddress);
        _protocolFeeOwner = protocolFeeOwner;
        _virtualReserveBalance = virtualReserve;
        _virtualSupply = supply;
        _reserveBalance = virtualReserve;
        _virtualLpSupply = price.mulDown(virtualReserve.sub(price.mulDown(supply)));

        _parameterUtilization = price.mulDown(supply).divDown(_reserveBalance);
        if (_parameterUtilization >= ONE_UINT) {
            revert UtilizationInvalid(_parameterUtilization);
        }
        _parameterInvariant = _reserveBalance.divDown(supply.powDown(_parameterUtilization));

        CurveLibrary.initializeRewardEMA(_feeStates);

        emit FeeOwnerChanged(protocolFeeOwner);
        emit CurveInitialized(msg.sender, virtualReserve, supply, price, _parameterUtilization, _parameterInvariant);
    }

    function updateFeeConfig(ActionType actionType, uint256 lpFee, uint256 stakingFee, uint256 protocolFee)
        external
        onlyOwner
    {
        if ((lpFee + stakingFee + protocolFee) >= MAX_FEE_PERCENT) {
            revert FeePercentOutOfRange();
        }
        if (uint256(actionType) >= MAX_ACTION_COUNT) {
            revert InvalidInput();
        }
        _lpFeePercent[uint256(actionType)] = lpFee;
        _stakingFeePercent[uint256(actionType)] = stakingFee;
        _protocolFeePercent[uint256(actionType)] = protocolFee;

        emit FeeConfigChanged(actionType, lpFee, stakingFee, protocolFee);
    }

    function updateFeeOwner(address protocolFeeOwner) public onlyOwner {
        if (protocolFeeOwner == address(0)) {
            revert EmptyAddress();
        }
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
        if(_lpBalanceOf(recipient) > 0){
            revert LpAlreadyExist();
        }
        if (msg.value < MIN_INPUT_AMOUNT) {
            revert InputAmountTooSmall(msg.value);
        }
        if (recipient == address(0)) {
            revert EmptyAddress();
        }
        if (_currentPrice() < minPriceLimit) {
            revert PriceOutOfLimit(_currentPrice(), minPriceLimit);
        }

        uint256 currentIbcSupply = _virtualInverseTokenTotalSupply();
        uint256 fee = _calculateAndUpdateFee(msg.value, ActionType.ADD_LIQUIDITY);

        uint256 reserveAdded = msg.value - fee;
        uint256 newReserve = _reserveBalance + reserveAdded;
        uint256 mintToken = reserveAdded.mulDown(_virtualLpTotalSupply()).divDown(_reserveBalance);
        uint256 inverseTokenCredit = reserveAdded.mulDown(currentIbcSupply).divDown(_reserveBalance);


        _updateLpReward(recipient);
        _createLpPosition(mintToken, inverseTokenCredit, recipient);

        _parameterInvariant = newReserve.divDown(_virtualInverseTokenTotalSupply().powDown(_parameterUtilization));
        _reserveBalance = newReserve;
         _checkUtilizationNotChanged();

        emit LiquidityAdded(msg.sender, recipient, msg.value, mintToken, _parameterUtilization, _parameterInvariant);
    }

    function removeLiquidity(address recipient, uint256 maxPriceLimit) external whenNotPaused {
        uint256 burnTokenAmount = _lpBalanceOf(msg.sender);

        if(burnTokenAmount == 0){
            revert LpNotExist();
        }
        if (recipient == address(0)) {
            revert EmptyAddress();
        }
        if (_currentPrice() > maxPriceLimit) {
            revert PriceOutOfLimit(_currentPrice(), maxPriceLimit);
        }
        
        uint256 currentIbcSupply = _virtualInverseTokenTotalSupply();
        uint256 inverseTokenCredit = _lpPositions[msg.sender].inverseTokenCredit;

        uint256 reserveRemoved = burnTokenAmount.mulDown(_reserveBalance).divDown(_virtualLpTotalSupply());
        uint256 inverseTokenBurned = burnTokenAmount.mulDown(currentIbcSupply).divDown(_virtualLpTotalSupply());
        if (reserveRemoved > _reserveBalance - _virtualReserveBalance) {
            revert InsufficientBalance();
        }
        uint256 fee = _calculateAndUpdateFee(reserveRemoved, ActionType.REMOVE_LIQUIDITY);
        uint256 reserveToUser = reserveRemoved - fee;

        uint256 newReserve = _reserveBalance - reserveRemoved;

        _updateLpReward(msg.sender); 
        _removeLpPosition();


        _parameterInvariant = newReserve.divDown(_virtualInverseTokenTotalSupply().powDown(_parameterUtilization));
        _reserveBalance = newReserve;

        
        int256 inverseTokenAmountOut = inverseTokenCredit >= inverseTokenBurned? int256(inverseTokenCredit - inverseTokenBurned) : -int256(inverseTokenBurned - inverseTokenCredit);
        emit LiquidityRemoved(msg.sender, recipient, burnTokenAmount, reserveToUser, inverseTokenAmountOut, _parameterUtilization, _parameterInvariant);

        if(inverseTokenCredit > inverseTokenBurned){
            _inverseToken.mint(recipient, inverseTokenCredit - inverseTokenBurned);
        }else if(inverseTokenCredit < inverseTokenBurned){
            _inverseToken.burnFrom(msg.sender, inverseTokenBurned - inverseTokenCredit);
        }

        _checkUtilizationNotChanged();

        (bool sent,) = recipient.call{value: reserveToUser}("");
        if (!sent) {
            revert FailToSend(recipient);
        }
    }

    function buyTokens(address recipient, uint256 maxPriceLimit)
        external
        payable
        whenNotPaused
    {
        if (recipient == address(0)) {
            revert EmptyAddress();
        }
        if (msg.value < MIN_INPUT_AMOUNT) {
            revert InputAmountTooSmall(msg.value);
        }

        uint256 newToken = _calcMintToken(msg.value);

        uint256 fee = _calculateAndUpdateFee(newToken, ActionType.BUY_TOKEN);
        uint256 mintToken = newToken.sub(fee);
        _reserveBalance += msg.value;
        if (msg.value.divDown(mintToken) > maxPriceLimit) {
            revert PriceOutOfLimit(msg.value.divDown(mintToken), maxPriceLimit);
        }

        _checkInvariantNotChanged(_virtualInverseTokenTotalSupply() + newToken);

        _inverseToken.mint(recipient, mintToken);
        _inverseToken.mint(address(this), fee);

        emit TokenBought(msg.sender, recipient, msg.value, mintToken);
    }

    function sellTokens(address recipient, uint256 amount, uint256 minPriceLimit)
        external
        whenNotPaused
    {
        if (_inverseToken.balanceOf(msg.sender) < amount) {
            revert InsufficientBalance();
        }
        if (amount < MIN_INPUT_AMOUNT) {
            revert InputAmountTooSmall(amount);
        }
        if (recipient == address(0)) {
            revert EmptyAddress();
        }

        uint256 fee = _calculateAndUpdateFee(amount, ActionType.SELL_TOKEN);
        uint256 burnToken = amount.sub(fee);

        uint256 returnLiquidity = _calcBurnToken(burnToken);
        if (returnLiquidity > _reserveBalance - _virtualReserveBalance) {
            returnLiquidity = _reserveBalance - _virtualReserveBalance;
        }
        _reserveBalance -= returnLiquidity;

        if (returnLiquidity.divDown(burnToken) < minPriceLimit) {
            revert PriceOutOfLimit(returnLiquidity.divDown(burnToken), minPriceLimit);
        }

        _checkInvariantNotChanged(_virtualInverseTokenTotalSupply() - burnToken);

        _inverseToken.burnFrom(msg.sender, burnToken);
        IERC20(_inverseToken).safeTransferFrom(msg.sender, address(this), fee);

        emit TokenSold(msg.sender, recipient, amount, returnLiquidity);

        (bool sent,) = recipient.call{value: returnLiquidity}("");
        if (!sent) {
            revert FailToSend(recipient);
        }
    }

    function stake(uint256 amount) external whenNotPaused {
        if (amount < MIN_INPUT_AMOUNT) {
            revert InputAmountTooSmall(amount);
        }
        if (_inverseToken.balanceOf(msg.sender) < amount) {
            revert InsufficientBalance();
        }

        _updateStakingReward(msg.sender);

        _rewardFirstStaker();
        _stakingBalances[msg.sender] += amount;
        _totalStaked += amount;
        IERC20(_inverseToken).safeTransferFrom(msg.sender, address(this), amount);

        emit TokenStaked(msg.sender, amount);
    }

    function unstake(uint256 amount) external whenNotPaused {
        if (_stakingBalances[msg.sender] < amount) {
            revert InsufficientBalance();
        }
        if (amount < MIN_INPUT_AMOUNT) {
            revert InputAmountTooSmall(amount);
        }

        _updateStakingReward(msg.sender);
        _stakingBalances[msg.sender] -= amount;
        _totalStaked -= amount;
        IERC20(_inverseToken).safeTransfer(msg.sender, amount);

        emit TokenUnstaked(msg.sender, amount);
    }

    function claimReward(address recipient) external whenNotPaused {
        if (recipient == address(0)) {
            revert EmptyAddress();
        }
        _updateLpReward(msg.sender);
        _updateStakingReward(msg.sender);

        uint256 inverseTokenReward = _claimReward(_feeStates[uint256(FeeType.INVERSE_TOKEN)]);
        uint256 reserveReward = _claimReward(_feeStates[uint256(FeeType.RESERVE)]);

        if (inverseTokenReward > 0) {
            uint256 maxReward = _inverseToken.balanceOf(address(this)).sub(
                _feeStates[uint256(FeeType.INVERSE_TOKEN)].totalPendingReward[uint256(RewardType.PROTOCOL)].add(
                    _feeStates[uint256(FeeType.INVERSE_TOKEN)].feeForFirstStaker
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
                _feeStates[uint256(FeeType.RESERVE)].totalPendingReward[uint256(RewardType.PROTOCOL)].add(
                    _feeStates[uint256(FeeType.RESERVE)].feeForFirstStaker
                )
            );
            if (reserveReward > maxReward) {
                reserveReward = maxReward;
            }
            (bool sent,) = recipient.call{value: reserveReward}("");
            if (!sent) {
                revert FailToSend(recipient);
            }
        }
    }

    function claimProtocolReward() external whenNotPaused {
        if (msg.sender != _protocolFeeOwner) {
            revert Unauthorized();
        }

        uint256 inverseTokenReward =
            _feeStates[uint256(FeeType.INVERSE_TOKEN)].totalPendingReward[uint256(RewardType.PROTOCOL)];
        uint256 reserveReward = _feeStates[uint256(FeeType.RESERVE)].totalPendingReward[uint256(RewardType.PROTOCOL)];

        _feeStates[uint256(FeeType.INVERSE_TOKEN)].totalPendingReward[uint256(RewardType.PROTOCOL)] = 0;
        _feeStates[uint256(FeeType.RESERVE)].totalPendingReward[uint256(RewardType.PROTOCOL)] = 0;

        if (inverseTokenReward > 0) {
            IERC20(_inverseToken).safeTransfer(_protocolFeeOwner, inverseTokenReward);
        }

        emit RewardClaimed(msg.sender, _protocolFeeOwner, inverseTokenReward, reserveReward);
        if (reserveReward > 0) {
            (bool sent,) = _protocolFeeOwner.call{value: reserveReward}("");
            if (!sent) {
                revert FailToSend(_protocolFeeOwner);
            }
        }
    }

    // function transfer(address recipient, uint256 amount) public override whenNotPaused returns (bool) {
    //     // update the sender/recipient rewards state before balances change
    //     _updateLpReward(msg.sender);
    //     _updateLpReward(recipient);

    //     return (super.transfer(recipient, amount));
    // }

    // function transferFrom(address from, address to, uint256 amount) public override whenNotPaused returns (bool) {
    //     // update the sender/recipient rewards state before balances change
    //     _updateLpReward(from);
    //     _updateLpReward(to);

    //     return (super.transferFrom(from, to, amount));
    // }

    /**
     * @dev Returns the amount of tokens in existence.
     */
    // function totalSupply() public view returns (uint256){
    //     return _totalLpSupply;
    // }


    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function _lpBalanceOf(address account) private view returns (uint256){
        return _lpPositions[account].lpTokenAmount;
    }

    function liquidityPositionOf(address account) external view returns (uint256 lpTokenAmount, uint256 inverseTokenCredit){
        return(_lpPositions[account].lpTokenAmount, _lpPositions[account].inverseTokenCredit);
    }


    function priceOf(uint256 supply) public view returns (uint256) {
        return _parameterInvariant.mulDown(_parameterUtilization).divDown(
            supply.powDown(ONE_UINT.sub(_parameterUtilization))
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
            _totalLpSupply,
            _virtualReserveBalance,
            _virtualSupply,
            _virtualLpTotalSupply(),
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
        (inverseTokenForLp, inverseTokenForStaking, reserveForLp, reserveForStaking) =
            CurveLibrary.calculatePendingReward(recipient, _feeStates, _lpBalanceOf(recipient), _stakingBalances[recipient]);
    }

    function rewardOfProtocol() external view returns (uint256 inverseTokenReward, uint256 reserveReward) {
        inverseTokenReward = _feeStates[uint256(FeeType.INVERSE_TOKEN)].totalPendingReward[uint256(RewardType.PROTOCOL)];
        reserveReward = _feeStates[uint256(FeeType.RESERVE)].totalPendingReward[uint256(RewardType.PROTOCOL)];
    }

    function blockRewardEMA(RewardType rewardType)
        external
        view
        returns (uint256 inverseTokenReward, uint256 reserveReward)
    {
        (inverseTokenReward, reserveReward) = CurveLibrary.calculateBlockRewardEMA(_feeStates, rewardType);
    }

    function rewardState()
        external
        view
        returns (
            uint256[MAX_FEE_STATE_COUNT] memory inverseTokenTotalReward,
            uint256[MAX_FEE_STATE_COUNT] memory inverseTokenPendingReward,
            uint256[MAX_FEE_STATE_COUNT] memory reserveTotalReward,
            uint256[MAX_FEE_STATE_COUNT] memory reservePendingReward
        )
    {
        return (
            _feeStates[uint256(FeeType.INVERSE_TOKEN)].totalReward,
            _feeStates[uint256(FeeType.INVERSE_TOKEN)].totalPendingReward,
            _feeStates[uint256(FeeType.RESERVE)].totalReward,
            _feeStates[uint256(FeeType.RESERVE)].totalPendingReward
        );
    }

    function stakingBalanceOf(address holder) external view returns (uint256) {
        return _stakingBalances[holder];
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    function totalStaked() external view returns (uint256) {
        return _totalStaked;
    }

    function _checkUtilizationNotChanged() private {
        uint256 newParameterUtilization = _currentPrice().mulDown(_virtualInverseTokenTotalSupply()).divDown(_reserveBalance);
        if (CurveLibrary.isValueChanged(_parameterUtilization, newParameterUtilization, ALLOWED_UTILIZATION_CHANGE_PERCENT)) {
            revert UtilizationChanged(_parameterUtilization, newParameterUtilization);
        }
    }

    function _checkInvariantNotChanged(uint256 inverseTokenSupply) private {
        uint256 newInvariant =
            _reserveBalance.divDown(inverseTokenSupply.powDown(_parameterUtilization));
        if (CurveLibrary.isValueChanged(_parameterInvariant, newInvariant, ALLOWED_INVARIANT_CHANGE_PERCENT)) {
            revert InvariantChanged(_parameterInvariant, newInvariant);
        }

    }

    function _createLpPosition(uint256 lpTokenAmount, uint256 inverseTokenCredit, address recipient) private {
        _lpPositions[recipient] = LpPosition(lpTokenAmount, inverseTokenCredit);
        _totalLpCreditToken += inverseTokenCredit;
        _totalLpSupply += lpTokenAmount;
    }

    function _removeLpPosition() private {
        _totalLpSupply -=  _lpPositions[msg.sender].lpTokenAmount;
        _totalLpCreditToken -= _lpPositions[msg.sender].inverseTokenCredit;
        _lpPositions[msg.sender] = LpPosition(0, 0);
    }

    function _calculateAndUpdateFee(uint256 amount, ActionType action) private returns (uint256 totalFee) {
        uint256 lpFee = amount.mulDown(_lpFeePercent[uint256(action)]);
        uint256 stakingFee = amount.mulDown(_stakingFeePercent[uint256(action)]);
        uint256 protocolFee = amount.mulDown(_protocolFeePercent[uint256(action)]);

        FeeState storage state = (action == ActionType.BUY_TOKEN || action == ActionType.SELL_TOKEN)
            ? _feeStates[uint256(FeeType.INVERSE_TOKEN)]
            : _feeStates[uint256(FeeType.RESERVE)];

        CurveLibrary.updateRewardEMA(state);

        if (_lpTotalSupply() > 0) {
            state.globalFeeIndexes[uint256(RewardType.LP)] += lpFee.divDown(_lpTotalSupply());
            state.totalReward[uint256(RewardType.LP)] += lpFee;
            state.totalPendingReward[uint256(RewardType.LP)] += lpFee;
        } else {
            state.totalReward[uint256(RewardType.PROTOCOL)] += lpFee;
            state.totalPendingReward[uint256(RewardType.PROTOCOL)] += lpFee;
        }

        if (_totalStaked > 0) {
            state.globalFeeIndexes[uint256(RewardType.STAKING)] += stakingFee.divDown(_totalStaked);
        } else {
            state.feeForFirstStaker = stakingFee;
        }
        state.totalReward[uint256(RewardType.STAKING)] += stakingFee;
        state.totalPendingReward[uint256(RewardType.STAKING)] += stakingFee;

        state.totalPendingReward[uint256(RewardType.PROTOCOL)] += protocolFee;
        state.totalReward[uint256(RewardType.PROTOCOL)] += protocolFee;

        return lpFee + stakingFee + protocolFee;
    }

    function _rewardFirstStaker() private {
        if (_totalStaked == 0) {
            FeeState storage state = _feeStates[uint256(FeeType.INVERSE_TOKEN)];
            if (state.feeForFirstStaker > 0) {
                state.pendingRewards[uint256(RewardType.STAKING)][msg.sender] = state.feeForFirstStaker;
                state.feeForFirstStaker = 0;
            }

            state = _feeStates[uint256(FeeType.RESERVE)];
            if (state.feeForFirstStaker > 0) {
                state.pendingRewards[uint256(RewardType.STAKING)][msg.sender] = state.feeForFirstStaker;
                state.feeForFirstStaker = 0;
            }
        }
    }

    function _currentPrice() private view returns (uint256) {
        return _parameterInvariant.mulDown(_parameterUtilization).divDown(
            _virtualInverseTokenTotalSupply().powDown(ONE_UINT.sub(_parameterUtilization))
        );
    }

    function _calcMintToken(uint256 amount) private view returns (uint256) {
        uint256 newBalance = _reserveBalance + amount;
        uint256 currentSupply = _virtualInverseTokenTotalSupply();
        uint256 newSupply =
            newBalance.divDown(_reserveBalance).powDown(ONE_UINT.divDown(_parameterUtilization)).mulDown(currentSupply);

        return newSupply > currentSupply ? newSupply.sub(currentSupply) : 0;
    }

    function _calcBurnToken(uint256 amount) private view returns (uint256) {
        uint256 currentSupply = _virtualInverseTokenTotalSupply();
        uint256 newReserve =
            (currentSupply.sub(amount).divUp(currentSupply)).powUp(_parameterUtilization).mulUp(_reserveBalance);

        return _reserveBalance > newReserve ? _reserveBalance.sub(newReserve) : 0;
    }

    // function _calculatePendingReward(address recipient, FeeState storage state, RewardType rewardType)
    //     internal
    //     view
    //     returns (uint256)
    // {
    //     uint256 userBalance = rewardType == RewardType.LP ? balanceOf(recipient) : _stakingBalances[recipient];
    //     return CurveLibrary.calculatePendingReward(recipient, state, userBalance, rewardType);
    // }

    function _claimReward(FeeState storage state) private returns (uint256) {
        uint256 reward = state.pendingRewards[uint256(RewardType.LP)][msg.sender]
            + state.pendingRewards[uint256(RewardType.STAKING)][msg.sender];
        state.totalPendingReward[uint256(RewardType.LP)] -= state.pendingRewards[uint256(RewardType.LP)][msg.sender];
        state.totalPendingReward[uint256(RewardType.STAKING)] -=
            state.pendingRewards[uint256(RewardType.STAKING)][msg.sender];
        state.pendingRewards[uint256(RewardType.LP)][msg.sender] = 0;
        state.pendingRewards[uint256(RewardType.STAKING)][msg.sender] = 0;

        return reward;
    }

    function _updateLpReward(address user) private {
        CurveLibrary.updateReward(user, _lpBalanceOf(user), _feeStates, RewardType.LP);
    }

    function _updateStakingReward(address user) private {
        CurveLibrary.updateReward(user, _stakingBalances[user], _feeStates, RewardType.STAKING);
    }

    // function _beforeTokenTransfer(address from, address to, uint256 amount) internal override whenNotPaused {
    //     super._beforeTokenTransfer(from, to, amount);
    // }

    function _virtualInverseTokenTotalSupply() private view returns (uint256) {
        return _inverseToken.totalSupply() + _virtualSupply + _totalLpCreditToken;
    }

    function  _virtualLpTotalSupply() private view returns (uint256){
        return _totalLpSupply + _virtualLpSupply;
    }

    function _lpTotalSupply() private view returns (uint256){
        return _totalLpSupply;
    }

    // =============================!!! Do not remove below method !!!=============================
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    // ============================================================================================
}
