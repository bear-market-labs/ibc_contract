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
    /// ERRORS ///

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

    // The initial virtual reserve and supply, virtual parameters are derived from initialization but not actual reserve, supply, LP
    uint256 private _virtualReserveBalance;
    uint256 private _virtualSupply;
    uint256 private _virtualLpSupply;

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
     * @param   virtualReserve : Initial virtual reserve
     * @param   supply : Initial virtual supply
     * @param   price : Initial IBC token price
     * @param   inverseTokenContractAddress : IBC token contract address
     * @param   protocolFeeOwner : Fee owner for the reward to protocol
     */
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

        _intialFeeConfig();

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

    /**
     * @notice  Update protocol fee owner
     * @dev     
     * @param   protocolFeeOwner : The new owner of protocol fee
     */
    function updateFeeOwner(address protocolFeeOwner) public onlyOwner {
        if (protocolFeeOwner == address(0)) {
            revert EmptyAddress();
        }
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
     * @dev     LP will get virtual LP token(non-transferable), and one account can only hold one LP position(Need to close and reopen if user want to change)
     * @param   recipient : Account to receive LP token
     * @param   minPriceLimit : Minimum price limit, revert if current price less than the limit
     */
    function addLiquidity(address recipient, uint256 minPriceLimit) external payable whenNotPaused {
        if (_lpBalanceOf(recipient) > 0) {
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

        uint256 fee = _calculateAndUpdateFee(msg.value, ActionType.ADD_LIQUIDITY);
        uint256 reserveAdded = msg.value.sub(fee);
        (uint256 mintToken, uint256 inverseTokenCredit) = _calculateLpAddition(reserveAdded);

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

        if (burnTokenAmount == 0) {
            revert LpNotExist();
        }
        if (recipient == address(0)) {
            revert EmptyAddress();
        }
        if (_currentPrice() > maxPriceLimit) {
            revert PriceOutOfLimit(_currentPrice(), maxPriceLimit);
        }

        uint256 inverseTokenCredit = _lpPositions[msg.sender].inverseTokenCredit;

        (uint256 reserveRemoved, uint256 inverseTokenBurned) = _calculateLpRemoval(burnTokenAmount);
        uint256 newSupply = _virtualInverseTokenTotalSupply() - inverseTokenBurned;
        uint256 fee = _calculateAndUpdateFee(reserveRemoved, ActionType.REMOVE_LIQUIDITY);
        uint256 reserveToUser = reserveRemoved.sub(fee);

        _updateLpReward(msg.sender);
        _removeLpPosition();

        _decreaseReserve(reserveRemoved);
        _updateInvariant(newSupply);

        int256 inverseTokenAmountOut = inverseTokenCredit >= inverseTokenBurned
            ? int256(inverseTokenCredit - inverseTokenBurned)
            : -int256(inverseTokenBurned - inverseTokenCredit);
        emit LiquidityRemoved(
            msg.sender,
            recipient,
            burnTokenAmount,
            reserveToUser,
            inverseTokenAmountOut,
            _parameterUtilization,
            _parameterInvariant
        );

        if (inverseTokenCredit > inverseTokenBurned) {
            _inverseToken.mint(recipient, inverseTokenCredit - inverseTokenBurned);
        } else if (inverseTokenCredit < inverseTokenBurned) {
            _inverseToken.burnFrom(msg.sender, inverseTokenBurned - inverseTokenCredit);
        }

        _checkUtilizationNotChanged();
        _transferReserve(recipient, reserveToUser);
    }

    /**
     * @notice  Buy IBC token with reserve
     * @dev     
     * @param   recipient : Account to receive IBC token
     * @param   maxPriceLimit : Maximum price limit, revert if current price greater than the limit
     */
    function buyTokens(address recipient, uint256 maxPriceLimit) external payable whenNotPaused {
        if (recipient == address(0)) {
            revert EmptyAddress();
        }
        if (msg.value < MIN_INPUT_AMOUNT) {
            revert InputAmountTooSmall(msg.value);
        }

        uint256 newToken = _calculateMintToken(msg.value);
        uint256 fee = _calculateAndUpdateFee(newToken, ActionType.BUY_TOKEN);
        uint256 mintToken = newToken.sub(fee);
        _increaseReserve(msg.value);

        if (msg.value.divDown(mintToken) > maxPriceLimit) {
            revert PriceOutOfLimit(msg.value.divDown(mintToken), maxPriceLimit);
        }

        _checkInvariantNotChanged(_virtualInverseTokenTotalSupply() + newToken);

        _inverseToken.mint(recipient, mintToken);
        _inverseToken.mint(address(this), fee);

        emit TokenBought(msg.sender, recipient, msg.value, mintToken);
    }

    /**
     * @notice  Sell IBC token to get reserve back
     * @dev     
     * @param   recipient : Account to receive reserve
     * @param   amount : IBC token amount to sell
     * @param   minPriceLimit : Minimum price limit, revert if current price less than the limit
     */
    function sellTokens(address recipient, uint256 amount, uint256 minPriceLimit) external whenNotPaused {
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

        uint256 returnLiquidity = _calculateBurnToken(burnToken);
        if (returnLiquidity > _reserveBalance - _virtualReserveBalance) {
            returnLiquidity = _reserveBalance - _virtualReserveBalance;
        }
        _decreaseReserve(returnLiquidity);

        if (returnLiquidity.divDown(burnToken) < minPriceLimit) {
            revert PriceOutOfLimit(returnLiquidity.divDown(burnToken), minPriceLimit);
        }

        _checkInvariantNotChanged(_virtualInverseTokenTotalSupply() - burnToken);

        _inverseToken.burnFrom(msg.sender, burnToken);
        IERC20(_inverseToken).safeTransferFrom(msg.sender, address(this), fee);
        emit TokenSold(msg.sender, recipient, amount, returnLiquidity);

        _transferReserve(recipient, returnLiquidity);
    }

    /**
     * @notice  Stake IBC token to get fee reward
     * @dev     
     * @param   amount : Token amount to stake
     */
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

    /**
     * @notice  Unstake staked IBC token
     * @dev     
     * @param   amount : Token amount to unstake
     */
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

    /**
     * @notice  Claim fee reward
     * @dev     
     * @param   recipient : Account to receive fee reward
     */
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

            _transferReserve(recipient, reserveReward);
        }
    }

    /**
     * @notice  Claim protocol fee reward
     * @dev     Only protocol fee owner allowed
     */
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

        _transferReserve(_protocolFeeOwner, reserveReward);
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
     * @notice  Query price of specific supply
     * @dev     
     * @param   supply : Supply amount
     * @return  uint256 : Price at the input supply
     */
    function priceOf(uint256 supply) public view returns (uint256) {
        return _parameterInvariant.mulDown(_parameterUtilization).divDown(
            supply.powDown(ONE_UINT.sub(_parameterUtilization))
        );
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
        (inverseTokenForLp, inverseTokenForStaking, reserveForLp, reserveForStaking) = CurveLibrary
            .calculatePendingReward(recipient, _feeStates, _lpBalanceOf(recipient), _stakingBalances[recipient]);
    }

    /**
     * @notice  Query protocol fee reward
     * @dev     
     * @return  inverseTokenReward : IBC token reward
     * @return  reserveReward : Reserve reward
     */
    function rewardOfProtocol() external view returns (uint256 inverseTokenReward, uint256 reserveReward) {
        inverseTokenReward = _feeStates[uint256(FeeType.INVERSE_TOKEN)].totalPendingReward[uint256(RewardType.PROTOCOL)];
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
        (inverseTokenReward, reserveReward) = CurveLibrary.calculateBlockRewardEMA(_feeStates, rewardType);
    }

    /**
     * @notice  Query fee state
     * @dev     Each array contains value for LP/Staker/Protocol
     * @return  inverseTokenTotalReward : Total IBC token reward
     * @return  inverseTokenPendingReward : IBC token reward not claimed
     * @return  reserveTotalReward : Total reserve reward
     * @return  reservePendingReward : Reserve reward not claimed
     */
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
    function _calculateLpAddition(uint256 reserveAdded)
        private
        view
        returns (uint256 mintToken, uint256 inverseTokenCredit)
    {
        mintToken = reserveAdded.mulDown(_virtualLpTotalSupply()).divDown(_reserveBalance);
        inverseTokenCredit = reserveAdded.mulDown(_virtualInverseTokenTotalSupply()).divDown(_reserveBalance);
    }

    /**
     * @notice  Calculate result for removing LP
     * @dev     
     * @param   burnLpTokenAmount : LP virtual token amount
     * @return  reserveRemoved : Reserve returned to LP
     * @return  inverseTokenBurned : IBC token need to burned
     */
    function _calculateLpRemoval(uint256 burnLpTokenAmount)
        private
        view
        returns (uint256 reserveRemoved, uint256 inverseTokenBurned)
    {
        reserveRemoved = burnLpTokenAmount.mulDown(_reserveBalance).divDown(_virtualLpTotalSupply());
        inverseTokenBurned =
            burnLpTokenAmount.mulDown(_virtualInverseTokenTotalSupply()).divDown(_virtualLpTotalSupply());
        if (reserveRemoved > _reserveBalance - _virtualReserveBalance) {
            revert InsufficientBalance();
        }
    }

    /**
     * @notice  Calculate and update fee state
     * @dev     
     * @param   amount : IBC/Reserve amount
     * @param   action : Buy/Sell/Add liquidity/Remove liquidity
     * @return  totalFee : Total fee for LP+Staker+Protocol
     */
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

    /**
     * @notice  Reward the accumulated reward to first staker
     * @dev     
     */
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

    /**
     * @notice  Price at current supply
     * @dev     
     * @return  uint256 : Price at current supply
     */
    function _currentPrice() private view returns (uint256) {
        return _parameterInvariant.mulDown(_parameterUtilization).divDown(
            _virtualInverseTokenTotalSupply().powDown(ONE_UINT.sub(_parameterUtilization))
        );
    }

    /**
     * @notice  Calculate IBC token should be minted for input reserve
     * @dev     
     * @param   amount : Reserve input
     * @return  uint256 : IBC token should be minted
     */
    function _calculateMintToken(uint256 amount) private view returns (uint256) {
        uint256 newBalance = _reserveBalance + amount;
        uint256 currentSupply = _virtualInverseTokenTotalSupply();
        uint256 newSupply =
            newBalance.divDown(_reserveBalance).powDown(ONE_UINT.divDown(_parameterUtilization)).mulDown(currentSupply);

        return newSupply > currentSupply ? newSupply.sub(currentSupply) : 0;
    }

    /**
     * @notice  Calculate reserve should be returned for input IBC token
     * @dev     
     * @param   amount : IBC token amount input
     * @return  uint256 : Reserve should returned
     */
    function _calculateBurnToken(uint256 amount) private view returns (uint256) {
        uint256 currentSupply = _virtualInverseTokenTotalSupply();
        uint256 newReserve =
            (currentSupply.sub(amount).divUp(currentSupply)).powUp(_parameterUtilization).mulUp(_reserveBalance);

        return _reserveBalance > newReserve ? _reserveBalance.sub(newReserve) : 0;
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
        return _inverseToken.totalSupply() + _virtualSupply + _totalLpCreditToken;
    }

    /**
     * @notice  Total LP token amount
     * @dev     Include initial virtual LP token amount
     * @return  uint256 : Total LP virtual token amount
     */
    function _virtualLpTotalSupply() private view returns (uint256) {
        return _totalLpSupply + _virtualLpSupply;
    }

    /**
     * @notice  LP token supply 
     * @dev     Exclude initial virtual LP token 
     * @return  uint256 : LP token supply
     */
    function _lpTotalSupply() private view returns (uint256) {
        return _totalLpSupply;
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
