// SPDX-License-Identifier: GPL-3.0-only
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

import "./interface/IInverseBondingCurveAdmin.sol";

/**
 * @title   Inverse bonding curve implementation contract
 * @dev
 * @notice
 */
contract InverseBondingCurve is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    // PausableUpgradeable,
    IInverseBondingCurve
{
    using FixedPoint for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IInverseBondingCurveToken;

    /// STATE VARIABLES ///
    address private _protocolFeeOwner;

    // swap/LP fee percent = _lpFeePercent + _stakingFeePercent + _protocolFeePercent
    // uint256[MAX_ACTION_COUNT] private _lpFeePercent;
    // uint256[MAX_ACTION_COUNT] private _stakingFeePercent;
    // uint256[MAX_ACTION_COUNT] private _protocolFeePercent;

    IInverseBondingCurveToken private _inverseToken;
    IERC20 private _reserveToken;
    IInverseBondingCurveAdmin _adminContract;
    address _router;

    uint256 private _parameterInvariant;
    uint256 private _parameterUtilization;
    uint256 private _curveReserveBalance;

    // Used to ensure enough token transfered to curve
    uint256 private _reserveBalance;
    uint256 private _inverseTokenBalance;

    //TODO: should add process for ERC20 token decimals

    uint256 private _totalLpSupply;
    uint256 private _totalLpCreditToken;
    uint256 private _totalStaked;

    FeeState[MAX_FEE_TYPE_COUNT] private _feeStates;

    mapping(address => uint256) private _stakingBalances;
    mapping(address => LpPosition) private _lpPositions;

    constructor() {
        _disableInitializers();
    }

    modifier onlyProtocolFeeOwner() {
        if(msg.sender == _adminContract.feeOwner()){
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
        require(_adminContract.paused(), "Pausable: paused");
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

    // /**
    //  * @notice  Initialize contract
    //  * @dev
    //  * @param   supply : Initial reserve
    //  * @param   supply : Initial supply
    //  * @param   price : Initial IBC token price
    //  * @param   inverseTokenContractAddress : IBC token contract address
    //  * @param   reserveTokenAddress : Reserve token address
    //  * @param   protocolFeeOwner : Fee owner for the reward to protocol
    //  */
    // function initialize(uint256 reserve, uint256 supply, uint256 price, address inverseTokenContractAddress, address reserveTokenAddress, address protocolFeeOwner)
    //     external
    //     initializer
    // {
    //     if (reserve == 0 || supply == 0 || price == 0) revert ParameterZeroNotAllowed();
    //     if (inverseTokenContractAddress == address(0) || protocolFeeOwner == address(0)) revert EmptyAddress();

    //     __Pausable_init();
    //     __Ownable_init();
    //     __UUPSUpgradeable_init();

    //     _intialFeeConfig();

    //     _inverseToken = IInverseBondingCurveToken(inverseTokenContractAddress);
    //     _reserveToken = IERC20(reserveTokenAddress);
    //     _protocolFeeOwner = protocolFeeOwner;
    //     _curveReserveBalance = reserve;
    //     uint256 lpTokenAmount = price.mulDown(_curveReserveBalance - (price.mulDown(supply)));

    //     _parameterUtilization = price.mulDown(supply).divDown(_curveReserveBalance);
    //     if (_parameterUtilization >= ONE_UINT) {
    //         revert UtilizationInvalid(_parameterUtilization);
    //     }
    //     _parameterInvariant = _curveReserveBalance.divDown(supply.powDown(_parameterUtilization));

      

    //     CurveLibrary.initializeRewardEMA(_feeStates);

    //     _updateLpReward(protocolFeeOwner);
    //     _createLpPosition(lpTokenAmount, supply, protocolFeeOwner);

    //     emit FeeOwnerChanged(protocolFeeOwner);
    //     emit CurveInitialized(msg.sender, _curveReserveBalance, supply, price, _parameterUtilization, _parameterInvariant);

    //     _reserveToken.safeTransferFrom(token, from, to, value);
    // }

    // /**
    //  * @notice  Initialize contract
    //  * @dev
    //  * @param   supply : Initial reserve
    //  * @param   supply : Initial supply
    //  * @param   price : Initial IBC token price
    //  * @param   inverseTokenContractAddress : IBC token contract address
    //  * @param   reserveTokenAddress : Reserve token address
    //  * @param   protocolFeeOwner : Fee owner for the reward to protocol
    //  */
    /**
     * @notice  .
     * @dev     .
     * @param   adminContract  .
     * @param   router  .
     * @param   inverseTokenContractAddress  .
     * @param   reserveTokenAddress  .
     * @param   reserve  .
     * @param   supply  .
     * @param   price  .
     */
    function initialize(address adminContract, address router, address inverseTokenContractAddress, address reserveTokenAddress, uint256 reserve, uint256 supply, uint256 price)
        external
        initializer
    {
        if (reserve == 0 || supply == 0 || price == 0) revert ParameterZeroNotAllowed();
        if (inverseTokenContractAddress == address(0)) revert EmptyAddress();        

        // __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();

        // _intialFeeConfig();

        _inverseToken = IInverseBondingCurveToken(inverseTokenContractAddress);
        _reserveToken = IERC20(reserveTokenAddress);
        _adminContract = IInverseBondingCurveAdmin(adminContract);
        _router = router;
        
        _curveReserveBalance = reserve;
        uint256 lpTokenAmount = price.mulDown(_curveReserveBalance - (price.mulDown(supply)));

        _parameterUtilization = price.mulDown(supply).divDown(_curveReserveBalance);
        if (_parameterUtilization >= ONE_UINT) {
            revert UtilizationInvalid(_parameterUtilization);
        }
        _parameterInvariant = _curveReserveBalance.divDown(supply.powDown(_parameterUtilization));

        _reserveBalance = _checkPayment(_reserveToken, _reserveBalance, reserve);

        CurveLibrary.initializeRewardEMA(_feeStates);

        address protocolFeeOwner = _adminContract.feeOwner();
        _updateLpReward(protocolFeeOwner);
        _createLpPosition(lpTokenAmount, supply, protocolFeeOwner);

        // emit FeeOwnerChanged(protocolFeeOwner);
        emit CurveInitialized(msg.sender, _curveReserveBalance, supply, price, _parameterUtilization, _parameterInvariant);
    }

    // /**
    //  * @notice  Update fee config
    //  * @dev
    //  * @param   actionType : Fee configuration for : Buy/Sell/Add liquidity/Remove liquidity)
    //  * @param   lpFee : The percent of fee reward to LP
    //  * @param   stakingFee : The percent of fee reward to staker
    //  * @param   protocolFee : The percent of fee reward to protocol
    //  */
    // function updateFeeConfig(ActionType actionType, uint256 lpFee, uint256 stakingFee, uint256 protocolFee)
    //     external
    //     onlyOwner
    // {
    //     if ((lpFee + stakingFee + protocolFee) >= MAX_FEE_PERCENT) revert FeePercentOutOfRange();
    //     if (uint256(actionType) >= MAX_ACTION_COUNT) revert InvalidInput();

    //     _lpFeePercent[uint256(actionType)] = lpFee;
    //     _stakingFeePercent[uint256(actionType)] = stakingFee;
    //     _protocolFeePercent[uint256(actionType)] = protocolFee;

    //     emit FeeConfigChanged(actionType, lpFee, stakingFee, protocolFee);
    // }

    // /**
    //  * @notice  Update protocol fee owner
    //  * @dev
    //  * @param   protocolFeeOwner : The new owner of protocol fee
    //  */
    // function updateFeeOwner(address protocolFeeOwner) public onlyOwner {
    //     if (protocolFeeOwner == address(0)) revert EmptyAddress();

    //     _protocolFeeOwner = protocolFeeOwner;

    //     emit FeeOwnerChanged(protocolFeeOwner);
    // }

    /**
     * @notice  Pause contract
     * @dev     Not able to buy/sell/add liquidity/remove liquidity/transfer token
     */
    // function pause() external onlyOwner {
    //     _pause();
    //     _inverseToken.pause();
    // }

    /**
     * @notice  Unpause contract
     * @dev
     */
    // function unpause() external onlyOwner {
    //     _unpause();
    //     _inverseToken.unpause();
    // }

    /**
     * @notice  Add reserve liquidity to inverse bonding curve
     * @dev     LP will get virtual LP token(non-transferable),
     *          and one account can only hold one LP position(Need to close and reopen if user want to change)
     * @param   recipient : Account to receive LP token
     * @param   minPriceLimit : Minimum price limit, revert if current price less than the limit
     */
    function addLiquidity(address recipient, uint256 reserveIn, uint256 minPriceLimit) external whenNotPaused {
        address sourceAccount = _getSourceAccount(recipient);
        if (_lpBalanceOf(recipient) > 0) revert LpAlreadyExist();
        if (reserveIn < MIN_INPUT_AMOUNT) revert InputAmountTooSmall(reserveIn);
        if (recipient == address(0)) revert EmptyAddress();
        if (_currentPrice() < minPriceLimit) revert PriceOutOfLimit(_currentPrice(), minPriceLimit);

        _reserveBalance = _checkPayment(_reserveToken, _reserveBalance, reserveIn);
        // _reserveBalance += reserveIn;
        uint256 fee =
            _calcAndUpdateFee(reserveIn, false, ActionType.ADD_LIQUIDITY, _feeStates[uint256(FeeType.RESERVE)]);
        uint256 reserveAdded = reserveIn - fee;
        (uint256 mintToken, uint256 inverseTokenCredit) = _calcLpAddition(reserveAdded);

        _updateLpReward(recipient);
        _createLpPosition(mintToken, inverseTokenCredit, recipient);
        _increaseReserve(reserveAdded);
        _updateInvariant(_virtualInverseTokenTotalSupply());
        _checkUtilizationNotChanged();

        emit LiquidityAdded(sourceAccount, recipient, reserveIn, mintToken, _parameterUtilization, _parameterInvariant);
    }

    function _getSourceAccount(address recipient) private view returns (address){
        return msg.sender != _router? msg.sender : recipient;
    }

    /**
     * @notice  Remove reserve liquidity from inverse bonding curve
     * @dev     IBC token may needed to burn LP
     * @param   recipient : Account to receive reserve
     * @param   maxPriceLimit : Maximum price limit, revert if current price greater than the limit
     */
    function removeLiquidity(address recipient, uint256 inverseTokenIn, uint256 maxPriceLimit) external whenNotPaused {
        address sourceAccount = _getSourceAccount(recipient);
        uint256 burnTokenAmount = _lpBalanceOf(sourceAccount);

        _inverseTokenBalance = _checkPayment(_inverseToken, _inverseTokenBalance, inverseTokenIn);

        if (burnTokenAmount == 0) revert LpNotExist();
        if (recipient == address(0)) revert EmptyAddress();
        if (_currentPrice() > maxPriceLimit) revert PriceOutOfLimit(_currentPrice(), maxPriceLimit);   

        _updateLpReward(sourceAccount);
        uint256 inverseTokenCredit = _lpPositions[sourceAccount].inverseTokenCredit;
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
            sourceAccount,
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
            _mintInverseToken(recipient, tokenMint - fee);
            _mintInverseToken(address(this), fee);
            // _inverseToken.mint(recipient, tokenMint - fee);
            // _inverseToken.mint(address(this), fee);
        } else if (inverseTokenCredit < inverseTokenBurned) {
            if(inverseTokenIn < inverseTokenBurned - inverseTokenCredit){
                revert InsufficientBalance();
            }
            _burnInverseToken(inverseTokenBurned - inverseTokenCredit);
            // _inverseToken.burn(inverseTokenBurned - inverseTokenCredit);
            // Transfer additional token back to user
            _transferInverseToken(recipient, inverseTokenIn - (inverseTokenBurned - inverseTokenCredit));
            _inverseToken.safeTransfer(recipient, inverseTokenIn - (inverseTokenBurned - inverseTokenCredit));
        }

        _checkUtilizationNotChanged();
        _transferReserveToken(recipient, reserveToUser);
    }

    function _mintInverseToken(address recipient, uint256 amount) private {
        _inverseToken.mint(recipient, amount);
        if(recipient == address(this)){
            _inverseTokenBalance += amount;
        }
    }

    function _burnInverseToken(uint256 amount) private {
        _inverseToken.burn(amount);
        _inverseTokenBalance -= amount;
    }

    function _transferInverseToken(address recipient,uint256 amount) private {
        _inverseToken.safeTransfer(recipient, amount);
        _inverseTokenBalance -= amount;
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
     * @param   maxPriceLimit  .
     */
    function buyTokens(address recipient, uint256 reserveIn, uint256 exactAmountOut, uint256 maxPriceLimit)
        external
        payable
        whenNotPaused
    {
        if (recipient == address(0)) revert EmptyAddress();
        if (reserveIn < MIN_INPUT_AMOUNT) revert InputAmountTooSmall(reserveIn);
        if (exactAmountOut > 0 && exactAmountOut < MIN_INPUT_AMOUNT) revert InputAmountTooSmall(exactAmountOut);
        _reserveBalance = _checkPayment(_reserveToken, _reserveBalance, reserveIn);
        address sourceAccount = _getSourceAccount(recipient);

        (uint256 totalMint, uint256 tokenToUser, uint256 fee, uint256 reserve) =
            exactAmountOut == 0 ? _calcExacAmountIn() : _calcExacAmountOut(exactAmountOut);
        if (exactAmountOut > 0 && reserveIn < reserve) {
            revert InsufficientBalance();
        }

        _increaseReserve(reserve);

        if (reserve.divDown(tokenToUser) > maxPriceLimit) {
            revert PriceOutOfLimit(reserve.divDown(tokenToUser), maxPriceLimit);
        }

        _checkInvariantNotChanged(_virtualInverseTokenTotalSupply() + totalMint);

        emit TokenBought(sourceAccount, recipient, reserve, tokenToUser);

        _mintInverseToken(recipient, tokenToUser);
        _mintInverseToken(address(this), fee);
        // _inverseToken.mint(recipient, tokenToUser);
        // _inverseToken.mint(address(this), fee);

        // Send back additional reserve
        if (reserveIn > reserve) {
            _transferReserveToken(recipient, reserveIn - reserve);
        }
    }

    /**
     * @notice  Sell IBC token to get reserve back
     * @dev
     * @param   recipient : Account to receive reserve
     * @param   inverseTokenIn : IBC token amount to sell
     * @param   minPriceLimit : Minimum price limit, revert if current price less than the limit
     */
    function sellTokens(address recipient, uint256 inverseTokenIn, uint256 minPriceLimit) external whenNotPaused {
        // if (_inverseToken.balanceOf(msg.sender) < amount) revert InsufficientBalance();
        if (inverseTokenIn < MIN_INPUT_AMOUNT) revert InputAmountTooSmall(inverseTokenIn);
        if (recipient == address(0)) revert EmptyAddress();
        address sourceAccount = _getSourceAccount(recipient);

        _inverseTokenBalance = _checkPayment(_inverseToken, _inverseTokenBalance, inverseTokenIn);

        uint256 fee =
            _calcAndUpdateFee(inverseTokenIn, false, ActionType.SELL_TOKEN, _feeStates[uint256(FeeType.IBC_FROM_TRADE)]);
        uint256 burnToken = inverseTokenIn - fee;

        uint256 returnLiquidity = _calcBurnToken(burnToken);
        _decreaseReserve(returnLiquidity);

        if (returnLiquidity.divDown(burnToken) < minPriceLimit) {
            revert PriceOutOfLimit(returnLiquidity.divDown(burnToken), minPriceLimit);
        }

        _checkInvariantNotChanged(_virtualInverseTokenTotalSupply() - burnToken);

        emit TokenSold(sourceAccount, recipient, inverseTokenIn, returnLiquidity);

        _burnInverseToken(burnToken);
        // _transferInverseToken(amount);
        // _inverseToken.burnFrom(msg.sender, burnToken);
        // IERC20(_inverseToken).safeTransferFrom(msg.sender, address(this), fee);
        _transferReserveToken(recipient, returnLiquidity);
    }

    /**
     * @notice  Stake IBC token to get fee reward
     * @dev
     * @param   amount : Token amount to stake
     */
    function stake(address recipient, uint256 amount) external whenNotPaused {
        if (amount < MIN_INPUT_AMOUNT) revert InputAmountTooSmall(amount);
        address sourceAccount = _getSourceAccount(recipient);

        _inverseTokenBalance = _checkPayment(_inverseToken, _inverseTokenBalance, amount);

        // if (_inverseToken.balanceOf(msg.sender) < amount) revert InsufficientBalance();

        _updateStakingReward(sourceAccount);

        _rewardFirstStaker();
        _stakingBalances[sourceAccount] += amount;
        _totalStaked += amount;

        emit TokenStaked(sourceAccount, amount);

        // IERC20(_inverseToken).safeTransferFrom(msg.sender, address(this), amount);
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
        // IERC20(_inverseToken).safeTransfer(msg.sender, amount);
    }

    /**
     * @notice  Claim fee reward
     * @dev
     * @param   recipient : Account to receive fee reward
     */
    function claimReward(address recipient) external whenNotPaused {
        if (recipient == address(0)) revert EmptyAddress();

        address sourceAccount = _getSourceAccount(recipient);

        _updateLpReward(sourceAccount);
        _updateStakingReward(sourceAccount);

        uint256 inverseTokenReward = _claimReward(sourceAccount, _feeStates[uint256(FeeType.IBC_FROM_TRADE)])
            + _claimReward(sourceAccount, _feeStates[uint256(FeeType.IBC_FROM_LP)]);
        uint256 reserveReward = _claimReward(sourceAccount, _feeStates[uint256(FeeType.RESERVE)]);

        emit RewardClaimed(sourceAccount, recipient, inverseTokenReward, reserveReward);

        // if (inverseTokenReward > 0) {
        //     IERC20(_inverseToken).safeTransfer(recipient, inverseTokenReward);
        // }
        _transferInverseToken(recipient, inverseTokenReward);

        _transferReserveToken(recipient, reserveReward);
    }

    /**
     * @notice  Claim protocol fee reward
     * @dev     Only protocol fee owner allowed
     */
    function claimProtocolReward() external whenNotPaused onlyProtocolFeeOwner {
        // if (msg.sender != _protocolFeeOwner) revert Unauthorized();


        uint256 inverseTokenReward = _feeStates[uint256(FeeType.IBC_FROM_TRADE)].totalPendingReward[uint256(
            RewardType.PROTOCOL
        )] + _feeStates[uint256(FeeType.IBC_FROM_LP)].totalPendingReward[uint256(RewardType.PROTOCOL)] +
        (_inverseToken.balanceOf(address(this)) - _inverseTokenBalance); // Additional token send to contract
        uint256 reserveReward = _feeStates[uint256(FeeType.RESERVE)].totalPendingReward[uint256(RewardType.PROTOCOL)] +
        (_reserveToken.balanceOf(address(this)) - _reserveBalance);

        _inverseTokenBalance = _inverseToken.balanceOf(address(this));
        _reserveBalance = _reserveToken.balanceOf(address(this));

        _feeStates[uint256(FeeType.IBC_FROM_TRADE)].totalPendingReward[uint256(RewardType.PROTOCOL)] = 0;
        _feeStates[uint256(FeeType.IBC_FROM_LP)].totalPendingReward[uint256(RewardType.PROTOCOL)] = 0;
        _feeStates[uint256(FeeType.RESERVE)].totalPendingReward[uint256(RewardType.PROTOCOL)] = 0;

        emit RewardClaimed(msg.sender, msg.sender, inverseTokenReward, reserveReward);

        if (inverseTokenReward > 0) {
            IERC20(_inverseToken).safeTransfer(msg.sender, inverseTokenReward);
        }

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
            _curveReserveBalance, supply, _totalLpSupply, _currentPrice(), _parameterInvariant, _parameterUtilization
        );
    }



    // /**
    //  * @notice  Query protocol fee owner
    //  * @dev
    //  * @return  address : protocol fee owner
    //  */
    // function feeOwner() external view returns (address) {
    //     return _protocolFeeOwner;
    // }

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
            // (bool sent,) = recipient.call{value: amount}("");
            // if (!sent) {
            //     revert FailToSend(recipient);
            // }
            _reserveBalance -= amount;
            _reserveToken.safeTransfer(recipient, amount);
        }
    }

    /**
     * @notice  Update invariant parameter of inverse bonding curve
     * @dev
     * @param   newSupply : Supply parameter to calculate invariant
     */
    function _updateInvariant(uint256 newSupply) private {
        _parameterInvariant = _curveReserveBalance.divDown(newSupply.powDown(_parameterUtilization));
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
            _currentPrice().mulDown(_virtualInverseTokenTotalSupply()).divDown(_curveReserveBalance);
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
        uint256 newInvariant = _curveReserveBalance.divDown(inverseTokenSupply.powDown(_parameterUtilization));
        if (CurveLibrary.isValueChanged(_parameterInvariant, newInvariant, ALLOWED_INVARIANT_CHANGE_PERCENT)) {
            revert InvariantChanged(_parameterInvariant, newInvariant);
        }
    }

    function _checkPayment(IERC20 token, uint256 previousAmount, uint256 inputAmount) private view returns (uint256){
        uint256 currentBalance = token.balanceOf(address(this));
        if(currentBalance - previousAmount < inputAmount){
            revert InsufficientBalance();
        }
        return previousAmount + inputAmount;
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
        mintToken = reserveAdded.mulDown(_totalLpSupply).divDown(_curveReserveBalance);
        inverseTokenCredit = reserveAdded.mulDown(_virtualInverseTokenTotalSupply()).divDown(_curveReserveBalance);
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
        inverseTokenBurned = burnLpTokenAmount.mulDown(_virtualInverseTokenTotalSupply()).divDown(_totalLpSupply);
        if (reserveRemoved > _curveReserveBalance) {
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
        (uint256 lpFeePercent, uint256 stakeFeePercent, uint256 protocolFeePercent) = _adminContract.feeConfig(action);
        if (amountAfterFee) {
            uint256 totalFeePercent = lpFeePercent + stakeFeePercent + protocolFeePercent;
            uint256 amountBeforeFee = amount.divDown(ONE_UINT - totalFeePercent);
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
        ).mulDown(_curveReserveBalance) - _curveReserveBalance;
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
        return _parameterUtilization.mulDown(_curveReserveBalance).divDown(_virtualInverseTokenTotalSupply());
    }

    /**
     * @notice  Calculate IBC token should be minted for input reserve
     * @dev
     * @param   amount : Reserve input
     * @return  uint256 : IBC token should be minted
     */
    function _calcMintToken(uint256 amount) private view returns (uint256) {
        uint256 newBalance = _curveReserveBalance + amount;
        uint256 currentSupply = _virtualInverseTokenTotalSupply();
        uint256 newSupply =
            newBalance.divDown(_curveReserveBalance).powDown(ONE_UINT.divDown(_parameterUtilization)).mulDown(currentSupply);

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
            ((currentSupply - amount).divUp(currentSupply)).powUp(_parameterUtilization).mulUp(_curveReserveBalance);

        return _curveReserveBalance > newReserve ? _curveReserveBalance - newReserve : 0;
    }

    /**
     * @notice  Update fee state for claiming reward
     * @dev
     * @param   state : Fee state
     * @return  uint256 : Reward amount to be claimed
     */
    function _claimReward(address account, FeeState storage state) private returns (uint256) {
        uint256 reward = state.pendingRewards[uint256(RewardType.LP)][account]
            + state.pendingRewards[uint256(RewardType.STAKING)][account];
        state.totalPendingReward[uint256(RewardType.LP)] -= state.pendingRewards[uint256(RewardType.LP)][account];
        state.totalPendingReward[uint256(RewardType.STAKING)] -=
            state.pendingRewards[uint256(RewardType.STAKING)][account];
        state.pendingRewards[uint256(RewardType.LP)][account] = 0;
        state.pendingRewards[uint256(RewardType.STAKING)][account] = 0;

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
