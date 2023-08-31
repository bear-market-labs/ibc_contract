// SPDX-License-Identifier: GPL-3.0-or-later
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity >=0.7.0 <0.9.0;

import "./BalancerErrors.sol";

import "./LogExpMath.sol";

/* solhint-disable private-vars-leading-underscore */

library FixedPoint {
    // solhint-disable no-inline-assembly
    uint256 internal constant uMAX = 115792089237316195423570985008687907853269984665640564039457_584007913129639935;
    uint256 internal constant ONE = 1e18; // 18 decimal places
    uint256 internal constant TWO = 2 * ONE;
    uint256 internal constant FOUR = 4 * ONE;
    uint256 internal constant MAX_POW_RELATIVE_ERROR = 10000; // 10^(-14)

    // Minimum base for the power function when the exponent is 'free' (larger than ONE).
    uint256 internal constant MIN_POW_BASE_FREE_EXPONENT = 0.7e18;

    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        // Fixed Point addition is the same as regular checked addition

        uint256 c = a + b;
        _require(c >= a, Errors.ADD_OVERFLOW);
        return c;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        // Fixed Point addition is the same as regular checked addition

        _require(b <= a, Errors.SUB_OVERFLOW);
        uint256 c = a - b;
        return c;
    }

    function mulDown(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 product = a * b;
        _require(a == 0 || product / a == b, Errors.MUL_OVERFLOW);

        return product / ONE;
    }

    function mulUp(uint256 a, uint256 b) internal pure returns (uint256 result) {
        uint256 product = a * b;
        _require(a == 0 || product / a == b, Errors.MUL_OVERFLOW);

        // The traditional divUp formula is:
        // divUp(x, y) := (x + y - 1) / y
        // To avoid intermediate overflow in the addition, we distribute the division and get:
        // divUp(x, y) := (x - 1) / y + 1
        // Note that this requires x != 0, if x == 0 then the result is zero
        //
        // Equivalent to:
        // result = product == 0 ? 0 : ((product - 1) / FixedPoint.ONE) + 1;
        assembly {
            result := mul(iszero(iszero(product)), add(div(sub(product, 1), ONE), 1))
        }
    }

    function divDown(uint256 a, uint256 b) internal pure returns (uint256) {
        _require(b != 0, Errors.ZERO_DIVISION);

        uint256 aInflated = a * ONE;
        _require(a == 0 || aInflated / a == ONE, Errors.DIV_INTERNAL); // mul overflow

        return aInflated / b;
    }

    function divUp(uint256 a, uint256 b) internal pure returns (uint256 result) {
        _require(b != 0, Errors.ZERO_DIVISION);

        uint256 aInflated = a * ONE;
        _require(a == 0 || aInflated / a == ONE, Errors.DIV_INTERNAL); // mul overflow

        // The traditional divUp formula is:
        // divUp(x, y) := (x + y - 1) / y
        // To avoid intermediate overflow in the addition, we distribute the division and get:
        // divUp(x, y) := (x - 1) / y + 1
        // Note that this requires x != 0, if x == 0 then the result is zero
        //
        // Equivalent to:
        // result = a == 0 ? 0 : (a * FixedPoint.ONE - 1) / b + 1;
        assembly {
            result := mul(iszero(iszero(aInflated)), add(div(sub(aInflated, 1), b), 1))
        }
    }

    /**
     * @dev Returns x^y, assuming both are fixed point numbers, rounding down. The result is guaranteed to not be above
     * the true value (that is, the error function expected - actual is always positive).
     */
    function powDown(uint256 x, uint256 y) internal pure returns (uint256) {
        // Optimize for when y equals 1.0, 2.0 or 4.0, as those are very simple to implement and occur often in 50/50
        // and 80/20 Weighted Pools
        if (y == ONE) {
            return x;
        } else if (y == TWO) {
            return mulDown(x, x);
        } else if (y == FOUR) {
            uint256 square = mulDown(x, x);
            return mulDown(square, square);
        } else {
            uint256 raw = LogExpMath.pow(x, y);
            uint256 maxError = add(mulUp(raw, MAX_POW_RELATIVE_ERROR), 1);

            if (raw < maxError) {
                return 0;
            } else {
                return sub(raw, maxError);
            }
        }
    }

    /**
     * @dev Returns x^y, assuming both are fixed point numbers, rounding up. The result is guaranteed to not be below
     * the true value (that is, the error function expected - actual is always negative).
     */
    function powUp(uint256 x, uint256 y) internal pure returns (uint256) {
        // Optimize for when y equals 1.0, 2.0 or 4.0, as those are very simple to implement and occur often in 50/50
        // and 80/20 Weighted Pools
        if (y == ONE) {
            return x;
        } else if (y == TWO) {
            return mulUp(x, x);
        } else if (y == FOUR) {
            uint256 square = mulUp(x, x);
            return mulUp(square, square);
        } else {
            uint256 raw = LogExpMath.pow(x, y);
            uint256 maxError = add(mulUp(raw, MAX_POW_RELATIVE_ERROR), 1);

            return add(raw, maxError);
        }
    }

    /**
     * @dev Returns the complement of a value (1 - x), capped to 0 if x is larger than 1.
     *
     * Useful when computing the complement for values with some level of relative error, as it strips this error and
     * prevents intermediate negative values.
     */
    function complement(uint256 x) internal pure returns (uint256 result) {
        // Equivalent to:
        // result = (x < ONE) ? (ONE - x) : 0;
        assembly {
            result := mul(lt(x, ONE), sub(ONE, x))
        }
    }

    /// @notice Calculates the square root of x using the Babylonian method.
    ///
    /// @dev See https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method.
    ///
    /// Notes:
    /// - If x is not a perfect square, the result is rounded down.
    /// - Credits to OpenZeppelin for the explanations in comments below.
    ///
    /// @param x The uint256 number for which to calculate the square root.
    /// @return result The result as a uint256.
    /// @custom:smtchecker abstract-function-nondet
    function sqrt(uint256 x) internal pure returns (uint256 result) {
        _require(x <= (uMAX / ONE), Errors.OUT_OF_BOUNDS);

        x = x * ONE;

        if (x == 0) {
            return 0;
        }

        // For our first guess, we calculate the biggest power of 2 which is smaller than the square root of x.
        //
        // We know that the "msb" (most significant bit) of x is a power of 2 such that we have:
        //
        // $$
        // msb(x) <= x <= 2*msb(x)$
        // $$
        //
        // We write $msb(x)$ as $2^k$, and we get:
        //
        // $$
        // k = log_2(x)
        // $$
        //
        // Thus, we can write the initial inequality as:
        //
        // $$
        // 2^{log_2(x)} <= x <= 2*2^{log_2(x)+1} \\
        // sqrt(2^k) <= sqrt(x) < sqrt(2^{k+1}) \\
        // 2^{k/2} <= sqrt(x) < 2^{(k+1)/2} <= 2^{(k/2)+1}
        // $$
        //
        // Consequently, $2^{log_2(x) /2} is a good first approximation of sqrt(x) with at least one correct bit.
        uint256 xAux = uint256(x);
        result = 1;
        if (xAux >= 2 ** 128) {
            xAux >>= 128;
            result <<= 64;
        }
        if (xAux >= 2 ** 64) {
            xAux >>= 64;
            result <<= 32;
        }
        if (xAux >= 2 ** 32) {
            xAux >>= 32;
            result <<= 16;
        }
        if (xAux >= 2 ** 16) {
            xAux >>= 16;
            result <<= 8;
        }
        if (xAux >= 2 ** 8) {
            xAux >>= 8;
            result <<= 4;
        }
        if (xAux >= 2 ** 4) {
            xAux >>= 4;
            result <<= 2;
        }
        if (xAux >= 2 ** 2) {
            result <<= 1;
        }

        // At this point, `result` is an estimation with at least one bit of precision. We know the true value has at
        // most 128 bits, since it is the square root of a uint256. Newton's method converges quadratically (precision
        // doubles at every iteration). We thus need at most 7 iteration to turn our partial result with one bit of
        // precision into the expected uint128 result.
        unchecked {
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;

            // If x is not a perfect square, round the result toward zero.
            uint256 roundedResult = x / result;
            if (result >= roundedResult) {
                result = roundedResult;
            }
        }
    }

    function pow(uint256 x, int256 y) internal pure returns (uint256) {
        if (y < 0) {
            return divDown(ONE, powDown(x, uint256(-y)));
        } else if (y == 0) {
            return ONE;
        } else {
            return powDown(x, uint256(y));
        }
    }
}
