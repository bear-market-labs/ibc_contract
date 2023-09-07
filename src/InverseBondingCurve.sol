// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "openzeppelin/token/ERC20/IERC20.sol";
import "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin/utils/math/SignedMath.sol";
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

    event LiquidityStaked(address indexed from, uint256 amount);
    event LiquidityUnstaked(address indexed from, uint256 amount);

    event TokenBought(address indexed from, address indexed recipient, uint256 amountIn, uint256 amountOut);

    event TokenSold(address indexed from, address indexed recipient, uint256 amountIn, uint256 amountOut);

    event RewardClaimed(address indexed from, address indexed recipient, RewardType rewardType, uint256 amount);

    event FeeConfigChanged(uint256 lpFee, uint256 stakingFee, uint256 protocolFee);

    event FeeOwnerChanged(address feeOwner);

    /// STATE VARIABLES ///
    address _protocolFeeOwner;
    //TODO: there will be tiny errors accumulated and some balance left after user claim reward,
    // need to handle this properly to protocol
    uint256 _protocolFee;
    uint256 _totalStaked;

    int256 private _parameterK;
    uint256 private _parameterM;
    uint256 private _globalLpFeeIndex;
    uint256 private _globalStakingFeeIndex;

    // swap fee percent = _lpFeePercent + _stakingFeePercent + _protocolFeePercent
    uint256 private _lpFeePercent;
    uint256 private _stakingFeePercent;
    uint256 private _protocolFeePercent;

    IInverseBondingCurveToken private _inverseToken;
    mapping(address => uint256) private _userLpFeeIndexState;
    mapping(address => uint256) private _userLpPendingReward;
    mapping(address => uint256) private _userStakingFeeIndexState;
    mapping(address => uint256) private _userStakingPendingReward;

    mapping(address => uint256) private _stakingBalance;

    /// MODIFIERS ///

    ///
    /// CONSTRUCTOR
    ///

    constructor() {
        _disableInitializers();
    }

    function initialize(uint256 supply, uint256 price, address inverseTokenContractAddress, address protocolFeeOwner)
        external
        payable
        initializer
    {
        require(msg.value >= MIN_LIQUIDITY, ERR_LIQUIDITY_TOO_SMALL);
        require(supply > 0 && price > 0, ERR_PARAM_ZERO);
        require(inverseTokenContractAddress != address(0), ERR_EMPTY_ADDRESS);
        require(protocolFeeOwner != address(0), ERR_EMPTY_ADDRESS);

        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();
        __ERC20_init("IBCLP", "IBCLP");

        _lpFeePercent = FEE_PERCENT;
        _stakingFeePercent = FEE_PERCENT;
        _protocolFeePercent = FEE_PERCENT;

        _inverseToken = IInverseBondingCurveToken(inverseTokenContractAddress);
        _protocolFeeOwner = protocolFeeOwner;

        _parameterK = ONE_INT - int256(supply.mulDown(price).divDown(msg.value));
        require(_parameterK > 0 && _parameterK < ONE_INT, ERR_PARAM_UPDATE_FAIL);
        _parameterM = price.mulDown(supply.pow(_parameterK));

        _updateLpReward(msg.sender);
        // mint LP token
        _mint(msg.sender, msg.value);
        // mint IBC token
        _inverseToken.mint(msg.sender, supply);

        emit FeeOwnerChanged(protocolFeeOwner);
        emit LiquidityAdded(msg.sender, msg.sender, msg.value, supply, _parameterK, _parameterM);
    }   

    function updateFeeConfig(uint256 lpFee, uint256 stakingFee, uint256 protocolFee) external onlyOwner {
        require((lpFee + stakingFee + protocolFee) < 5e17, ERR_FEE_PERCENT_OUT_OF_RANGE);
        _lpFeePercent = lpFee;
        _stakingFeePercent = stakingFee;
        _protocolFeePercent = protocolFee;

        emit FeeConfigChanged(lpFee, stakingFee, protocolFee);
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

        uint256 currentIbcSupply = _inverseToken.totalSupply();
        uint256 currentPrice = priceOf(currentIbcSupply);
        require(currentPrice >= minPriceLimit, ERR_PRICE_OUT_OF_LIMIT);

        uint256 currentBalance = address(this).balance;
        uint256 mintToken = totalSupply().mulDown(msg.value).divDown(
            currentBalance.sub(msg.value).sub(currentIbcSupply.mulDown(currentPrice))
        );

        _updateLpReward(recipient);
        _mint(recipient, mintToken);
        _parameterK = ONE_INT - int256((currentPrice.mulDown(currentIbcSupply)).divDown(currentBalance));
        require(_parameterK < ONE_INT, ERR_PARAM_UPDATE_FAIL);
        _parameterM = currentPrice.mulDown(currentIbcSupply.pow(_parameterK));

        emit LiquidityAdded(msg.sender, recipient, msg.value, mintToken, _parameterK, _parameterM);
    }

    function removeLiquidity(address recipient, uint256 amount, uint256 maxPriceLimit) external whenNotPaused {
        require(balanceOf(msg.sender) >= amount, ERR_INSUFFICIENT_BALANCE);
        require(recipient != address(0), ERR_EMPTY_ADDRESS);

        uint256 currentIbcSupply = _inverseToken.totalSupply();
        uint256 currentPrice = priceOf(currentIbcSupply);
        require(currentPrice <= maxPriceLimit, ERR_PRICE_OUT_OF_LIMIT);

        uint256 currentBalance = address(this).balance;
        uint256 returnLiquidity =
            amount.mulDown(currentBalance.sub(currentIbcSupply.mulDown(currentPrice))).divDown(totalSupply());

        _updateLpReward(msg.sender);
        _burn(msg.sender, amount);

        uint256 newBalance = currentBalance - returnLiquidity;
        _parameterK = ONE_INT - int256((currentPrice.mulDown(currentIbcSupply)).divDown(newBalance));
        require(_parameterK < ONE_INT, ERR_PARAM_UPDATE_FAIL);
        _parameterM = currentPrice.mulDown(currentIbcSupply.pow(_parameterK));
        (bool sent,) = recipient.call{value: returnLiquidity}("");
        require(sent, "Failed to send Ether");

        emit LiquidityRemoved(msg.sender, recipient, amount, returnLiquidity, _parameterK, _parameterM);
    }

    function _calculateAndUpdateFee(uint256 tokenAmount) private returns (uint256 totalFee) {
        uint256 lpFee = tokenAmount.mulDown(_lpFeePercent);
        uint256 stakingFee = tokenAmount.mulDown(_stakingFeePercent);
        uint256 protocolFee = tokenAmount.mulDown(_protocolFeePercent);

        if (totalSupply() > 0) {
            _globalLpFeeIndex += lpFee.divDown(totalSupply());
        }
        if (_totalStaked > 0) {
            _globalStakingFeeIndex += stakingFee.divDown(_totalStaked);
        }

        _protocolFee += protocolFee;

        return lpFee + stakingFee + protocolFee;
    }

    function buyTokens(address recipient, uint256 maxPriceLimit) external payable whenNotPaused {
        require(recipient != address(0), ERR_EMPTY_ADDRESS);
        require(msg.value > MIN_LIQUIDITY, ERR_LIQUIDITY_TOO_SMALL);

        uint256 newSupply = getSupplyFromLiquidity(address(this).balance);
        uint256 newToken = newSupply - _inverseToken.totalSupply();

        uint256 fee = _calculateAndUpdateFee(newToken);
        // uint256 fee = newToken.mulDown(_lpFeePercent);
        uint256 mintToken = newToken.sub(fee);
        require(msg.value.divDown(mintToken) <= maxPriceLimit, ERR_PRICE_OUT_OF_LIMIT);

        // _globalLpFeeIndex += fee.divDown(totalSupply());
        _inverseToken.mint(recipient, mintToken);
        _inverseToken.mint(address(this), fee);

        emit TokenBought(msg.sender, recipient, msg.value, mintToken);
    }

    function sellTokens(address recipient, uint256 amount, uint256 minPriceLimit) external whenNotPaused {
        require(_inverseToken.balanceOf(msg.sender) >= amount, ERR_INSUFFICIENT_BALANCE);
        require(amount >= MIN_SUPPLY, ERR_LIQUIDITY_TOO_SMALL);
        require(recipient != address(0), ERR_EMPTY_ADDRESS);

        uint256 fee = _calculateAndUpdateFee(amount);
        // uint256 fee = amount.mulDown(_lpFeePercent);
        uint256 burnToken = amount.sub(fee);
        uint256 newLiquidity = getLiquidityFromSupply(_inverseToken.totalSupply().sub(burnToken));
        uint256 returnLiquidity = address(this).balance - newLiquidity;

        require(returnLiquidity.divDown(burnToken) >= minPriceLimit, ERR_PRICE_OUT_OF_LIMIT);

        // Change state
        // _globalLpFeeIndex += fee.divDown(totalSupply());
        _inverseToken.burnFrom(msg.sender, burnToken);
        IERC20(_inverseToken).safeTransferFrom(msg.sender, address(this), fee);

        (bool sent,) = recipient.call{value: returnLiquidity}("");
        require(sent, "Failed to send Ether");

        emit TokenSold(msg.sender, recipient, amount, returnLiquidity);
    }

    function stake(uint256 amount) external whenNotPaused {
        require(_inverseToken.balanceOf(msg.sender) >= amount, ERR_INSUFFICIENT_BALANCE);

        _updateStakingReward(msg.sender);
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

    function claimReward(address recipient, RewardType rewardType) external whenNotPaused {
        require(recipient != address(0), ERR_EMPTY_ADDRESS);
        if (RewardType.LP == rewardType) {
            _claimLpReward(recipient, rewardType);
        } else if (RewardType.STAKING == rewardType) {
            _claimStakingReward(recipient, rewardType);
        } else {}
    }

    function claimProtocolReward() external onlyOwner whenNotPaused {
        uint256 amount = _protocolFee;
        _protocolFee = 0;
        IERC20(_inverseToken).safeTransfer(_protocolFeeOwner, amount);

        emit RewardClaimed(msg.sender, _protocolFeeOwner, RewardType.PROTOCOL, amount);
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
        return _parameterM.divDown(supply.pow(_parameterK));
    }

    function getLiquidityFromSupply(uint256 supply) public view returns (uint256) {
        uint256 oneMinusK = uint256(ONE_INT - _parameterK);
        return _parameterM.mulDown(supply.powDown(oneMinusK)).divDown(oneMinusK);
    }

    function getSupplyFromLiquidity(uint256 liquidity) public view returns (uint256) {
        uint256 oneMinusK = uint256(ONE_INT - _parameterK);

        return liquidity.mulDown(oneMinusK).divDown(_parameterM).powDown(ONE_UINT.divDown(oneMinusK));
    }

    function inverseTokenAddress() external view returns (address) {
        return address(_inverseToken);
    }

    function curveParameters() external view returns (CurveParameter memory parameters) {
        uint256 supply = _inverseToken.totalSupply();
        return CurveParameter(address(this).balance, supply, priceOf(supply), _parameterK, _parameterM);
    }

    function feeConfig() external view returns (uint256 lpFee, uint256 stakingFee, uint256 protocolFee) {
        return (_lpFeePercent, _stakingFeePercent, _protocolFeePercent);
    }

    function feeOwner() external view returns (address) {
        return _protocolFeeOwner;
    }

    function rewardOf(address recipient, RewardType rewardType) external view returns (uint256) {
        uint256 reward = 0;
        if (rewardType == RewardType.LP) {
            uint256 userLpBalance = balanceOf(recipient);
            reward += _userLpPendingReward[recipient];
            if (userLpBalance > 0) {
                reward += _globalLpFeeIndex.sub(_userLpFeeIndexState[recipient]).mulDown(userLpBalance);
            }
        } else if (rewardType == RewardType.STAKING) {
            uint256 userStakingBalance = _stakingBalance[recipient];
            reward += _userStakingPendingReward[recipient];
            if (userStakingBalance > 0) {
                reward += _globalStakingFeeIndex.sub(_userStakingFeeIndexState[recipient]).mulDown(userStakingBalance);
            }
        } else {
            reward = _protocolFee;
        }

        return reward;
    }

    function stakingBalanceOf(address holder) external view returns (uint256) {
        return _stakingBalance[holder];
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    function _claimLpReward(address recipient, RewardType rewardType) private {
        _updateLpReward(msg.sender);

        if (_userLpPendingReward[msg.sender] > 0) {
            uint256 amount = _userLpPendingReward[msg.sender];
            _userLpPendingReward[msg.sender] = 0;
            IERC20(_inverseToken).safeTransfer(recipient, amount);

            emit RewardClaimed(msg.sender, recipient, rewardType, amount);
        }
    }

    function _claimStakingReward(address recipient, RewardType rewardType) private {
        _updateStakingReward(msg.sender);

        if (_userStakingPendingReward[msg.sender] > 0) {
            uint256 amount = _userStakingPendingReward[msg.sender];
            _userStakingPendingReward[msg.sender] = 0;
            IERC20(_inverseToken).safeTransfer(recipient, amount);

            emit RewardClaimed(msg.sender, recipient, rewardType, amount);
        }
    }

    function _updateLpReward(address user) private {
        uint256 userLpBalance = balanceOf(user);
        if (userLpBalance > 0) {
            uint256 reward = _globalLpFeeIndex.sub(_userLpFeeIndexState[user]).mulDown(userLpBalance);
            _userLpPendingReward[user] += reward;
            _userLpFeeIndexState[user] = _globalLpFeeIndex;
        } else {
            _userLpFeeIndexState[user] = _globalLpFeeIndex;
        }
    }

    function _updateStakingReward(address user) private {
        uint256 userStakingBalance = _stakingBalance[user];
        if (userStakingBalance > 0) {
            uint256 reward = _globalStakingFeeIndex.sub(_userStakingFeeIndexState[user]).mulDown(userStakingBalance);
            _userStakingPendingReward[user] += reward;
            _userStakingFeeIndexState[user] = _globalStakingFeeIndex;
        } else {
            _userStakingPendingReward[user] = 0;
            _userStakingFeeIndexState[user] = _globalStakingFeeIndex;
        }
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override whenNotPaused {
        super._beforeTokenTransfer(from, to, amount);
    }

    // =============================!!! Do not remove below method !!!=============================
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    // ============================================================================================
}
