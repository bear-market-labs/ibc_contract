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

import "./lib/CurveLibrary.sol";

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
    mapping(address => uint256) private _stakingBalance;

    // Used for curve calculation
    uint256 private _reserveBalance;
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
        if(virtualReserve == 0 || supply == 0 || price == 0){
            revert ParameterZeroNotAllowed();
        }
        if(inverseTokenContractAddress == address(0) || protocolFeeOwner == address(0)){
            revert EmptyAddress();
        }

        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();
        __ERC20_init("IBCLP", "IBCLP");

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

        _parameterUtilization = price.mulDown(supply).divDown(_reserveBalance);
        if(_parameterUtilization >= ONE_UINT){
            revert UtilizationInvalid(_parameterUtilization);
        }
        _parameterInvariant = _reserveBalance.divDown(supply.powDown(_parameterUtilization));

        emit FeeOwnerChanged(protocolFeeOwner);
        emit CurveInitialized(msg.sender, virtualReserve, supply, price, _parameterUtilization, _parameterInvariant);
    }

    function updateFeeConfig(ActionType actionType, uint256 lpFee, uint256 stakingFee, uint256 protocolFee)
        external
        onlyOwner
    {
        if((lpFee + stakingFee + protocolFee) >= MAX_FEE_PERCENT){
            revert FeePercentOutOfRange();
        }
        if(uint256(actionType) >= MAX_ACTION_COUNT){
            revert InvalidInput();
        }
        _lpFeePercent[uint256(actionType)] = lpFee;
        _stakingFeePercent[uint256(actionType)] = stakingFee;
        _protocolFeePercent[uint256(actionType)] = protocolFee;

        emit FeeConfigChanged(actionType, lpFee, stakingFee, protocolFee);
    }

    function updateFeeOwner(address protocolFeeOwner) public onlyOwner {
        if(protocolFeeOwner == address(0)){
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
        if(msg.value < MIN_INPUT_AMOUNT){
            revert InputAmountTooSmall(msg.value);
        }
        if(recipient == address(0)){
            revert EmptyAddress();
        }
        if(_currentPrice() < minPriceLimit){
            revert PriceOutOfLimit(_currentPrice(), minPriceLimit);
        }

        uint256 currentIbcSupply = _virtualInverseTokenTotalSupply();
        uint256 fee = _calculateAndUpdateFee(msg.value, ActionType.ADD_LIQUIDITY);

        uint256 reserveAdded = msg.value - fee;
        uint256 newBalance = _reserveBalance + reserveAdded;
        uint256 mintToken = _virtualTotalSupply().mulDown(reserveAdded).divDown(
            ONE_UINT.sub(_parameterUtilization).mulDown(_reserveBalance)
        );

        _updateLpReward(recipient);
        _mint(recipient, mintToken);

        _parameterUtilization = _reserveBalance.mulDown(_parameterUtilization).divDown(newBalance);
        if(_parameterUtilization >= ONE_UINT){
            revert UtilizationInvalid(_parameterUtilization);
        }
        _parameterInvariant = newBalance.divDown(currentIbcSupply.powDown(_parameterUtilization));
        _reserveBalance = newBalance;

        emit LiquidityAdded(msg.sender, recipient, msg.value, mintToken, _parameterUtilization, _parameterInvariant);
    }

    function removeLiquidity(address recipient, uint256 amount, uint256 maxPriceLimit) external whenNotPaused {
        if(balanceOf(msg.sender) < amount){
            revert InsufficientBalance();
        }
        if(amount < MIN_INPUT_AMOUNT){
            revert InputAmountTooSmall(amount);
        }
        if(recipient == address(0)){
            revert EmptyAddress();
        }
        if(_currentPrice() > maxPriceLimit){
            revert PriceOutOfLimit(_currentPrice(), maxPriceLimit);
        }

        uint256 currentIbcSupply = _virtualInverseTokenTotalSupply();

        uint256 reserveRemoved =
            _reserveBalance.mulDown(ONE_UINT.sub(_parameterUtilization)).mulDown(amount).divDown(_virtualTotalSupply());
        if (reserveRemoved > _reserveBalance - _virtualReserveBalance) {
            reserveRemoved = _reserveBalance - _virtualReserveBalance;
        }
        uint256 fee = _calculateAndUpdateFee(reserveRemoved, ActionType.REMOVE_LIQUIDITY);
        uint256 reserveToUser = reserveRemoved - fee;

        uint256 newBalance = _reserveBalance - reserveRemoved;
        _parameterUtilization = _reserveBalance.mulDown(_parameterUtilization).divDown(newBalance);
        if(_parameterUtilization >= ONE_UINT){
            revert UtilizationInvalid(_parameterUtilization);
        }        
        _parameterInvariant = newBalance.divDown(currentIbcSupply.powDown(_parameterUtilization));
        _reserveBalance = newBalance;

        _updateLpReward(msg.sender);
        _burn(msg.sender, amount);

        emit LiquidityRemoved(msg.sender, recipient, amount, reserveToUser, _parameterUtilization, _parameterInvariant);

        (bool sent,) = recipient.call{value: reserveToUser}("");
        if(!sent){
            revert FailToSend(recipient);
        }        
    }

    function buyTokens(address recipient, uint256 maxPriceLimit, uint256 maxReserveLimit) external payable whenNotPaused {
        if(recipient == address(0)){
            revert EmptyAddress();
        }      
        if(msg.value < MIN_INPUT_AMOUNT){
            revert InputAmountTooSmall(msg.value);
        }
        if(_reserveBalance > maxReserveLimit){
            revert ReserveOutOfLimit(_reserveBalance, maxReserveLimit);
        }

        uint256 newToken = _calcMintToken(msg.value);

        uint256 fee = _calculateAndUpdateFee(newToken, ActionType.BUY_TOKEN);
        uint256 mintToken = newToken.sub(fee);
        _reserveBalance += msg.value;
        if(msg.value.divDown(mintToken) > maxPriceLimit){
            revert PriceOutOfLimit(msg.value.divDown(mintToken), maxPriceLimit);
        }

        uint256 newInvariant = _reserveBalance.divDown((_virtualInverseTokenTotalSupply() + newToken).powDown(_parameterUtilization));
        if(CurveLibrary.isInvariantChanged( _parameterInvariant, newInvariant)){
            revert InvariantChanged(_parameterInvariant, newInvariant);
        }

        _inverseToken.mint(recipient, mintToken);
        _inverseToken.mint(address(this), fee);

        emit TokenBought(msg.sender, recipient, msg.value, mintToken);
    }

    function sellTokens(address recipient, uint256 amount, uint256 minPriceLimit, uint256 minReserveLimit) external whenNotPaused {
        if(_inverseToken.balanceOf(msg.sender) < amount){
            revert InsufficientBalance();
        }        
        if(amount < MIN_INPUT_AMOUNT){
            revert InputAmountTooSmall(amount);
        }
        if(recipient == address(0)){
            revert EmptyAddress();
        }
        if(_reserveBalance < minReserveLimit){
            revert ReserveOutOfLimit(_reserveBalance, minReserveLimit);
        }

        uint256 fee = _calculateAndUpdateFee(amount, ActionType.SELL_TOKEN);
        uint256 burnToken = amount.sub(fee);

        uint256 returnLiquidity = _calcBurnToken(burnToken);
        if (returnLiquidity > _reserveBalance - _virtualReserveBalance) {
            returnLiquidity = _reserveBalance - _virtualReserveBalance;
        }
        _reserveBalance -= returnLiquidity;

        if(returnLiquidity.divDown(burnToken) < minPriceLimit){
            revert PriceOutOfLimit(returnLiquidity.divDown(burnToken), minPriceLimit);
        }        

        uint256 newInvariant = _reserveBalance.divDown((_virtualInverseTokenTotalSupply() - burnToken).powDown(_parameterUtilization));
        if(CurveLibrary.isInvariantChanged( _parameterInvariant, newInvariant)){
            revert InvariantChanged(_parameterInvariant, newInvariant);
        }

        _inverseToken.burnFrom(msg.sender, burnToken);
        IERC20(_inverseToken).safeTransferFrom(msg.sender, address(this), fee);

        emit TokenSold(msg.sender, recipient, amount, returnLiquidity);

        (bool sent,) = recipient.call{value: returnLiquidity}("");
        if(!sent){
            revert FailToSend(recipient);
        }        
    }

    function stake(uint256 amount) external whenNotPaused {
        if(amount < MIN_INPUT_AMOUNT){
            revert InputAmountTooSmall(amount);
        }
        if(_inverseToken.balanceOf(msg.sender) < amount){
            revert InsufficientBalance();
        }

        _updateStakingReward(msg.sender);

        _rewardFirstStaker();
        _stakingBalance[msg.sender] += amount;
        _totalStaked += amount;
        IERC20(_inverseToken).safeTransferFrom(msg.sender, address(this), amount);

        emit TokenStaked(msg.sender, amount);
    }

    function unstake(uint256 amount) external whenNotPaused {
        if(_stakingBalance[msg.sender] < amount){
            revert InsufficientBalance();
        }
        if(amount < MIN_INPUT_AMOUNT){
            revert InputAmountTooSmall(amount);
        }

        _updateStakingReward(msg.sender);
        _stakingBalance[msg.sender] -= amount;
        _totalStaked -= amount;
        IERC20(_inverseToken).safeTransfer(msg.sender, amount);

        emit TokenUnstaked(msg.sender, amount);
    }

    function claimReward(address recipient) external whenNotPaused {
        if(recipient == address(0)){
            revert EmptyAddress();
        }

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
            if(!sent){
                revert FailToSend(recipient);
            }
        }
    }

    function claimProtocolReward() external whenNotPaused {
        if(msg.sender != _protocolFeeOwner){
            revert Unauthorized();
        }

        uint256 inverseTokenReward = _feeState[uint256(FeeType.INVERSE_TOKEN)].protocolFee;
        uint256 reserveReward = _feeState[uint256(FeeType.RESERVE)].protocolFee;

        _feeState[uint256(FeeType.INVERSE_TOKEN)].protocolFee = 0;
        _feeState[uint256(FeeType.RESERVE)].protocolFee = 0;

        if (inverseTokenReward > 0) {
            IERC20(_inverseToken).safeTransfer(_protocolFeeOwner, inverseTokenReward);
        }

        emit RewardClaimed(msg.sender, _protocolFeeOwner, inverseTokenReward, reserveReward);
        if (reserveReward > 0) {
            (bool sent,) = _protocolFeeOwner.call{value: reserveReward}("");
            if(!sent){
                revert FailToSend(_protocolFeeOwner);
            }            
        }
    }

    function transfer(address recipient, uint256 amount) public override whenNotPaused returns (bool) {
        // update the sender/recipient rewards state before balances change
        _updateLpReward(msg.sender);
        _updateLpReward(recipient);

        return (super.transfer(recipient, amount));
    }

    function transferFrom(address from, address to, uint256 amount) public override whenNotPaused returns (bool) {
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

    function rewardOfProtocol() external view returns (uint256 inverseTokenReward, uint256 reserveReward) {
        inverseTokenReward = _feeState[uint256(FeeType.INVERSE_TOKEN)].protocolFee;
        reserveReward = _feeState[uint256(FeeType.RESERVE)].protocolFee;
    }

    function stakingBalanceOf(address holder) external view returns (uint256) {
        return _stakingBalance[holder];
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    function totalStaked() external view returns (uint256) {
        return _totalStaked;
    }

    function _calculateAndUpdateFee(uint256 amount, ActionType action) private returns (uint256 totalFee) {
        uint256 lpFee = amount.mulDown(_lpFeePercent[uint256(action)]);
        uint256 stakingFee = amount.mulDown(_stakingFeePercent[uint256(action)]);
        uint256 protocolFee = amount.mulDown(_protocolFeePercent[uint256(action)]);

        FeeState storage state = (action == ActionType.BUY_TOKEN || action == ActionType.SELL_TOKEN)
            ? _feeState[uint256(FeeType.INVERSE_TOKEN)]
            : _feeState[uint256(FeeType.RESERVE)];

        if (totalSupply() > 0) {
            state.globalFeeIndexes[uint256(RewardType.LP)] += lpFee.divDown(totalSupply());
            state.totalReward[uint256(RewardType.LP)] += lpFee;
            state.totalPendingReward[uint256(RewardType.LP)] += lpFee;
        } else {
            state.protocolFee += lpFee;
        }

        if (_totalStaked > 0) {
            state.globalFeeIndexes[uint256(RewardType.STAKING)] += stakingFee.divDown(_totalStaked);
        } else {
            state.feeForFirstStaker = stakingFee;
        }
        state.totalReward[uint256(RewardType.STAKING)] += stakingFee;
        state.totalPendingReward[uint256(RewardType.STAKING)] += stakingFee;
        

        state.protocolFee += protocolFee;

        return lpFee + stakingFee + protocolFee;
    }

    function _rewardFirstStaker() private {
        if (_totalStaked == 0) {
            FeeState storage state = _feeState[uint256(FeeType.INVERSE_TOKEN)];
            if (state.feeForFirstStaker > 0) {
                state.pendingRewards[uint256(RewardType.STAKING)][msg.sender] = state.feeForFirstStaker;
                state.feeForFirstStaker = 0;
            }

            state = _feeState[uint256(FeeType.RESERVE)];
            if (state.feeForFirstStaker > 0) {
                state.pendingRewards[uint256(RewardType.STAKING)][msg.sender] = state.feeForFirstStaker;
                state.feeForFirstStaker = 0;
            }
        }
    }

    function _currentPrice() private view returns (uint256){
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

    function _calculatePendingReward(address recipient, FeeState storage state, RewardType rewardType)
        internal
        view
        returns (uint256)
    {
        uint256 userBalance = rewardType == RewardType.LP ? balanceOf(recipient) : _stakingBalance[recipient];
        return CurveLibrary.calculatePendingReward(recipient, state, userBalance, rewardType);
    }

    function _claimReward(FeeState storage state) private returns (uint256) {
        uint256 reward = state.pendingRewards[uint256(RewardType.LP)][msg.sender] + state.pendingRewards[uint256(RewardType.STAKING)][msg.sender];
        state.totalPendingReward[uint256(RewardType.LP)] -= state.pendingRewards[uint256(RewardType.LP)][msg.sender];
        state.totalPendingReward[uint256(RewardType.STAKING)] -= state.pendingRewards[uint256(RewardType.STAKING)][msg.sender];
        state.pendingRewards[uint256(RewardType.LP)][msg.sender] = 0;
        state.pendingRewards[uint256(RewardType.STAKING)][msg.sender] = 0;
        
        return reward;
    }

    function _updateLpReward(address user) private {
        CurveLibrary.updateLpReward(user, balanceOf(user), _feeState[uint256(FeeType.RESERVE)]);
        CurveLibrary.updateLpReward(user, balanceOf(user), _feeState[uint256(FeeType.INVERSE_TOKEN)]);
    }

    function _updateStakingReward(address user) private {
        CurveLibrary.updateStakingReward(user, _stakingBalance[user], _feeState[uint256(FeeType.RESERVE)]);
        CurveLibrary.updateStakingReward(user, _stakingBalance[user], _feeState[uint256(FeeType.INVERSE_TOKEN)]);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override whenNotPaused {
        super._beforeTokenTransfer(from, to, amount);
    }

    function _virtualTotalSupply() private view returns (uint256) {
        return totalSupply() + _virtualReserveBalance;
    }

    function _virtualInverseTokenTotalSupply() private view returns (uint256) {
        return _inverseToken.totalSupply() + _virtualSupply;
    }

    // =============================!!! Do not remove below method !!!=============================
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    // ============================================================================================
}
