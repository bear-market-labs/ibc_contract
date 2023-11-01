// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "openzeppelin/token/ERC20/IERC20.sol";
import "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "oz-upgradeable/proxy/utils/Initializable.sol";
import "oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

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
import "./interface/IInverseBondingCurveAdmin.sol";

/**
 * @title   Inverse bonding curve implementation contract
 * @dev
 * @notice
 */
contract InverseBondingCurve is Initializable, UUPSUpgradeable, IInverseBondingCurve {
    using FixedPoint for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IInverseBondingCurveToken;

    /// STATE VARIABLES ///
    address private _protocolFeeOwner;

    IInverseBondingCurveToken private _inverseToken;
    IERC20 private _reserveToken;
    IInverseBondingCurveAdmin _adminContract;
    address _router;

    uint256 private _invariant;
    uint256 private _curveReserveBalance;

    // Used to ensure enough token transfered to curve
    uint256 private _reserveBalance;
    uint256 private _inverseTokenBalance;

    //TODO: should add process for ERC20 token decimals

    uint256 private _totalLpSupply;
    uint256 private _totalLpCreditToken;
    uint256 private _totalStaked;

    uint8 private _reserveTokenDecimal;

    FeeState[MAX_FEE_TYPE_COUNT] private _feeStates;

    mapping(address => uint256) private _stakingBalances;
    mapping(address => LpPosition) private _lpPositions;

    constructor() {
        _disableInitializers();
    }

    modifier onlyProtocolFeeOwner() {
        if (msg.sender != _adminContract.feeOwner()) {
            revert Unauthorized();
        }
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is not paused.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    modifier whenNotPaused() {
        require(!_adminContract.paused(), "Pausable: paused");
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is paused.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    modifier whenPaused() {
        require(_adminContract.paused(), "Pausable: paused");
        _;
    }

    /**
     * @notice  Initialize contract
     * @dev
     * @param   adminContract : Admin contract address
     * @param   router : Router contract address
     * @param   inverseTokenContract : Inverse bonding curve token contract address
     * @param   reserveTokenContract : Reserve token contract address
     * @param   reserve : Reserve amount
     */
    function initialize(
        address adminContract,
        address router,
        address inverseTokenContract,
        address reserveTokenContract,
        address recipient,
        uint256 reserve
    ) external initializer {
        if (
            adminContract == address(0) || router == address(0) || inverseTokenContract == address(0)
                || inverseTokenContract == address(0)
        ) revert EmptyAddress();
        __UUPSUpgradeable_init();

        _inverseToken = IInverseBondingCurveToken(inverseTokenContract);
        _reserveToken = IERC20(reserveTokenContract);
        _reserveTokenDecimal = IERC20Metadata(reserveTokenContract).decimals();
        _adminContract = IInverseBondingCurveAdmin(adminContract);
        _router = router;

        _checkPayment(_reserveToken, _reserveBalance, reserve);
        reserve = CurveLibrary.scaleFrom(reserve, _reserveTokenDecimal);
        if (reserve < MIN_INPUT_AMOUNT) revert InputAmountTooSmall(reserve);
        _reserveBalance += reserve;

        _curveReserveBalance = reserve;
        uint256 price = UINT_TWO.divDown(_curveReserveBalance);
        uint256 supply = _curveReserveBalance.mulDown(_curveReserveBalance).divDown(UINT_FOUR);

        uint256 lpTokenAmount = price.mulDown(_curveReserveBalance - (price.mulDown(supply)));

        uint256 tokenToDead = supply.mulDown(INITIAL_RESERVE_DEDUCTION).divDown(_curveReserveBalance);
        uint256 lpToDead = lpTokenAmount.mulDown(INITIAL_RESERVE_DEDUCTION).divDown(_curveReserveBalance);

        _invariant = _curveReserveBalance.divDown(supply.powDown(UTILIZATION));

        CurveLibrary.initializeRewardEMA(_feeStates);

        _updateLpReward(recipient);
        _createLpPosition(lpTokenAmount - lpToDead, supply - tokenToDead, recipient);
        // Burn some liquidity to dead address to avoid empty pool
        _createLpPosition(lpToDead, tokenToDead, DEAD_ADDRESS);

        // emit FeeOwnerChanged(protocolFeeOwner);
        emit CurveInitialized(msg.sender, reserveTokenContract, _curveReserveBalance, supply, price, _invariant);
    }

    /**
     * @notice  Add reserve liquidity to inverse bonding curve
     * @dev     LP will get virtual LP token(non-transferable),
     *          and one account can only hold one LP position(Need to close and reopen if user want to change)
     * @param   recipient : Account to receive LP token
     * @param   priceLimits : [minPriceLimit, maxPriceLimit], if maxPriceLimit = 0, then no limitation for max price
     */
    function addLiquidity(address recipient, uint256 reserveIn, uint256[2] memory priceLimits) external whenNotPaused {
        address sourceAccount = _getSourceAccount(recipient);
        if (_lpBalanceOf(recipient) > 0) revert LpAlreadyExist();

        if (recipient == address(0)) revert EmptyAddress();
        if (!CurveLibrary.valueInRange(_currentPrice(), priceLimits)) {
            revert PriceOutOfLimit(_currentPrice(), priceLimits);
        }

        _checkPayment(_reserveToken, CurveLibrary.scaleTo(_reserveBalance, _reserveTokenDecimal), reserveIn);
        reserveIn = CurveLibrary.scaleFrom(reserveIn, _reserveTokenDecimal);
        if (reserveIn < MIN_INPUT_AMOUNT) revert InputAmountTooSmall(reserveIn);
        _reserveBalance += reserveIn;

        uint256 fee = _calcAndUpdateFee(reserveIn, false, ActionType.ADD_LIQUIDITY, _feeStates[FEE_RESERVE]);
        uint256 reserveAdded = reserveIn - fee;
        (uint256 mintToken, uint256 inverseTokenCredit) = _calcLpAddition(reserveAdded);

        _updateLpReward(recipient);
        _createLpPosition(mintToken, inverseTokenCredit, recipient);
        _increaseReserve(reserveAdded);
        _updateInvariant(_virtualInverseTokenSupply());
        _checkUtilizationNotChanged();

        emit LiquidityAdded(sourceAccount, recipient, reserveIn, mintToken, _invariant);
    }

    /**
     * @notice  Remove reserve liquidity from inverse bonding curve
     * @dev     IBC token may needed to burn LP
     * @param   recipient : Account to receive reserve
     * @param   priceLimits : [minPriceLimit, maxPriceLimit], if maxPriceLimit = 0, then no limitation for max price
     */
    function removeLiquidity(address recipient, uint256 inverseTokenIn, uint256[2] memory priceLimits) external whenNotPaused {
        address sourceAccount = _getSourceAccount(recipient);
        address targetAccount = _getTargetAccount(recipient);
        uint256 burnTokenAmount = _lpBalanceOf(sourceAccount);

        _checkPayment(_inverseToken, _inverseTokenBalance, inverseTokenIn);
        _inverseTokenBalance += inverseTokenIn;

        if (burnTokenAmount == 0) revert LpNotExist();
        if (recipient == address(0)) revert EmptyAddress();
        if (!CurveLibrary.valueInRange(_currentPrice(), priceLimits)) revert PriceOutOfLimit(_currentPrice(), priceLimits);

        _updateLpReward(sourceAccount);
        uint256 inverseTokenCredit = _lpPositions[sourceAccount].inverseTokenCredit;
        (uint256 reserveRemoved, uint256 inverseTokenBurned) = _calcLpRemoval(burnTokenAmount);
        uint256 newSupply = _virtualInverseTokenSupply() - inverseTokenBurned;
        // Remove LP position(LP token and IBC credit) after caclulation
        _removeLpPosition(sourceAccount);
        uint256 fee = _calcAndUpdateFee(reserveRemoved, false, ActionType.REMOVE_LIQUIDITY, _feeStates[FEE_RESERVE]);
        uint256 reserveToUser = reserveRemoved - fee;

        _decreaseReserve(reserveRemoved);
        _updateInvariant(newSupply);

        emit LiquidityRemoved(
            sourceAccount, targetAccount, burnTokenAmount, reserveToUser, inverseTokenCredit, inverseTokenBurned, _invariant
        );

        if (inverseTokenCredit > inverseTokenBurned) {
            uint256 tokenMint = inverseTokenCredit - inverseTokenBurned;
            fee = _calcAndUpdateFee(tokenMint, false, ActionType.REMOVE_LIQUIDITY, _feeStates[FEE_IBC_FROM_LP]);
            _mintInverseToken(targetAccount, tokenMint - fee);
            _mintInverseToken(address(this), fee);
        } else if (inverseTokenCredit < inverseTokenBurned) {
            if (inverseTokenIn < inverseTokenBurned - inverseTokenCredit) revert InsufficientBalance();
            _burnInverseToken(inverseTokenBurned - inverseTokenCredit);
            // Transfer additional token back to user
            _transferInverseToken(targetAccount, inverseTokenIn - (inverseTokenBurned - inverseTokenCredit));
        }

        _checkUtilizationNotChanged();
        _transferReserveToken(targetAccount, reserveToUser);
    }

    // /**
    //  * @notice  Buy IBC token with reserve
    //  * @dev     If exactAmountOut greater than zero, then it will mint exact token to recipient
    //  * @param   recipient : Account to receive IBC token
    //  * @param   exactAmountOut : Exact amount IBC token to mint to user
    //  * @param   maxPriceLimit : Maximum price limit, revert if current price greater than the limit
    //  */
    /**
     * @notice  .
     * @dev     .
     * @param   recipient  .
     * @param   reserveIn  .
     * @param   exactAmountOut  .
     * @param   priceLimits : [minPriceLimit, maxPriceLimit], if maxPriceLimit = 0, then no limitation for max price
     * @param   reserveLimits : [minReserveLimit, maxReserveLimit], if maxReserveLimit = 0, then no limitation for max reserve
     */
    function buyTokens(
        address recipient,
        uint256 reserveIn,
        uint256 exactAmountOut,
        uint256[2] memory priceLimits,
        uint256[2] memory reserveLimits
    ) external whenNotPaused {
        if (recipient == address(0)) revert EmptyAddress();
        if (!CurveLibrary.valueInRange(_reserveBalance, reserveLimits)) revert ReserveOutOfLimit(_reserveBalance, reserveLimits);

        if (exactAmountOut > 0 && exactAmountOut < MIN_INPUT_AMOUNT) revert InputAmountTooSmall(exactAmountOut);
        _checkPayment(_reserveToken, CurveLibrary.scaleTo(_reserveBalance, _reserveTokenDecimal), reserveIn);
        reserveIn = CurveLibrary.scaleFrom(reserveIn, _reserveTokenDecimal);
        if (reserveIn < MIN_INPUT_AMOUNT) revert InputAmountTooSmall(reserveIn);
        _reserveBalance += reserveIn;

        address sourceAccount = _getSourceAccount(recipient);
        address targetAccount = _getTargetAccount(recipient);

        (uint256 totalMint, uint256 tokenToUser, uint256 fee, uint256 reserve) =
            exactAmountOut == 0 ? _calcExacAmountIn(reserveIn) : _calcExacAmountOut(exactAmountOut);
        if (exactAmountOut > 0 && reserveIn < reserve) {
            revert InsufficientBalance();
        }

        _increaseReserve(reserve);
        uint256 price = reserve.divDown(tokenToUser);
        if (!CurveLibrary.valueInRange(price, priceLimits)) revert PriceOutOfLimit(price, priceLimits);

        _checkInvariantNotChanged(_virtualInverseTokenSupply() + totalMint);

        emit TokenBought(sourceAccount, targetAccount, reserve, tokenToUser);

        _mintInverseToken(targetAccount, tokenToUser);
        _mintInverseToken(address(this), fee);

        // Send back additional reserve
        if (reserveIn > reserve) {
            _transferReserveToken(targetAccount, reserveIn - reserve);
        }
    }

    /**
     * @notice  Sell IBC token to get reserve back
     * @dev
     * @param   recipient : Account to receive reserve
     * @param   inverseTokenIn : IBC token amount to sell
     * @param   priceLimits : [minPriceLimit, maxPriceLimit], if maxPriceLimit = 0, then no limitation for max price
     * @param   reserveLimits : [minReserveLimit, maxReserveLimit], if maxReserveLimit = 0, then no limitation for max reserve
     */
    function sellTokens(address recipient, uint256 inverseTokenIn, uint256[2] memory priceLimits, uint256[2] memory reserveLimits)
        external
        whenNotPaused
    {
        if (inverseTokenIn < MIN_INPUT_AMOUNT) revert InputAmountTooSmall(inverseTokenIn);
        if (!CurveLibrary.valueInRange(_reserveBalance, reserveLimits)) {
            revert ReserveOutOfLimit(_reserveBalance, reserveLimits);
        }
        if (recipient == address(0)) revert EmptyAddress();
        address sourceAccount = _getSourceAccount(recipient);
        address targetAccount = _getTargetAccount(recipient);

        _checkPayment(_inverseToken, _inverseTokenBalance, inverseTokenIn);
        _inverseTokenBalance += inverseTokenIn;

        uint256 fee = _calcAndUpdateFee(inverseTokenIn, false, ActionType.SELL_TOKEN, _feeStates[FEE_IBC_FROM_TRADE]);
        uint256 burnToken = inverseTokenIn - fee;

        uint256 returnLiquidity = _calcBurnToken(burnToken);
        _decreaseReserve(returnLiquidity);

        if (!CurveLibrary.valueInRange(returnLiquidity.divDown(burnToken), priceLimits)) {
            revert PriceOutOfLimit(returnLiquidity.divDown(burnToken), priceLimits);
        }

        _checkInvariantNotChanged(_virtualInverseTokenSupply() - burnToken);

        emit TokenSold(sourceAccount, targetAccount, inverseTokenIn, returnLiquidity);

        _burnInverseToken(burnToken);
        _transferReserveToken(targetAccount, returnLiquidity);
    }

    /**
     * @notice  Stake IBC token to get fee reward
     * @dev
     * @param   amount : Token amount to stake
     */
    function stake(address recipient, uint256 amount) external whenNotPaused {
        if (amount < MIN_INPUT_AMOUNT) revert InputAmountTooSmall(amount);
        address sourceAccount = _getSourceAccount(recipient);

        _checkPayment(_inverseToken, _inverseTokenBalance, amount);
        _inverseTokenBalance += amount;

        _updateStakingReward(sourceAccount);

        _rewardFirstStaker(sourceAccount);
        _stakingBalances[sourceAccount] += amount;
        _totalStaked += amount;

        emit TokenStaked(sourceAccount, amount);
    }

    /**
     * @notice  Unstake staked IBC token
     * @dev
     * @param   amount : Token amount to unstake
     */
    function unstake(address recipient, uint256 amount) external whenNotPaused {
        address sourceAccount = _getSourceAccount(recipient);
        if (_stakingBalances[sourceAccount] < amount) revert InsufficientBalance();
        if (amount < MIN_INPUT_AMOUNT) revert InputAmountTooSmall(amount);

        _updateStakingReward(sourceAccount);
        _stakingBalances[sourceAccount] -= amount;
        _totalStaked -= amount;

        emit TokenUnstaked(sourceAccount, amount);
        _transferInverseToken(sourceAccount, amount);
    }

    /**
     * @notice  Claim fee reward
     * @dev
     * @param   recipient : Account to receive fee reward
     */
    function claimReward(address recipient) external whenNotPaused {
        if (recipient == address(0)) revert EmptyAddress();

        address sourceAccount = _getSourceAccount(recipient);
        address targetAccount = _getTargetAccount(recipient);

        _updateLpReward(sourceAccount);
        _updateStakingReward(sourceAccount);

        uint256 inverseTokenReward =
            _claimReward(sourceAccount, _feeStates[FEE_IBC_FROM_TRADE]) + _claimReward(sourceAccount, _feeStates[FEE_IBC_FROM_LP]);
        uint256 reserveReward = _claimReward(sourceAccount, _feeStates[FEE_RESERVE]);

        emit RewardClaimed(sourceAccount, targetAccount, inverseTokenReward, reserveReward);

        _transferInverseToken(targetAccount, inverseTokenReward);
        _transferReserveToken(targetAccount, reserveReward);
    }

    /**
     * @notice  Claim protocol fee reward
     * @dev     Only protocol fee owner allowed
     */
    function claimProtocolReward() external whenNotPaused onlyProtocolFeeOwner {        
        uint256 inverseTokenReward = _feeStates[FEE_IBC_FROM_TRADE].totalPendingReward[REWARD_PROTOCOL]
            + _feeStates[FEE_IBC_FROM_LP].totalPendingReward[REWARD_PROTOCOL]
            + (_inverseToken.balanceOf(address(this)) - _inverseTokenBalance); // Additional token send to contract
        uint256 reserveReward = _feeStates[FEE_RESERVE].totalPendingReward[REWARD_PROTOCOL]
            + (CurveLibrary.scaleFrom(_reserveToken.balanceOf(address(this)), _reserveTokenDecimal)- _reserveBalance);

        _inverseTokenBalance = _inverseToken.balanceOf(address(this));
        _reserveBalance = CurveLibrary.scaleFrom(_reserveToken.balanceOf(address(this)), _reserveTokenDecimal);

        _feeStates[FEE_IBC_FROM_TRADE].totalPendingReward[REWARD_PROTOCOL] = 0;
        _feeStates[FEE_IBC_FROM_LP].totalPendingReward[REWARD_PROTOCOL] = 0;
        _feeStates[FEE_RESERVE].totalPendingReward[REWARD_PROTOCOL] = 0;

        emit RewardClaimed(msg.sender, msg.sender, inverseTokenReward, reserveReward);

        _transferInverseToken(msg.sender, inverseTokenReward);
        _transferReserveToken(msg.sender, reserveReward);
    }

    /**
     * @notice  Query LP position
     * @dev
     * @param   account : Account to query position
     * @return  lpTokenAmount : LP virtual token amount
     * @return  inverseTokenCredit : IBC token credited(Virtual, not able to sell/stake/transfer)
     */
    function liquidityPositionOf(address account) external view returns (uint256 lpTokenAmount, uint256 inverseTokenCredit) {
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
     * @notice  Get IBC token contract address
     * @dev
     * @return  address : IBC token contract address
     */
    function reserveTokenAddress() external view returns (address) {
        return address(_reserveToken);
    }

    /**
     * @notice  Query current inverse bonding curve parameter
     * @dev
     * @return  parameters : See CurveParameter for detail
     */
    function curveParameters() external view returns (CurveParameter memory parameters) {
        uint256 supply = _virtualInverseTokenSupply();
        return CurveParameter(_curveReserveBalance, supply, _totalLpSupply, _currentPrice(), _invariant);
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
        returns (uint256 inverseTokenForLp, uint256 inverseTokenForStaking, uint256 reserveForLp, uint256 reserveForStaking)
    {
        (inverseTokenForLp, inverseTokenForStaking, reserveForLp, reserveForStaking) =
            CurveLibrary.calcPendingReward(recipient, _feeStates, _lpBalanceOf(recipient), _stakingBalances[recipient]);
    }

    /**
     * @notice  Query protocol fee reward
     * @dev
     */
    function rewardOfProtocol() external view returns (uint256 inverseTokenReward, uint256 reserveReward) {
        inverseTokenReward = _feeStates[FEE_IBC_FROM_TRADE].totalPendingReward[REWARD_PROTOCOL]
            + _feeStates[FEE_IBC_FROM_LP].totalPendingReward[REWARD_PROTOCOL];
        reserveReward = _feeStates[FEE_RESERVE].totalPendingReward[REWARD_PROTOCOL];
    }

    /**
     * @notice  Query EMA(exponential moving average) reward per block
     * @dev
     * @param   rewardType : Reward type: LP or staking
     * @return  inverseTokenReward : EMA IBC token reward per block
     * @return  reserveReward : EMA reserve reward per block
     */
    function blockRewardEMA(RewardType rewardType) external view returns (uint256 inverseTokenReward, uint256 reserveReward) {
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
            _feeStates[FEE_IBC_FROM_TRADE].totalReward,
            _feeStates[FEE_IBC_FROM_LP].totalReward,
            _feeStates[FEE_RESERVE].totalReward
        ];
        totalPendingReward = [
            _feeStates[FEE_IBC_FROM_TRADE].totalPendingReward,
            _feeStates[FEE_IBC_FROM_LP].totalPendingReward,
            _feeStates[FEE_RESERVE].totalPendingReward
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
     * @notice  Increase reserve parameter of inverse bonding curve
     * @dev
     * @param   amount : amount to increase
     */

    function _increaseReserve(uint256 amount) private {
        _curveReserveBalance += amount;
    }

    /**
     * @notice  Decrease reserve parameter of inverse bonding curve
     * @dev
     * @param   amount : amount to decrease
     */
    function _decreaseReserve(uint256 amount) private {
        _curveReserveBalance -= amount;
    }

    /**
     * @notice  Transfer reserve to recipient
     * @dev     Revert if transfer fail
     * @param   recipient : Account to transfer reserve to
     * @param   amount : Amount to transfer
     */
    function _transferReserveToken(address recipient, uint256 amount) private {
        if (amount > 0) {
            _reserveBalance -= amount;
            _reserveToken.safeTransfer(recipient, CurveLibrary.scaleTo(amount, _reserveTokenDecimal));
        }
    }

    /**
     * @notice  Update invariant parameter of inverse bonding curve
     * @dev
     * @param   newSupply : Supply parameter to calculate invariant
     */
    function _updateInvariant(uint256 newSupply) private {
        _invariant = _curveReserveBalance.divDown(newSupply.powDown(UTILIZATION));
    }

    /**
     * @notice  Mint inverse token to recipient
     * @dev
     * @param   recipient : Accmount to receive token
     * @param   amount : Token amount
     */
    function _mintInverseToken(address recipient, uint256 amount) private {
        if (recipient == address(this)) {
            _inverseTokenBalance += amount;
        }
        _inverseToken.mint(recipient, amount);
    }

    /**
     * @notice  Burn inverse token
     * @dev
     * @param   amount : Amount to burn
     */
    function _burnInverseToken(uint256 amount) private {
        _inverseTokenBalance -= amount;
        _inverseToken.burn(amount);        
    }

    /**
     * @notice  Transfer inverse token to recipient
     * @dev
     * @param   recipient : Recipient account to receive token
     * @param   amount : Token amount to transfer
     */
    function _transferInverseToken(address recipient, uint256 amount) private {
        if (amount > 0) {
            _inverseTokenBalance -= amount;
            _inverseToken.safeTransfer(recipient, amount);            
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
    function _removeLpPosition(address account) private {
        _totalLpSupply -= _lpPositions[account].lpTokenAmount;
        _totalLpCreditToken -= _lpPositions[account].inverseTokenCredit;
        _lpPositions[account] = LpPosition(0, 0);
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
            feeState.globalFeeIndexes[REWARD_LP] += lpFee.divDown(_totalLpSupply);
            feeState.totalReward[REWARD_LP] += lpFee;
            feeState.totalPendingReward[REWARD_LP] += lpFee;
        } else {
            feeState.totalReward[REWARD_PROTOCOL] += lpFee;
            feeState.totalPendingReward[REWARD_PROTOCOL] += lpFee;
        }

        if (_totalStaked > 0) {
            feeState.globalFeeIndexes[REWARD_STAKE] += stakingFee.divDown(_totalStaked);
        } else {
            feeState.feeForFirstStaker += stakingFee;
        }
        feeState.totalReward[REWARD_STAKE] += stakingFee;
        feeState.totalPendingReward[REWARD_STAKE] += stakingFee;

        feeState.totalPendingReward[REWARD_PROTOCOL] += protocolFee;
        feeState.totalReward[REWARD_PROTOCOL] += protocolFee;

        return lpFee + stakingFee + protocolFee;
    }

    /**
     * @notice  Calculate token need to mint, fee based on input reserve
     * @dev     .
     * @return  totalMint : Total token need to mint
     * @return  tokenToUser : Token amount mint to user
     * @return  fee : Total fee
     * @return  reserve : Reserve needed
     */
    function _calcExacAmountIn(uint256 reserveIn)
        private
        returns (uint256 totalMint, uint256 tokenToUser, uint256 fee, uint256 reserve)
    {
        totalMint = _calcMintToken(reserveIn);
        fee = _calcAndUpdateFee(totalMint, false, ActionType.BUY_TOKEN, _feeStates[FEE_IBC_FROM_TRADE]);
        tokenToUser = totalMint - fee;
        reserve = reserveIn;
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
        fee = _calcAndUpdateFee(amountOut, true, ActionType.BUY_TOKEN, _feeStates[FEE_IBC_FROM_TRADE]);
        tokenToUser = amountOut;
        totalMint = amountOut + fee;
        reserve = (_virtualInverseTokenSupply() + totalMint).divDown(_virtualInverseTokenSupply()).powDown(UTILIZATION).mulDown(
            _curveReserveBalance
        ) - _curveReserveBalance;
    }

    /**
     * @notice  Reward the accumulated reward to first staker
     * @dev
     */
    function _rewardFirstStaker(address account) private {
        if (_totalStaked == 0) {
            _rewardFirstStaker(account, FeeType.IBC_FROM_TRADE);
            _rewardFirstStaker(account, FeeType.IBC_FROM_LP);
            _rewardFirstStaker(account, FeeType.RESERVE);
        }
    }

    /**
     * @notice  Reward first staker for different reward(IBC/ETH)
     * @dev
     * @param   feeType : IBC token or Reserve(ETH)
     */
    function _rewardFirstStaker(address account, FeeType feeType) private {
        FeeState storage state = _feeStates[uint256(feeType)];
        if (state.feeForFirstStaker > 0) {
            state.pendingRewards[REWARD_STAKE][account] = state.feeForFirstStaker;
            state.feeForFirstStaker = 0;
        }
    } 

    /**
     * @notice  Update fee state for claiming reward
     * @dev
     * @param   state : Fee state
     * @return  uint256 : Reward amount to be claimed
     */
    function _claimReward(address account, FeeState storage state) private returns (uint256) {
        uint256 reward = state.pendingRewards[REWARD_LP][account] + state.pendingRewards[REWARD_STAKE][account];
        state.totalPendingReward[REWARD_LP] -= state.pendingRewards[REWARD_LP][account];
        state.totalPendingReward[REWARD_STAKE] -= state.pendingRewards[REWARD_STAKE][account];
        state.pendingRewards[REWARD_LP][account] = 0;
        state.pendingRewards[REWARD_STAKE][account] = 0;

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
        uint256 utilization = _currentPrice().mulDown(_virtualInverseTokenSupply()).divDown(_curveReserveBalance);
        if (CurveLibrary.valueChanged(UTILIZATION, utilization, MAX_UTIL_CHANGE)) revert UtilizationChanged(utilization);
    }

    /**
     * @notice  Check whether utitlization parameter changed(value change percent within range)
     * @dev     Revert if changed
     * @param   inverseTokenSupply : Curve supply to calculate invariant parameter
     */
    function _checkInvariantNotChanged(uint256 inverseTokenSupply) private view {
        uint256 invariant = _curveReserveBalance.divDown(inverseTokenSupply.powDown(UTILIZATION));
        if (CurveLibrary.valueChanged(_invariant, invariant, MAX_INVARIANT_CHANGE)) {
            revert InvariantChanged(_invariant, invariant);
        }
    }

    /**
     * @notice  Check whether user transfer in enough amount of input token
     * @dev     Revert if user doesn't pay enough
     * @param   token : token contract address
     * @param   previousAmount : Balance before function call
     * @param   inputAmount : User specificed input amount
     */
    function _checkPayment(IERC20 token, uint256 previousAmount, uint256 inputAmount) private view {
        if (token.balanceOf(address(this)) - previousAmount < inputAmount) revert InsufficientBalance();
    }

    /**
     * @notice  Get proper source account address to process
     * @dev     When sender is router address, then we will use recipient specified as source LP account
     * @param   recipient : Input recipient
     * @return  address : The source account(LP)
     */
    function _getSourceAccount(address recipient) private view returns (address) {
        return msg.sender != _router ? msg.sender : recipient;
    }

    /**
     * @notice  Get proper target account address
     * @dev     When sender is router address, then we will use router as target token account
     * @param   recipient : Input recipient
     * @return  address : The target account(for token)
     */
    function _getTargetAccount(address recipient) private view returns (address) {
        // Reserve token will be sent to router firstly to unwrap to native token
        return msg.sender == _router ? msg.sender : recipient;
    }

    /**
     * @notice  Calculate result for adding LP
     * @dev
     * @param   reserveAdded : Reserve amount added
     * @return  mintToken : LP virtual token assigned to LP
     * @return  inverseTokenCredit : Virtual IBC token credited to LP
     */
    function _calcLpAddition(uint256 reserveAdded) private view returns (uint256 mintToken, uint256 inverseTokenCredit) {
        mintToken = reserveAdded.mulDown(_totalLpSupply).divDown(_curveReserveBalance);
        inverseTokenCredit = reserveAdded.mulDown(_virtualInverseTokenSupply()).divDown(_curveReserveBalance);
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
        reserveRemoved = burnLpTokenAmount.mulDown(_curveReserveBalance).divDown(_totalLpSupply);
        inverseTokenBurned = burnLpTokenAmount.mulDown(_virtualInverseTokenSupply()).divDown(_totalLpSupply);
        if (reserveRemoved > _curveReserveBalance) revert InsufficientBalance();
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
        (uint256 lpFeePercent, uint256 stakeFeePercent, uint256 protocolFeePercent) = _adminContract.feeConfig(action);
        if (amountAfterFee) {
            uint256 totalFeePercent = lpFeePercent + stakeFeePercent + protocolFeePercent;
            uint256 amountBeforeFee = amount.divDown(UINT_ONE - totalFeePercent);
            uint256 totalFee = amountBeforeFee - amount;
            lpFee = totalFee.mulDown(lpFeePercent).divDown(totalFeePercent);
            stakingFee = totalFee.mulDown(stakeFeePercent).divDown(totalFeePercent);
            protocolFee = totalFee - lpFee - stakingFee;
        } else {
            lpFee = amount.mulDown(lpFeePercent);
            stakingFee = amount.mulDown(stakeFeePercent);
            protocolFee = amount.mulDown(protocolFeePercent);
        }
    }


    /**
     * @notice  Price at current supply
     * @dev
     * @return  uint256 : Price at current supply
     */
    function _currentPrice() private view returns (uint256) {
        return UTILIZATION.mulDown(_curveReserveBalance).divDown(_virtualInverseTokenSupply());
    }

    /**
     * @notice  Calculate IBC token should be minted for input reserve
     * @dev
     * @param   amount : Reserve input
     * @return  uint256 : IBC token should be minted
     */
    function _calcMintToken(uint256 amount) private view returns (uint256) {
        uint256 newBalance = _curveReserveBalance + amount;
        uint256 currentSupply = _virtualInverseTokenSupply();
        uint256 newSupply = newBalance.divDown(_curveReserveBalance).powDown(UTILIZATION_RECIPROCAL).mulDown(currentSupply);

        return newSupply > currentSupply ? newSupply - currentSupply : 0;
    }

    /**
     * @notice  Calculate reserve should be returned for input IBC token
     * @dev
     * @param   amount : IBC token amount input
     * @return  uint256 : Reserve should returned
     */
    function _calcBurnToken(uint256 amount) private view returns (uint256) {
        uint256 currentSupply = _virtualInverseTokenSupply();
        uint256 newReserve = ((currentSupply - amount).divUp(currentSupply)).powUp(UTILIZATION).mulUp(_curveReserveBalance);

        return _curveReserveBalance > newReserve ? _curveReserveBalance - newReserve : 0;
    }

    /**
     * @notice  Total IBC amount for curve calculation
     * @dev     Include virtual supply and token credited to LP
     * @return  uint256 : Total IBC amount
     */
    function _virtualInverseTokenSupply() private view returns (uint256) {
        return _inverseToken.totalSupply() + _totalLpCreditToken;
    }

    /**
     * @notice  For contract upgrade
     * @dev     _authorizeUpgrade is diabled so this contract is not upgradable, the implementation can only be upgraded through admin contract
     * @param   newImplementation : New contract implementation
     */
    function _authorizeUpgrade(address newImplementation) internal pure override {
        revert();
    }
    // ============================================================================================
}
