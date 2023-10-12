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
import "./CurveLibrary.sol";

/**
 * @title   Inverse bonding curve implementation contract
 * @dev
 * @notice
 */
contract InverseBondingCurve is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    IInverseBondingCurve
{
    using FixedPoint for uint256;
    using SafeERC20 for IERC20;

    /// STATE VARIABLES ///
    address private _protocolFeeOwner;

    // swap/LP fee percent = _lpFeePercent + _stakingFeePercent + _protocolFeePercent
    uint256[MAX_ACTION_COUNT] private _lpFeePercent;
    uint256[MAX_ACTION_COUNT] private _stakingFeePercent;
    uint256[MAX_ACTION_COUNT] private _protocolFeePercent;

    IInverseBondingCurveToken private _inverseToken;

    uint256 private _parameterInvariant;
    uint256 private _parameterUtilization;
    uint256 private _reserveBalance;

    uint256 private _totalLpSupply;
    uint256 private _totalLpCreditToken;
    uint256 private _totalStaked;

    FeeState[MAX_FEE_TYPE_COUNT] private _feeStates;

    mapping(address => uint256) private _stakingBalances;
    mapping(address => LpPosition) private _lpPositions;

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice  Initialize contract
     * @dev
     * @param   supply : Initial virtual supply
     * @param   price : Initial IBC token price
     * @param   inverseTokenContractAddress : IBC token contract address
     * @param   protocolFeeOwner : Fee owner for the reward to protocol
     */
    function initialize(uint256 supply, uint256 price, address inverseTokenContractAddress, address protocolFeeOwner)
        external
        payable
        initializer
    {
        if (supply == 0 || price == 0 || msg.value == 0) revert ParameterZeroNotAllowed();
        if (inverseTokenContractAddress == address(0) || protocolFeeOwner == address(0)) revert EmptyAddress();

        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();

        _intialFeeConfig();

        _inverseToken = IInverseBondingCurveToken(inverseTokenContractAddress);
        _protocolFeeOwner = protocolFeeOwner;
        _reserveBalance = msg.value;
        uint256 lpTokenAmount = price.mulDown(_reserveBalance - (price.mulDown(supply)));

        _parameterUtilization = price.mulDown(supply).divDown(_reserveBalance);
        if (_parameterUtilization >= ONE_UINT) {
            revert UtilizationInvalid(_parameterUtilization);
        }
        _parameterInvariant = _reserveBalance.divDown(supply.powDown(_parameterUtilization));

        CurveLibrary.initializeRewardEMA(_feeStates);

        _updateLpReward(protocolFeeOwner);
        _createLpPosition(lpTokenAmount, supply, protocolFeeOwner);

        emit FeeOwnerChanged(protocolFeeOwner);
        emit CurveInitialized(msg.sender, _reserveBalance, supply, price, _parameterUtilization, _parameterInvariant);
    }

    /**
     * @notice  Update fee config
     * @dev
     * @param   actionType : Fee configuration for : Buy/Sell/Add liquidity/Remove liquidity)
     * @param   lpFee : The percent of fee reward to LP
     * @param   stakingFee : The percent of fee reward to staker
     * @param   protocolFee : The percent of fee reward to protocol
     */
    function updateFeeConfig(ActionType actionType, uint256 lpFee, uint256 stakingFee, uint256 protocolFee)
        external
        onlyOwner
    {
        if ((lpFee + stakingFee + protocolFee) >= MAX_FEE_PERCENT) revert FeePercentOutOfRange();
        if (uint256(actionType) >= MAX_ACTION_COUNT) revert InvalidInput();

        _lpFeePercent[uint256(actionType)] = lpFee;
        _stakingFeePercent[uint256(actionType)] = stakingFee;
        _protocolFeePercent[uint256(actionType)] = protocolFee;

        emit FeeConfigChanged(actionType, lpFee, stakingFee, protocolFee);
    }

    /**
     * @notice  Update protocol fee owner
     * @dev
     * @param   protocolFeeOwner : The new owner of protocol fee
     */
    function updateFeeOwner(address protocolFeeOwner) public onlyOwner {
        if (protocolFeeOwner == address(0)) revert EmptyAddress();

        _protocolFeeOwner = protocolFeeOwner;

        emit FeeOwnerChanged(protocolFeeOwner);
    }

    /**
     * @notice  Pause contract
     * @dev     Not able to buy/sell/add liquidity/remove liquidity/transfer token
     */
    function pause() external onlyOwner {
        _pause();
        _inverseToken.pause();
    }

    /**
     * @notice  Unpause contract
     * @dev
     */
    function unpause() external onlyOwner {
        _unpause();
        _inverseToken.unpause();
    }

    /**
     * @notice  Add reserve liquidity to inverse bonding curve
     * @dev     LP will get virtual LP token(non-transferable),
     *          and one account can only hold one LP position(Need to close and reopen if user want to change)
     * @param   recipient : Account to receive LP token
     * @param   minPriceLimit : Minimum price limit, revert if current price less than the limit
     */
    function addLiquidity(address recipient, uint256 minPriceLimit) external payable whenNotPaused {
        if (_lpBalanceOf(recipient) > 0) revert LpAlreadyExist();
        if (msg.value < MIN_INPUT_AMOUNT) revert InputAmountTooSmall(msg.value);
        if (recipient == address(0)) revert EmptyAddress();
        if (_currentPrice() < minPriceLimit) revert PriceOutOfLimit(_currentPrice(), minPriceLimit);

        uint256 fee =
            _calcAndUpdateFee(msg.value, false, ActionType.ADD_LIQUIDITY, _feeStates[uint256(FeeType.RESERVE)]);
        uint256 reserveAdded = msg.value - fee;
        (uint256 mintToken, uint256 inverseTokenCredit) = _calcLpAddition(reserveAdded);

        _updateLpReward(recipient);
        _createLpPosition(mintToken, inverseTokenCredit, recipient);
        _increaseReserve(reserveAdded);
        _updateInvariant(_virtualInverseTokenTotalSupply());
        _checkUtilizationNotChanged();

        emit LiquidityAdded(msg.sender, recipient, msg.value, mintToken, _parameterUtilization, _parameterInvariant);
    }

    /**
     * @notice  Remove reserve liquidity from inverse bonding curve
     * @dev     IBC token may needed to burn LP
     * @param   recipient : Account to receive reserve
     * @param   maxPriceLimit : Maximum price limit, revert if current price greater than the limit
     */
    function removeLiquidity(address recipient, uint256 maxPriceLimit) external whenNotPaused {
        uint256 burnTokenAmount = _lpBalanceOf(msg.sender);

        if (burnTokenAmount == 0) revert LpNotExist();
        if (recipient == address(0)) revert EmptyAddress();
        if (_currentPrice() > maxPriceLimit) revert PriceOutOfLimit(_currentPrice(), maxPriceLimit);

        _updateLpReward(msg.sender);
        uint256 inverseTokenCredit = _lpPositions[msg.sender].inverseTokenCredit;
        (uint256 reserveRemoved, uint256 inverseTokenBurned) = _calcLpRemoval(burnTokenAmount);
        uint256 newSupply = _virtualInverseTokenTotalSupply() - inverseTokenBurned;
        // Remove LP position(LP token and IBC credit) after caclulation
        _removeLpPosition();
        uint256 fee =
            _calcAndUpdateFee(reserveRemoved, false, ActionType.REMOVE_LIQUIDITY, _feeStates[uint256(FeeType.RESERVE)]);
        uint256 reserveToUser = reserveRemoved - fee;

        _decreaseReserve(reserveRemoved);
        _updateInvariant(newSupply);

        emit LiquidityRemoved(
            msg.sender,
            recipient,
            burnTokenAmount,
            reserveToUser,
            inverseTokenCredit,
            inverseTokenBurned,
            _parameterUtilization,
            _parameterInvariant
        );

        if (inverseTokenCredit > inverseTokenBurned) {
            uint256 tokenMint = inverseTokenCredit - inverseTokenBurned;
            fee = _calcAndUpdateFee(
                tokenMint, false, ActionType.REMOVE_LIQUIDITY, _feeStates[uint256(FeeType.IBC_FROM_LP)]
            );
            _inverseToken.mint(recipient, tokenMint - fee);
            _inverseToken.mint(address(this), fee);
        } else if (inverseTokenCredit < inverseTokenBurned) {
            _inverseToken.burnFrom(msg.sender, inverseTokenBurned - inverseTokenCredit);
        }

        _checkUtilizationNotChanged();
        _transferReserve(recipient, reserveToUser);
    }
    
    /**
     * @notice  Buy IBC token with reserve
     * @dev     If exactAmountOut greater than zero, then it will mint exact token to recipient
     * @param   recipient : Account to receive IBC token
     * @param   exactAmountOut : Exact amount IBC token to mint to user
     * @param   maxPriceLimit : Maximum price limit, revert if current price greater than the limit
     */
    function buyTokens(address recipient, uint256 exactAmountOut, uint256 maxPriceLimit)
        external
        payable
        whenNotPaused
    {
        if (recipient == address(0)) revert EmptyAddress();
        if (msg.value < MIN_INPUT_AMOUNT) revert InputAmountTooSmall(msg.value);
        if (exactAmountOut > 0 && exactAmountOut < MIN_INPUT_AMOUNT) revert InputAmountTooSmall(exactAmountOut);

        (uint256 totalMint, uint256 tokenToUser, uint256 fee, uint256 reserve) =
            exactAmountOut == 0 ? _calcExacAmountIn() : _calcExacAmountOut(exactAmountOut);
        if (exactAmountOut > 0 && msg.value < reserve) {
            revert InsufficientBalance();
        }

        _increaseReserve(reserve);

        if (reserve.divDown(tokenToUser) > maxPriceLimit) {
            revert PriceOutOfLimit(reserve.divDown(tokenToUser), maxPriceLimit);
        }

        _checkInvariantNotChanged(_virtualInverseTokenTotalSupply() + totalMint);

        emit TokenBought(msg.sender, recipient, reserve, tokenToUser);

        _inverseToken.mint(recipient, tokenToUser);
        _inverseToken.mint(address(this), fee);

        // Send back additional reserve
        if (msg.value > reserve) {
            _transferReserve(recipient, msg.value - reserve);
        }
    }

    /**
     * @notice  Sell IBC token to get reserve back
     * @dev
     * @param   recipient : Account to receive reserve
     * @param   amount : IBC token amount to sell
     * @param   minPriceLimit : Minimum price limit, revert if current price less than the limit
     */
    function sellTokens(address recipient, uint256 amount, uint256 minPriceLimit) external whenNotPaused {
        if (_inverseToken.balanceOf(msg.sender) < amount) revert InsufficientBalance();
        if (amount < MIN_INPUT_AMOUNT) revert InputAmountTooSmall(amount);
        if (recipient == address(0)) revert EmptyAddress();

        uint256 fee =
            _calcAndUpdateFee(amount, false, ActionType.SELL_TOKEN, _feeStates[uint256(FeeType.IBC_FROM_TRADE)]);
        uint256 burnToken = amount - fee;

        uint256 returnLiquidity = _calcBurnToken(burnToken);
        _decreaseReserve(returnLiquidity);

        if (returnLiquidity.divDown(burnToken) < minPriceLimit) {
            revert PriceOutOfLimit(returnLiquidity.divDown(burnToken), minPriceLimit);
        }

        _checkInvariantNotChanged(_virtualInverseTokenTotalSupply() - burnToken);

        emit TokenSold(msg.sender, recipient, amount, returnLiquidity);

        _inverseToken.burnFrom(msg.sender, burnToken);
        IERC20(_inverseToken).safeTransferFrom(msg.sender, address(this), fee);
        _transferReserve(recipient, returnLiquidity);
    }

    /**
     * @notice  Stake IBC token to get fee reward
     * @dev
     * @param   amount : Token amount to stake
     */
    function stake(uint256 amount) external whenNotPaused {
        if (amount < MIN_INPUT_AMOUNT) revert InputAmountTooSmall(amount);
        if (_inverseToken.balanceOf(msg.sender) < amount) revert InsufficientBalance();

        _updateStakingReward(msg.sender);

        _rewardFirstStaker();
        _stakingBalances[msg.sender] += amount;
        _totalStaked += amount;

        emit TokenStaked(msg.sender, amount);
        IERC20(_inverseToken).safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice  Unstake staked IBC token
     * @dev
     * @param   amount : Token amount to unstake
     */
    function unstake(uint256 amount) external whenNotPaused {
        if (_stakingBalances[msg.sender] < amount) revert InsufficientBalance();
        if (amount < MIN_INPUT_AMOUNT) revert InputAmountTooSmall(amount);

        _updateStakingReward(msg.sender);
        _stakingBalances[msg.sender] -= amount;
        _totalStaked -= amount;

        emit TokenUnstaked(msg.sender, amount);
        IERC20(_inverseToken).safeTransfer(msg.sender, amount);
    }

    /**
     * @notice  Claim fee reward
     * @dev
     * @param   recipient : Account to receive fee reward
     */
    function claimReward(address recipient) external whenNotPaused {
        if (recipient == address(0)) revert EmptyAddress();

        _updateLpReward(msg.sender);
        _updateStakingReward(msg.sender);

        uint256 inverseTokenReward = _claimReward(_feeStates[uint256(FeeType.IBC_FROM_TRADE)])
            + _claimReward(_feeStates[uint256(FeeType.IBC_FROM_LP)]);
        uint256 reserveReward = _claimReward(_feeStates[uint256(FeeType.RESERVE)]);

        emit RewardClaimed(msg.sender, recipient, inverseTokenReward, reserveReward);

        if (inverseTokenReward > 0) {
            IERC20(_inverseToken).safeTransfer(recipient, inverseTokenReward);
        }

        _transferReserve(recipient, reserveReward);
    }

    /**
     * @notice  Claim protocol fee reward
     * @dev     Only protocol fee owner allowed
     */
    function claimProtocolReward() external whenNotPaused {
        if (msg.sender != _protocolFeeOwner) revert Unauthorized();

        uint256 inverseTokenReward = _feeStates[uint256(FeeType.IBC_FROM_TRADE)].totalPendingReward[uint256(
            RewardType.PROTOCOL
        )] + _feeStates[uint256(FeeType.IBC_FROM_LP)].totalPendingReward[uint256(RewardType.PROTOCOL)];
        uint256 reserveReward = _feeStates[uint256(FeeType.RESERVE)].totalPendingReward[uint256(RewardType.PROTOCOL)];

        _feeStates[uint256(FeeType.IBC_FROM_TRADE)].totalPendingReward[uint256(RewardType.PROTOCOL)] = 0;
        _feeStates[uint256(FeeType.IBC_FROM_LP)].totalPendingReward[uint256(RewardType.PROTOCOL)] = 0;
        _feeStates[uint256(FeeType.RESERVE)].totalPendingReward[uint256(RewardType.PROTOCOL)] = 0;

        emit RewardClaimed(msg.sender, _protocolFeeOwner, inverseTokenReward, reserveReward);

        if (inverseTokenReward > 0) {
            IERC20(_inverseToken).safeTransfer(_protocolFeeOwner, inverseTokenReward);
        }

        _transferReserve(_protocolFeeOwner, reserveReward);
    }

    /**
     * @notice  Query LP position
     * @dev
     * @param   account : Account to query position
     * @return  lpTokenAmount : LP virtual token amount
     * @return  inverseTokenCredit : IBC token credited(Virtual, not able to sell/stake/transfer)
     */
    function liquidityPositionOf(address account)
        external
        view
        returns (uint256 lpTokenAmount, uint256 inverseTokenCredit)
    {
        return (_lpPositions[account].lpTokenAmount, _lpPositions[account].inverseTokenCredit);
    }

    /**
     * @notice  Get IBC token contract address
     * @dev
     * @return  address : IBC token contract address
     */
    function inverseTokenAddress() external view returns (address) {
        return address(_inverseToken);
    }

    /**
     * @notice  Query current inverse bonding curve parameter
     * @dev
     * @return  parameters : See CurveParameter for detail
     */
    function curveParameters() external view returns (CurveParameter memory parameters) {
        uint256 supply = _virtualInverseTokenTotalSupply();
        return CurveParameter(
            _reserveBalance, supply, _totalLpSupply, _currentPrice(), _parameterInvariant, _parameterUtilization
        );
    }

    /**
     * @notice  Query fee configuration
     * @dev     Each fee config array contains configuration for four actions(Buy/Sell/Add liquidity/Remove liquidity)
     * @return  lpFee : The percent of fee reward to LP
     * @return  stakingFee : The percent of fee reward to staker
     * @return  protocolFee : The percent of fee reward to protocol
     */
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

    /**
     * @notice  Query protocol fee owner
     * @dev
     * @return  address : protocol fee owner
     */
    function feeOwner() external view returns (address) {
        return _protocolFeeOwner;
    }

    /**
     * @notice  Query reward of account
     * @dev
     * @param   recipient : Account to query
     * @return  inverseTokenForLp : IBC token reward for account as LP
     * @return  inverseTokenForStaking : IBC token reward for account as Staker
     * @return  reserveForLp : Reserve reward for account as LP
     * @return  reserveForStaking : Reserve reward for account as Staker
     */
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
            CurveLibrary.calcPendingReward(recipient, _feeStates, _lpBalanceOf(recipient), _stakingBalances[recipient]);
    }

    /**
     * @notice  Query protocol fee reward
     * @dev
     */
    function rewardOfProtocol() external view returns (uint256 inverseTokenReward, uint256 reserveReward) {
        inverseTokenReward = _feeStates[uint256(FeeType.IBC_FROM_TRADE)].totalPendingReward[uint256(RewardType.PROTOCOL)]
            + _feeStates[uint256(FeeType.IBC_FROM_LP)].totalPendingReward[uint256(RewardType.PROTOCOL)];
        reserveReward = _feeStates[uint256(FeeType.RESERVE)].totalPendingReward[uint256(RewardType.PROTOCOL)];
    }

    /**
     * @notice  Query EMA(exponential moving average) reward per block
     * @dev
     * @param   rewardType : Reward type: LP or staking
     * @return  inverseTokenReward : EMA IBC token reward per block
     * @return  reserveReward : EMA reserve reward per block
     */
    function blockRewardEMA(RewardType rewardType)
        external
        view
        returns (uint256 inverseTokenReward, uint256 reserveReward)
    {
        (inverseTokenReward, reserveReward) = CurveLibrary.calcBlockRewardEMA(_feeStates, rewardType);
    }

    /**
     * @notice  Query fee state
     * @dev     Each array contains value for LP/Staker/Protocol
     * @return  totalReward : Total IBC token reward
     * @return  totalPendingReward : IBC token reward not claimed
     */
    function rewardState()
        external
        view
        returns (
            uint256[MAX_FEE_TYPE_COUNT][MAX_FEE_STATE_COUNT] memory totalReward,
            uint256[MAX_FEE_TYPE_COUNT][MAX_FEE_STATE_COUNT] memory totalPendingReward
        )
    {
        totalReward = [
            _feeStates[uint256(FeeType.IBC_FROM_TRADE)].totalReward,
            _feeStates[uint256(FeeType.IBC_FROM_LP)].totalReward,
            _feeStates[uint256(FeeType.RESERVE)].totalReward
        ];
        totalPendingReward = [
            _feeStates[uint256(FeeType.IBC_FROM_TRADE)].totalPendingReward,
            _feeStates[uint256(FeeType.IBC_FROM_LP)].totalPendingReward,
            _feeStates[uint256(FeeType.RESERVE)].totalPendingReward
        ];
    }

    /**
     * @notice  Query staking balance
     * @dev
     * @param   account : Account address to query
     * @return  uint256 : Staking balance
     */
    function stakingBalanceOf(address account) external view returns (uint256) {
        return _stakingBalances[account];
    }

    /**
     * @notice  Get implementation contract address of the upgradable pattern
     * @dev
     * @return  address : Implementation contract address
     */
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    /**
     * @notice  Query total staked IBC token amount
     * @dev
     * @return  uint256 : Total staked amount
     */
    function totalStaked() external view returns (uint256) {
        return _totalStaked;
    }

    /**
     * @notice  Initialize default fee percent
     * @dev
     */
    function _intialFeeConfig() private {
        for (uint8 i = 0; i < MAX_ACTION_COUNT; i++) {
            _lpFeePercent[i] = LP_FEE_PERCENT;
            _stakingFeePercent[i] = STAKE_FEE_PERCENT;
            _protocolFeePercent[i] = PROTOCOL_FEE_PERCENT;
        }
    }
    /**
     * @notice  Increase reserve parameter of inverse bonding curve
     * @dev
     * @param   amount : amount to increase
     */

    function _increaseReserve(uint256 amount) private {
        _reserveBalance += amount;
    }

    /**
     * @notice  Decrease reserve parameter of inverse bonding curve
     * @dev
     * @param   amount : amount to decrease
     */
    function _decreaseReserve(uint256 amount) private {
        _reserveBalance -= amount;
    }

    /**
     * @notice  Transfer reserve to recipient
     * @dev     Revert if transfer fail
     * @param   recipient : Account to transfer reserve to
     * @param   amount : Amount to transfer
     */
    function _transferReserve(address recipient, uint256 amount) private {
        if (amount > 0) {
            (bool sent,) = recipient.call{value: amount}("");
            if (!sent) {
                revert FailToSend(recipient);
            }
        }
    }

    /**
     * @notice  Update invariant parameter of inverse bonding curve
     * @dev
     * @param   newSupply : Supply parameter to calculate invariant
     */
    function _updateInvariant(uint256 newSupply) private {
        _parameterInvariant = _reserveBalance.divDown(newSupply.powDown(_parameterUtilization));
    }

    /**
     * @notice  Returns the LP token amount owned by `account`
     * @dev
     * @param   account : Account to query
     */
    function _lpBalanceOf(address account) private view returns (uint256) {
        return _lpPositions[account].lpTokenAmount;
    }

    /**
     * @notice  Check whether utitlization parameter changed(value change percent within range)
     * @dev     Revert if changed
     */
    function _checkUtilizationNotChanged() private view {
        uint256 newParameterUtilization =
            _currentPrice().mulDown(_virtualInverseTokenTotalSupply()).divDown(_reserveBalance);
        if (
            CurveLibrary.isValueChanged(
                _parameterUtilization, newParameterUtilization, ALLOWED_UTILIZATION_CHANGE_PERCENT
            )
        ) {
            revert UtilizationChanged(_parameterUtilization, newParameterUtilization);
        }
    }

    /**
     * @notice  Check whether utitlization parameter changed(value change percent within range)
     * @dev     Revert if changed
     * @param   inverseTokenSupply : Curve supply to calculate invariant parameter
     */
    function _checkInvariantNotChanged(uint256 inverseTokenSupply) private view {
        uint256 newInvariant = _reserveBalance.divDown(inverseTokenSupply.powDown(_parameterUtilization));
        if (CurveLibrary.isValueChanged(_parameterInvariant, newInvariant, ALLOWED_INVARIANT_CHANGE_PERCENT)) {
            revert InvariantChanged(_parameterInvariant, newInvariant);
        }
    }

    /**
     * @notice  Add LP position
     * @dev
     * @param   lpTokenAmount : LP virtual token amount
     * @param   inverseTokenCredit : Virtual IBC token credited to LP
     * @param   recipient : Account to hold LP position
     */
    function _createLpPosition(uint256 lpTokenAmount, uint256 inverseTokenCredit, address recipient) private {
        _lpPositions[recipient] = LpPosition(lpTokenAmount, inverseTokenCredit);
        _totalLpCreditToken += inverseTokenCredit;
        _totalLpSupply += lpTokenAmount;
    }

    /**
     * @notice  Remove LP position
     * @dev
     */
    function _removeLpPosition() private {
        _totalLpSupply -= _lpPositions[msg.sender].lpTokenAmount;
        _totalLpCreditToken -= _lpPositions[msg.sender].inverseTokenCredit;
        _lpPositions[msg.sender] = LpPosition(0, 0);
    }

    /**
     * @notice  Calculate result for adding LP
     * @dev
     * @param   reserveAdded : Reserve amount added
     * @return  mintToken : LP virtual token assigned to LP
     * @return  inverseTokenCredit : Virtual IBC token credited to LP
     */
    function _calcLpAddition(uint256 reserveAdded)
        private
        view
        returns (uint256 mintToken, uint256 inverseTokenCredit)
    {
        mintToken = reserveAdded.mulDown(_totalLpSupply).divDown(_reserveBalance);
        inverseTokenCredit = reserveAdded.mulDown(_virtualInverseTokenTotalSupply()).divDown(_reserveBalance);
    }

    /**
     * @notice  Calculate result for removing LP
     * @dev
     * @param   burnLpTokenAmount : LP virtual token amount
     * @return  reserveRemoved : Reserve returned to LP
     * @return  inverseTokenBurned : IBC token need to burned
     */
    function _calcLpRemoval(uint256 burnLpTokenAmount)
        private
        view
        returns (uint256 reserveRemoved, uint256 inverseTokenBurned)
    {
        reserveRemoved = burnLpTokenAmount.mulDown(_reserveBalance).divDown(_totalLpSupply);
        inverseTokenBurned = burnLpTokenAmount.mulDown(_virtualInverseTokenTotalSupply()).divDown(_totalLpSupply);
        if (reserveRemoved > _reserveBalance) {
            revert InsufficientBalance();
        }
    }

    /**
     * @notice  Calculate and update fee state
     * @dev
     * @param   amount : IBC/Reserve amount
     * @param   amountAfterFee: Whether amount is value after fee deduction
     * @param   action : Buy/Sell/Add liquidity/Remove liquidity
     * @return  totalFee : Total fee for LP+Staker+Protocol
     */
    function _calcAndUpdateFee(uint256 amount, bool amountAfterFee, ActionType action, FeeState storage feeState)
        private
        returns (uint256 totalFee)
    {
        (uint256 lpFee, uint256 stakingFee, uint256 protocolFee) = _calcFee(amount, amountAfterFee, action);
        CurveLibrary.updateRewardEMA(feeState);

        if (_totalLpSupply > 0) {
            feeState.globalFeeIndexes[uint256(RewardType.LP)] += lpFee.divDown(_totalLpSupply);
            feeState.totalReward[uint256(RewardType.LP)] += lpFee;
            feeState.totalPendingReward[uint256(RewardType.LP)] += lpFee;
        } else {
            feeState.totalReward[uint256(RewardType.PROTOCOL)] += lpFee;
            feeState.totalPendingReward[uint256(RewardType.PROTOCOL)] += lpFee;
        }

        if (_totalStaked > 0) {
            feeState.globalFeeIndexes[uint256(RewardType.STAKING)] += stakingFee.divDown(_totalStaked);
        } else {
            feeState.feeForFirstStaker = stakingFee;
        }
        feeState.totalReward[uint256(RewardType.STAKING)] += stakingFee;
        feeState.totalPendingReward[uint256(RewardType.STAKING)] += stakingFee;

        feeState.totalPendingReward[uint256(RewardType.PROTOCOL)] += protocolFee;
        feeState.totalReward[uint256(RewardType.PROTOCOL)] += protocolFee;

        return lpFee + stakingFee + protocolFee;
    }

    /**
     * @notice  Calculate fee of action
     * @dev
     * @param   amount : Token/Reserve amount
     * @param   amountAfterFee : Whether amount is value after fee deduction
     * @param   action : Buy/Sell/Add liquidity/Remove liquidity
     * @return  lpFee : Fee reward for LP
     * @return  stakingFee : Fee reward for staker
     * @return  protocolFee : Fee reward for protocol
     */
    function _calcFee(uint256 amount, bool amountAfterFee, ActionType action)
        private
        view
        returns (uint256 lpFee, uint256 stakingFee, uint256 protocolFee)
    {
        if (amountAfterFee) {
            uint256 totalFeePercent = _lpFeePercent[uint256(action)] + _stakingFeePercent[uint256(action)]
                + _protocolFeePercent[uint256(action)];
            uint256 amountBeforeFee = amount.divDown(ONE_UINT - totalFeePercent);
            uint256 totalFee = amountBeforeFee - amount;
            lpFee = totalFee.mulDown(_lpFeePercent[uint256(action)]).divDown(totalFeePercent);
            stakingFee = totalFee.mulDown(_stakingFeePercent[uint256(action)]).divDown(totalFeePercent);
            protocolFee = totalFee - lpFee - stakingFee;
        } else {
            lpFee = amount.mulDown(_lpFeePercent[uint256(action)]);
            stakingFee = amount.mulDown(_stakingFeePercent[uint256(action)]);
            protocolFee = amount.mulDown(_protocolFeePercent[uint256(action)]);
        }
    }

    /**
     * @notice  Calculate token need to mint, fee based on input reserve
     * @dev     
     * @return  totalMint : Total token need to mint
     * @return  tokenToUser : Token amount mint to user
     * @return  fee : Total fee
     * @return  reserve : Reserve needed  
     */
    function _calcExacAmountIn()
        private
        returns (uint256 totalMint, uint256 tokenToUser, uint256 fee, uint256 reserve)
    {
        totalMint = _calcMintToken(msg.value);
        fee = _calcAndUpdateFee(totalMint, false, ActionType.BUY_TOKEN, _feeStates[uint256(FeeType.IBC_FROM_TRADE)]);
        tokenToUser = totalMint - fee;
        reserve = msg.value;
    }

    /**
     * @notice  Calculate token need to mint, fee and reserve needed based on token amount out
     * @dev
     * @param   amountOut : Exact amount token mint to user
     * @return  totalMint : Total token need to mint
     * @return  tokenToUser : Token amount mint to user
     * @return  fee : Total fee
     * @return  reserve : Reserve needed
     */
    function _calcExacAmountOut(uint256 amountOut)
        private
        returns (uint256 totalMint, uint256 tokenToUser, uint256 fee, uint256 reserve)
    {
        fee = _calcAndUpdateFee(amountOut, true, ActionType.BUY_TOKEN, _feeStates[uint256(FeeType.IBC_FROM_TRADE)]);
        tokenToUser = amountOut;
        totalMint = amountOut + fee;
        reserve = (_virtualInverseTokenTotalSupply() + totalMint).divDown(_virtualInverseTokenTotalSupply()).powDown(
            _parameterUtilization
        ).mulDown(_reserveBalance) - _reserveBalance;
    }

    /**
     * @notice  Reward the accumulated reward to first staker
     * @dev
     */
    function _rewardFirstStaker() private {
        if (_totalStaked == 0) {
            _rewardFirstStaker(FeeType.IBC_FROM_TRADE);
            _rewardFirstStaker(FeeType.IBC_FROM_LP);
            _rewardFirstStaker(FeeType.RESERVE);
        }
    }

    /**
     * @notice  Reward first staker for different reward(IBC/ETH)
     * @dev
     * @param   feeType : IBC token or Reserve(ETH)
     */
    function _rewardFirstStaker(FeeType feeType) private {
        FeeState storage state = _feeStates[uint256(feeType)];
        if (state.feeForFirstStaker > 0) {
            state.pendingRewards[uint256(RewardType.STAKING)][msg.sender] = state.feeForFirstStaker;
            state.feeForFirstStaker = 0;
        }
    }

    /**
     * @notice  Price at current supply
     * @dev
     * @return  uint256 : Price at current supply
     */
    function _currentPrice() private view returns (uint256) {
        return _parameterUtilization.mulDown(_reserveBalance).divDown(_virtualInverseTokenTotalSupply());
    }

    /**
     * @notice  Calculate IBC token should be minted for input reserve
     * @dev
     * @param   amount : Reserve input
     * @return  uint256 : IBC token should be minted
     */
    function _calcMintToken(uint256 amount) private view returns (uint256) {
        uint256 newBalance = _reserveBalance + amount;
        uint256 currentSupply = _virtualInverseTokenTotalSupply();
        uint256 newSupply =
            newBalance.divDown(_reserveBalance).powDown(ONE_UINT.divDown(_parameterUtilization)).mulDown(currentSupply);

        return newSupply > currentSupply ? newSupply - currentSupply : 0;
    }

    /**
     * @notice  Calculate reserve should be returned for input IBC token
     * @dev
     * @param   amount : IBC token amount input
     * @return  uint256 : Reserve should returned
     */
    function _calcBurnToken(uint256 amount) private view returns (uint256) {
        uint256 currentSupply = _virtualInverseTokenTotalSupply();
        uint256 newReserve =
            ((currentSupply - amount).divUp(currentSupply)).powUp(_parameterUtilization).mulUp(_reserveBalance);

        return _reserveBalance > newReserve ? _reserveBalance - newReserve : 0;
    }

    /**
     * @notice  Update fee state for claiming reward
     * @dev
     * @param   state : Fee state
     * @return  uint256 : Reward amount to be claimed
     */
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

    /**
     * @notice  Update reward state for LP
     * @dev
     * @param   account : Account to be updated
     */
    function _updateLpReward(address account) private {
        CurveLibrary.updateReward(account, _lpBalanceOf(account), _feeStates, RewardType.LP);
    }

    /**
     * @notice  Update reward state for staker
     * @dev
     * @param   account : Account to be updated
     */
    function _updateStakingReward(address account) private {
        CurveLibrary.updateReward(account, _stakingBalances[account], _feeStates, RewardType.STAKING);
    }

    /**
     * @notice  Total IBC amount for curve calculation
     * @dev     Include virtual supply and token credited to LP
     * @return  uint256 : Total IBC amount
     */
    function _virtualInverseTokenTotalSupply() private view returns (uint256) {
        return _inverseToken.totalSupply() + _totalLpCreditToken;
    }

    // =============================!!! Do not remove below method !!!=============================
    /**
     * @notice  For contract upgrade
     * @dev     We and remove upgradable feature in future with this method
     * @param   newImplementation : New contract implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    // ============================================================================================
}
