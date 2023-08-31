// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "openzeppelin/token/ERC20/ERC20.sol";
import "openzeppelin/token/ERC20/IERC20.sol";
import "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin/utils/Strings.sol";
import "openzeppelin/utils/math/SignedMath.sol";
import "openzeppelin/security/ReentrancyGuard.sol";

import "./interface/IInverseBondingCurve.sol";
import "./InverseBondingCurveToken.sol";
import "./lib/balancer/FixedPoint.sol";
import "./Constants.sol";
import "./Errors.sol";

contract InverseBondingCurve is IInverseBondingCurve, ERC20 {
    using FixedPoint for uint256;
    using SignedMath for int256;
    using SafeERC20 for IERC20;
    /// ERRORS ///

    /// EVENTS ///

    event LiquidityAdd(
        uint256 reserveIn,
        uint256 liquidityTokenAmount,
        uint256 newParameterM,
        int256 newParameterK
    );
    event LiquidityRemove(
        uint256 liquidityTokenIn,
        uint256 reserveOut,
        uint256 newParameterM,
        int256 newParameterK
    );

    /// STATE VARIABLES ///
    int256 private _parameterK;
    uint256 private _parameterM;
    bool private _isInitialized;

    InverseBondingCurveToken private immutable _inverseToken;

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
    }

    function initialize(uint256 supply, uint256 price) external payable {
        require(msg.value > 1 ether, ERR_LIQUIDITY_TOO_SMALL);
        require(supply > 0 && price > 0, ERR_PARAM_ZERO);
        _isInitialized = true;

        _parameterK = ONE_INT - int256(supply.mulDown(price).divDown(msg.value));
        require(_parameterK < 1, ERR_PARAM_UPDATE_FAIL);
        _parameterM = price.mulDown(supply.pow(_parameterK));

        // mint LP token
        _mint(msg.sender, msg.value);
        // mint IBC token
        _inverseToken.mint(msg.sender, supply);
    }


    function addLiquidity() external payable onlyInitialized{
        require(msg.value > MIN_LIQUIDITY, ERR_LIQUIDITY_TOO_SMALL);
        uint256 currentIbcSupply = _inverseToken.totalSupply();
        uint256 currentPrice = getPrice(currentIbcSupply);
        uint256 currentBalance = address(this).balance;
        uint256 mintToken = totalSupply().mulDown(msg.value).divDown(currentBalance);
        _mint(msg.sender, mintToken);
        _parameterK = ONE_INT - int256((currentPrice.mulDown(currentIbcSupply)).divDown(currentBalance));
        require(_parameterK < 1, ERR_PARAM_UPDATE_FAIL);
        _parameterM = currentPrice.mulDown(currentIbcSupply.pow(_parameterK));
    }

    function removeLiquidity(uint256 lpTokenAmount) external onlyInitialized {}

    function buyToken() external payable onlyInitialized {}

    function sellToken(uint256 amount) external onlyInitialized {}

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

}
