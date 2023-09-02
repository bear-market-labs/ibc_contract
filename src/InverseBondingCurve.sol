// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "openzeppelin/token/ERC20/ERC20.sol";
import "openzeppelin/token/ERC20/IERC20.sol";
import "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin/utils/Strings.sol";
import "openzeppelin/utils/math/SignedMath.sol";
import "openzeppelin/security/ReentrancyGuard.sol";
import "openzeppelin/access/Ownable.sol";

import "./interface/IInverseBondingCurve.sol";
import "./InverseBondingCurveToken.sol";
import "./lib/balancer/FixedPoint.sol";
import "./Constants.sol";
import "./Errors.sol";
import "./CurveParameter.sol";


contract InverseBondingCurve is IInverseBondingCurve, ERC20, Ownable {
    using FixedPoint for uint256;
    using SignedMath for int256;
    using SafeERC20 for IERC20;
    /// ERRORS ///

    /// EVENTS ///

    event LiquidityAdded(
        address indexed from,
        address indexed recipient,
        uint256 amountIn,
        uint256 amountOut,        
        int256 newParameterK,
        uint256 newParameterM
    );
    event LiquidityRemoved(
        address indexed from,
        address indexed recipient,
        uint256 amountIn,
        uint256 amountOut, 
        int256 newParameterK,
        uint256 newParameterM
    );

    event TokenBought(
        address indexed from,
        address indexed recipient,
        uint256 amountIn,
        uint256 amountOut
    );

    event TokenSold(
        address indexed from,
        address indexed recipient,
        uint256 amountIn,
        uint256 amountOut
    );

    event RewardClaimed(
        address indexed from,
        address indexed recipient,
        uint256 amount
    );

    /// STATE VARIABLES ///
    int256 private _parameterK;
    uint256 private _parameterM;
    bool private _isInitialized;
    uint256 private _globalIndex;
    uint256 private _feePercent; 

    InverseBondingCurveToken private immutable _inverseToken;
    mapping(address => uint256) private _userState;
    mapping(address => uint256) private _userPendingReward;

    /// MODIFIERS ///

    modifier onlyInitialized() {
        require(_isInitialized, ERR_POOL_NOT_INITIALIZED);
        _;
    }

    ///
    /// CONSTRUCTOR
    ///

    /// @notice Pool contract constructor
    /// @dev ETH should be wrapped to WETH
    constructor() ERC20("IBCLP", "IBCLP") {
        _inverseToken = new InverseBondingCurveToken(
            address(this),
            "IBC",
            "IBC"
        );

        _feePercent = FEE_PERCENT;
    }

    function setupFeePercent(uint256 feePercent) external onlyOwner {
        require(feePercent > 1e14 && feePercent < 5e17, ERR_FEE_PERCENT_OUT_OF_RANGE);
        _feePercent = feePercent;
    }

    function initialize(uint256 supply, uint256 price) external payable onlyOwner {
        require(msg.value >= MIN_LIQUIDITY, ERR_LIQUIDITY_TOO_SMALL);
        require(supply > 0 && price > 0, ERR_PARAM_ZERO);
        _isInitialized = true;


        _parameterK = ONE_INT - int256(supply.mulDown(price).divDown(msg.value));
        require(_parameterK < ONE_INT, ERR_PARAM_UPDATE_FAIL);
        _parameterM = price.mulDown(supply.pow(_parameterK));

        _updateReward(msg.sender);
        // mint LP token
        _mint(msg.sender, msg.value);
        // mint IBC token
        _inverseToken.mint(msg.sender, supply);

        emit LiquidityAdded(msg.sender, msg.sender, msg.value, supply, _parameterK, _parameterM);
    }


    function addLiquidity(address recipient, uint256 minPriceLimit) external payable onlyInitialized{
        require(msg.value > MIN_LIQUIDITY, ERR_LIQUIDITY_TOO_SMALL);
        require(recipient != address(0), ERR_EMPTY_ADDRESS);

        
        uint256 currentIbcSupply = _inverseToken.totalSupply();
        uint256 currentPrice = getPrice(currentIbcSupply);
        require(currentPrice >= minPriceLimit, ERR_PRICE_OUT_OF_LIMIT); 

        uint256 currentBalance = address(this).balance;
        uint256 mintToken = totalSupply().mulDown(msg.value).divDown(currentBalance.sub(msg.value));

        _updateReward(recipient);
        _mint(recipient, mintToken);
        _parameterK = ONE_INT - int256((currentPrice.mulDown(currentIbcSupply)).divDown(currentBalance));
        require(_parameterK < ONE_INT, ERR_PARAM_UPDATE_FAIL);
        _parameterM = currentPrice.mulDown(currentIbcSupply.pow(_parameterK));

        emit LiquidityAdded(msg.sender, recipient, msg.value, mintToken, _parameterK, _parameterM);
    }

    function removeLiquidity(address recipient, uint256 amount, uint256 maxPriceLimit) external onlyInitialized {
        require(balanceOf(msg.sender) >= amount, ERR_INSUFFICIENT_BALANCE);
        require(recipient != address(0), ERR_EMPTY_ADDRESS);

        uint256 currentIbcSupply = _inverseToken.totalSupply();
        uint256 currentPrice = getPrice(currentIbcSupply);
        require(currentPrice <= maxPriceLimit, ERR_PRICE_OUT_OF_LIMIT); 
        
        uint256 currentBalance = address(this).balance;
        uint256 returnLiquidity = amount.mulDown(currentBalance).divDown(totalSupply());

        _updateReward(msg.sender);
        _burn(msg.sender, amount);
        (bool sent, ) = recipient.call{value: returnLiquidity}("");
        require(sent, "Failed to send Ether");

        currentBalance = address(this).balance;
        _parameterK = ONE_INT - int256((currentPrice.mulDown(currentIbcSupply)).divDown(currentBalance));
        require(_parameterK < ONE_INT, ERR_PARAM_UPDATE_FAIL);
        _parameterM = currentPrice.mulDown(currentIbcSupply.pow(_parameterK));

        emit LiquidityRemoved(msg.sender, recipient, amount, returnLiquidity, _parameterK, _parameterM);
    }


    function buyTokens(address recipient, uint256 maxPriceLimit) external payable onlyInitialized {
        require(recipient != address(0), ERR_EMPTY_ADDRESS);
        require(msg.value > MIN_LIQUIDITY, ERR_LIQUIDITY_TOO_SMALL);

        uint256 newSupply = getSupplyFromLiquidity(address(this).balance);
        uint256 newToken = newSupply - _inverseToken.totalSupply();
        uint256 fee = newToken.mulDown(_feePercent);
        uint256 mintToken = newToken.sub(fee);
        require(msg.value.divDown(mintToken) <= maxPriceLimit, ERR_PRICE_OUT_OF_LIMIT);

        _globalIndex += fee.divDown(totalSupply());
        _inverseToken.mint(recipient, mintToken);
        _inverseToken.mint(address(this), fee);

        emit TokenBought(msg.sender, recipient, msg.value, mintToken);
    }


    function sellTokens(address recipient, uint256 amount, uint256 minPriceLimit) external onlyInitialized {
        require(_inverseToken.balanceOf(msg.sender) >= amount, ERR_INSUFFICIENT_BALANCE);
        require(amount >= MIN_SUPPLY, ERR_LIQUIDITY_TOO_SMALL);
        require(recipient != address(0), ERR_EMPTY_ADDRESS);

        uint256 fee = amount.mulDown(_feePercent);
        uint256 burnToken = amount.sub(fee);
        uint256 newLiquidity = getLiquidityFromSupply(_inverseToken.totalSupply().sub(burnToken));
        uint returnLiquidity = address(this).balance - newLiquidity;

        require(returnLiquidity.divDown(burnToken) >= minPriceLimit, ERR_PRICE_OUT_OF_LIMIT);

        // Change state
        _globalIndex += fee.divDown(totalSupply());
        _inverseToken.burnFrom(msg.sender, burnToken);
        _inverseToken.transferFrom(msg.sender, address(this), fee);

        (bool sent, ) = recipient.call{value: returnLiquidity}("");
        require(sent, "Failed to send Ether");

        emit TokenSold(msg.sender, recipient, amount, returnLiquidity);
    }

    function claimReward(address recipient) external onlyInitialized {
        require(recipient != address(0), ERR_EMPTY_ADDRESS);
        _updateReward(msg.sender);

        if(_userPendingReward[msg.sender] > 0){
            uint256 amount = _userPendingReward[msg.sender];
            _userPendingReward[msg.sender] = 0;
            // _userState[msg.sender] = 0;
            _inverseToken.transfer(recipient, amount);

            emit RewardClaimed(msg.sender, recipient, amount);
        }
    }
    function getPrice(uint256 supply) public view onlyInitialized returns(uint256) {
        return _parameterM.divDown(supply.pow(_parameterK));
    }

    function getLiquidityFromSupply(uint256 supply) public view onlyInitialized returns(uint256){
        uint256 oneMinusK = uint256(ONE_INT - _parameterK);
        return _parameterM.mulDown(supply.powDown(oneMinusK)).divDown(oneMinusK);
    }

    function getSupplyFromLiquidity(uint256 liquidity) public view onlyInitialized returns(uint256){
        uint256 oneMinusK = uint256(ONE_INT - _parameterK);

        return liquidity.mulDown(oneMinusK).divDown(_parameterM).powDown(ONE_UINT.divDown(oneMinusK));
    }

    function getInverseTokenAddress() external view returns(address){
        return address(_inverseToken);
    }

    function getCurveParameters() external view returns(CurveParameter memory parameters){
        uint256 supply = _inverseToken.totalSupply();
        return CurveParameter(
            address(this).balance,
            supply,
            getPrice(supply),
            _parameterK, 
            _parameterM);
    }

    function getFeePercent() external view returns(uint256){
        return _feePercent;
    }

    function getReward(address recipient) external view returns(uint256){
        uint256 reward = 0;
        uint256 userLpBalance = balanceOf(recipient);
        if(userLpBalance > 0){
            reward = _userPendingReward[recipient] + _globalIndex.sub(_userState[recipient]).mulDown(userLpBalance);
        }
        return reward;
    }

    function _updateReward(address user) private onlyInitialized() {
        uint256 userLpBalance = balanceOf(user);
        if(userLpBalance > 0){
            uint256 reward = _globalIndex.sub(_userState[user]).mulDown(userLpBalance);
            _userPendingReward[user] += reward;
            _userState[user] = _globalIndex;
        }else{
            _userPendingReward[user] = 0;
            _userState[user] = _globalIndex;
        }
    }

}
