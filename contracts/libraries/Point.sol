// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.4;

library Point {
    
    struct Data {
        uint128 liquidAcc;
        // value to add when pass this slot from left to right
        // value to dec when pass this slot from right to left
        int128 liquidDelta;
        // if pointPrice < currPrice
        //    value = sigma(feeScaleX(p)), which p < pointPrice
        // if pointPrice >= currPrice
        //    value = sigma(feeScaleX(p)), which p >= pointPrice
        uint256 feeScaleXBeyond_128;
        // similar to feeScaleXBeyond_128
        uint256 feeScaleYBeyond_128;
        // whether the point is endpoint of a liquid segment
        bool isEndpt;
    }
    
    function _getFeeScaleL(
        int24 endpt,
        int24 currpt,
        uint256 feeScale_128,
        uint256 feeScaleBeyond_128
    ) internal pure returns (uint256 feeScaleL_128) {
        if (endpt <= currpt) {
            feeScaleL_128 = feeScaleBeyond_128;
        } else {
            // feeScaleBeyond will never exceed feeScale
            // so, simply minus in 0.8 is safe
            feeScaleL_128 = feeScale_128 - feeScaleBeyond_128;
        }
    }
    function _getFeeScaleGE(
        int24 endpt,
        int24 currpt,
        uint256 feeScale_128,
        uint256 feeScaleBeyond_128
    ) internal pure returns (uint256 feeScaleGE_128) {
        if (endpt > currpt) {
            feeScaleGE_128 = feeScaleBeyond_128;
        } else {
            feeScaleGE_128 = feeScale_128 - feeScaleBeyond_128;
        }
    }
    /// @dev calculate fee scale within range [pl, pr)
    /// @param axies collection of points of liquidities
    /// @param pl left endpoint of the segment
    /// @param pr right endpoint of the segment
    /// @param currpt point of the curr price
    /// @param feeScaleX_128 total fee scale of token x accummulated of the exchange
    /// @param feeScaleY_128 similar to feeScaleX_128
    /// @return subFeeScaleX_128 subFeeScaleY_128 fee scale of token x and token y within range [pl, pr)
    function getSubFeeScale(
        mapping(int24 =>Point.Data) storage axies,
        int24 pl,
        int24 pr,
        int24 currpt,
        uint256 feeScaleX_128,
        uint256 feeScaleY_128
    ) internal view returns (uint256 subFeeScaleX_128, uint256 subFeeScaleY_128) {
        Point.Data storage plData = axies[pl];
        Point.Data storage prData = axies[pr];
        // tot fee scale of token x for price < pl
        uint256 feeScaleLX_128 = _getFeeScaleL(pl, currpt, feeScaleX_128, plData.feeScaleXBeyond_128);
        // to fee scale of token x for price >= pr
        uint256 feeScaleGEX_128 = _getFeeScaleGE(pr, currpt, feeScaleX_128, prData.feeScaleXBeyond_128);
        uint256 feeScaleLY_128 = _getFeeScaleL(pl, currpt, feeScaleY_128, plData.feeScaleYBeyond_128);
        uint256 feeScaleGEY_128 = _getFeeScaleGE(pr, currpt, feeScaleY_128, prData.feeScaleYBeyond_128);
        assembly{
            subFeeScaleX_128 := sub(sub(feeScaleX_128, feeScaleLX_128), feeScaleGEX_128)
            subFeeScaleY_128 := sub(sub(feeScaleY_128, feeScaleLY_128), feeScaleGEY_128)
        }
    }
    
    /// @dev update and endpoint of a liquidity segment,
    /// @param axies collections of points
    /// @param endpt endpoint of a segment
    /// @param isLeft left or right endpoint
    /// @param currpt point of current price
    /// @param delta >0 for add liquidity and <0 for dec
    /// @param liquidLimPt liquid limit per point
    /// @param feeScaleX_128 total fee scale of token x
    /// @param feeScaleY_128 total fee scale of token y
    function updateEndpoint(
        mapping(int24 =>Point.Data) storage axies,
        int24 endpt,
        bool isLeft,
        int24 currpt,
        int128 delta,
        uint128 liquidLimPt,
        uint256 feeScaleX_128,
        uint256 feeScaleY_128
    ) internal returns (bool) {
        Point.Data storage data = axies[endpt];
        uint128 liquidAccBefore = data.liquidAcc;
        // delta cannot be 0
        require(delta!=0, "D0");
        // liquide acc cannot overflow
        uint128 liquidAccAfter;
        if (delta > 0) {
            liquidAccAfter = liquidAccBefore + uint128(delta);
            require(liquidAccAfter > liquidAccBefore, "LAAO");
        } else {
            liquidAccAfter = liquidAccBefore - uint128(-delta);
            require(liquidAccAfter < liquidAccBefore, "LASO");
        }
        require(liquidAccAfter <= liquidLimPt, "L LIM PT");
        data.liquidAcc = liquidAccAfter;

        if (isLeft) {
            data.liquidDelta = data.liquidDelta + delta;
        } else {
            data.liquidDelta = data.liquidDelta - delta;
        }
        bool new_or_erase = false;
        if (liquidAccBefore == 0) {
            // a new endpoint of certain segment
            new_or_erase = true;
            data.isEndpt = true;
            // it can be proved that
            // for either left point or right point of the liquide segment
            // the feeScaleBeyond can be initialized to arbitrary value
            // we here set the initial val to total feeScale to delay overflow
            if (endpt >= currpt) {
                data.feeScaleXBeyond_128 = feeScaleX_128;
                data.feeScaleYBeyond_128 = feeScaleY_128;
            }
        } else if (liquidAccAfter == 0) {
            // no segment use this endpoint
            new_or_erase = true;
            data.isEndpt = false;
        }
        return new_or_erase;
    }

    /// @dev pass the endpoint, change the feescale beyond the price
    /// @param endpt endpoint to change
    /// @param feeScaleX_128 total fee scale of token x
    /// @param feeScaleY_128 total fee scale of token y 
    function passEndpoint(
        Point.Data storage endpt,
        uint256 feeScaleX_128,
        uint256 feeScaleY_128
    ) internal {
        endpt.feeScaleXBeyond_128 = feeScaleX_128 - endpt.feeScaleXBeyond_128;
        endpt.feeScaleYBeyond_128 = feeScaleY_128 - endpt.feeScaleYBeyond_128;
    }

}