// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.4;

import './interfaces/IiZiSwapPool.sol';
import './libraries/Liquidity.sol';
import './libraries/Point.sol';
import './libraries/PointBitmap.sol';
import './libraries/LogPowMath.sol';
import './libraries/MulDivMath.sol';
import './libraries/TwoPower.sol';
import './libraries/LimitOrder.sol';
import './libraries/SwapMathY2X.sol';
import './libraries/SwapMathX2Y.sol';
import './libraries/SwapMathY2XDesire.sol';
import './libraries/SwapMathX2YDesire.sol';
import './libraries/TokenTransfer.sol';
import './libraries/UserEarn.sol';
import './libraries/State.sol';
import './libraries/SwapCache.sol';
import './libraries/Oracle.sol';
import './interfaces/IiZiSwapCallback.sol';

import 'hardhat/console.sol';

contract SwapX2YModule {

    using Liquidity for mapping(bytes32 =>Liquidity.Data);
    using Liquidity for Liquidity.Data;
    using Point for mapping(int24 =>Point.Data);
    using Point for Point.Data;
    using PointBitmap for mapping(int16 =>uint256);
    using LimitOrder for LimitOrder.Data;
    using UserEarn for UserEarn.Data;
    using UserEarn for mapping(bytes32 =>UserEarn.Data);
    using SwapMathY2X for SwapMathY2X.RangeRetState;
    using SwapMathX2Y for SwapMathX2Y.RangeRetState;
    using Oracle for Oracle.Observation[65535];

    int24 internal constant LEFT_MOST_PT = -800000;
    int24 internal constant RIGHT_MOST_PT = 800000;

    /// @notice left most point regularized by pointDelta
    int24 public leftMostPt;
    /// @notice right most point regularized by pointDelta
    int24 public rightMostPt;
    /// @notice maximum liquidSum for each point, see points() in IiZiSwapPool or library Point
    uint128 public maxLiquidPt;

    /// @notice address of iZiSwapFactory
    address public factory;

    /// @notice address of tokenX
    address public tokenX;

    /// @notice address of tokenY
    address public tokenY;

    /// @notice fee amount of this swap pool, 3000 means 0.3%
    uint24 public fee;

    /// @notice minimum number of distance between initialized or limitorder points 
    int24 public pointDelta;

    /// @notice The fee growth as a 128-bit fixpoing fees of tokenX collected per 1 liquidity of the pool
    uint256 public feeScaleX_128;
    /// @notice The fee growth as a 128-bit fixpoing fees of tokenY collected per 1 liquidity of the pool
    uint256 public feeScaleY_128;

    uint160 sqrtRate_96;

    /// @notice some values of pool
    /// see library State or IiZiSwapPool#state for more infomation
    State public state;

    /// @notice the information about a liquidity by the liquidity's key
    mapping(bytes32 =>Liquidity.Data) public liquidities;

    /// @notice 256 packed point (orderOrEndpoint>0) boolean values. See PointBitmap for more information
    mapping(int16 =>uint256) public pointBitmap;

    /// @notice returns infomation of a point in the pool, see Point library of IiZiSwapPool#poitns for more information
    mapping(int24 =>Point.Data) public points;
    /// @notice infomation about a point whether has limit order and whether as an liquidity's endpoint
    mapping(int24 =>int24) public orderOrEndpoint;
    /// @notice limitOrder info on a given point
    mapping(int24 =>LimitOrder.Data) public limitOrderData;
    /// @notice information about a user's limit order (sell tokenY and earn tokenX)
    mapping(bytes32 => UserEarn.Data) public userEarnX;
    /// @notice information about a user's limit order (sell tokenX and earn tokenY)
    mapping(bytes32 => UserEarn.Data) public userEarnY;
    /// @notice observation data array
    Oracle.Observation[65535] public observations;
    
    uint256 public totalFeeXCharged;
    uint256 public totalFeeYCharged;

    address private  original;

    address private swapModuleX2Y;
    address private swapModuleY2X;
    address private mintModule;

    /// @notice percent to charge from miner's fee
    uint24 public immutable feeChargePercent = 20;

    // delta cannot be int128.min and it can be proofed that
    // liquidDelta of any one point will not be int128.min
    function liquidityAddDelta(uint128 l, int128 delta) private pure returns (uint128 nl) {
        if (delta < 0) {
            nl = l - uint128(-delta);
        } else {
            nl = l + uint128(delta);
        }
    }
    function balanceX() private view returns (uint256) {
        (bool success, bytes memory data) =
            tokenX.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    function balanceY() private view returns (uint256) {
        (bool success, bytes memory data) =
            tokenY.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    function getOrderOrEndptValue(int24 point, int24 _pointDelta) internal view returns(int24 val) {
        if (point % _pointDelta != 0) {
            return 0;
        }
        val = orderOrEndpoint[point / _pointDelta];
    }
    function setOrderOrEndptValue(int24 point, int24 _pointDelta, int24 val) internal {
        orderOrEndpoint[point / _pointDelta] = val;
    }

    /// @notice Swap tokenX for tokenY， given max amount of tokenX user willing to pay
    /// @param recipient The address to receive tokenY
    /// @param amount The max amount of tokenX user willing to pay
    /// @param lowPt the lowest point(price) of x/y during swap
    /// @param data Any data to be passed through to the callback
    /// @return amountX amount of tokenX acquired
    /// @return amountY amount of tokenY payed
    function swapX2Y(
        address recipient,
        uint128 amount,
        int24 lowPt,
        bytes calldata data
    ) external returns (uint256 amountX, uint256 amountY) {
        
        // todo we will consider -amount of desired y later
        require(amount > 0, "AP");
        require(lowPt >= leftMostPt, "LO");
        amountX = 0;
        amountY = 0;
        State memory st = state;
        SwapCache memory cache;
        cache.currFeeScaleX_128 = feeScaleX_128;
        cache.currFeeScaleY_128 = feeScaleY_128;
        cache.finished = false;
        cache._sqrtRate_96 = sqrtRate_96;
        cache.pointDelta = pointDelta;
        cache.currentOrderOrEndpt = getOrderOrEndptValue(st.currentPoint, cache.pointDelta);
        cache.startPoint = st.currentPoint;
        cache.startLiquidity = st.liquidity;
        cache.timestamp = uint32(block.number);
        while (lowPt <= st.currentPoint && !cache.finished) {
            // clear limit order first
            if (cache.currentOrderOrEndpt & 2 > 0) {
                LimitOrder.Data storage od = limitOrderData[st.currentPoint];
                uint256 currY = od.sellingY;
                (uint128 costX, uint256 acquireY) = SwapMathX2Y.x2YAtPrice(
                    amount, st.sqrtPrice_96, currY
                );
                if (acquireY < currY || costX >= amount) {
                    cache.finished = true;
                }
                amount -= costX;
                amountX = amountX + costX;
                amountY += acquireY;
                currY -= acquireY;
                od.sellingY = currY;
                od.earnX += costX;
                od.accEarnX += costX;
                if (od.sellingX == 0 && currY == 0) {
                    int24 newVal = cache.currentOrderOrEndpt & 1;
                    setOrderOrEndptValue(st.currentPoint, cache.pointDelta, newVal);
                    if (newVal == 0) {
                        pointBitmap.setZero(st.currentPoint, cache.pointDelta);
                    }
                }
            }
            if (cache.finished) {
                break;
            }
            int24 searchStart = st.currentPoint - 1;
            // second, clear the liquid if the currentPoint is an endpoint
            if (cache.currentOrderOrEndpt & 1 > 0) {
                uint128 amountNoFee = uint128(uint256(amount) * 1e6 / (1e6 + fee));
                if (amountNoFee > 0) {
                    if (st.liquidity > 0) {
                        SwapMathX2Y.RangeRetState memory retState = SwapMathX2Y.x2YRange(
                            st,
                            st.currentPoint,
                            cache._sqrtRate_96,
                            amountNoFee
                        );
                        cache.finished = retState.finished;
                        uint128 feeAmount;
                        if (retState.costX >= amountNoFee) {
                            feeAmount = amount - retState.costX;
                        } else {
                            feeAmount = uint128(uint256(retState.costX) * fee / 1e6);
                            uint256 mod = uint256(retState.costX) * fee % 1e6;
                            if (mod > 0) {
                                feeAmount += 1;
                            }
                        }
                        uint256 chargedFeeAmount = uint256(feeAmount) * feeChargePercent / 100;
                        totalFeeXCharged += chargedFeeAmount;

                        cache.currFeeScaleX_128 = cache.currFeeScaleX_128 + MulDivMath.mulDivFloor(feeAmount - chargedFeeAmount, TwoPower.Pow128, st.liquidity);
                        amountX = amountX + retState.costX + feeAmount;
                        amountY += retState.acquireY;
                        amount -= (retState.costX + feeAmount);
                        st.currentPoint = retState.finalPt;
                        st.sqrtPrice_96 = retState.sqrtFinalPrice_96;
                        st.allX = retState.finalAllX;
                        st.currX = retState.finalCurrX;
                        st.currY = retState.finalCurrY;
                    }
                    if (!cache.finished) {
                        Point.Data storage pointdata = points[st.currentPoint];
                        pointdata.passEndpoint(cache.currFeeScaleX_128, cache.currFeeScaleY_128);
                        st.liquidity = liquidityAddDelta(st.liquidity, - pointdata.liquidDelta);
                        st.currentPoint = st.currentPoint - 1;
                        st.sqrtPrice_96 = LogPowMath.getSqrtPrice(st.currentPoint);
                        st.allX = false;
                        st.currX = 0;
                        st.currY = MulDivMath.mulDivFloor(st.liquidity, st.sqrtPrice_96, TwoPower.Pow96);
                    }
                } else {
                    cache.finished = true;
                }
            }
            if (cache.finished || st.currentPoint < lowPt) {
                break;
            }
            int24 nextPt= pointBitmap.nearestLeftOneOrBoundary(searchStart, cache.pointDelta);
            if (nextPt < lowPt) {
                nextPt = lowPt;
            }
            int24 nextVal = getOrderOrEndptValue(nextPt, cache.pointDelta);
            
            // in [st.currentPoint, nextPt)
            if (st.liquidity == 0) {

                // no liquidity in the range [nextPt, st.currentPoint]
                st.currentPoint = nextPt;
                st.sqrtPrice_96 = LogPowMath.getSqrtPrice(st.currentPoint);
                st.allX = true;
                cache.currentOrderOrEndpt = nextVal;
            } else {
                // amount > 0
                uint128 amountNoFee = uint128(uint256(amount) * 1e6 / (1e6 + fee));
                if (amountNoFee > 0) {
                    SwapMathX2Y.RangeRetState memory retState = SwapMathX2Y.x2YRange(
                        st, nextPt, cache._sqrtRate_96, amountNoFee
                    );
                    cache.finished = retState.finished;
                    uint128 feeAmount;
                    if (retState.costX >= amountNoFee) {
                        feeAmount = amount - retState.costX;
                    } else {
                        feeAmount = uint128(uint256(retState.costX) * fee / 1e6);
                        uint256 mod = uint256(retState.costX) * fee % 1e6;
                        if (mod > 0) {
                            feeAmount += 1;
                        }
                    }
                    amountY += retState.acquireY;
                    amountX = amountX + retState.costX + feeAmount;
                    amount -= (retState.costX + feeAmount);

                    uint256 chargedFeeAmount = uint256(feeAmount) * feeChargePercent / 100;
                    totalFeeXCharged += chargedFeeAmount;
                    
                    cache.currFeeScaleX_128 = cache.currFeeScaleX_128 + MulDivMath.mulDivFloor(feeAmount - chargedFeeAmount, TwoPower.Pow128, st.liquidity);
                    st.currentPoint = retState.finalPt;
                    st.sqrtPrice_96 = retState.sqrtFinalPrice_96;
                    st.allX = retState.finalAllX;
                    st.currX = retState.finalCurrX;
                    st.currY = retState.finalCurrY;
                } else {
                    cache.finished = true;
                }
                if (st.currentPoint == nextPt) {
                    cache.currentOrderOrEndpt = nextVal;
                } else {
                    // not necessary, because finished must be true
                    cache.currentOrderOrEndpt = 0;
                }
            }
            if (st.currentPoint <= lowPt) {
                break;
            }
        }
        if (cache.startPoint != st.currentPoint) {
            (st.observationCurrentIndex, st.observationQueueLen) = observations.append(
                st.observationCurrentIndex,
                cache.timestamp,
                cache.startPoint,
                cache.startLiquidity,
                st.observationQueueLen,
                st.observationNextQueueLen
            );
        }

        // write back fee scale, no fee of y
        feeScaleX_128 = cache.currFeeScaleX_128;
        // write back state
        state = st;
        // transfer y to trader
        if (amountY > 0) {
            TokenTransfer.transferToken(tokenY, recipient, amountY);
            // trader pay x
            require(amountX > 0, "PP");
            uint256 bx = balanceX();
            IiZiSwapCallback(msg.sender).swapX2YCallback(amountX, amountY, data);
            require(balanceX() >= bx + amountX, "XE");
        }
        
    }
    
    /// @notice Swap tokenX for tokenY， given amount of tokenY user desires
    /// @param recipient The address to receive tokenY
    /// @param desireY The amount of tokenY user desires
    /// @param lowPt the lowest point(price) of x/y during swap
    /// @param data Any data to be passed through to the callback
    /// @return amountX amount of tokenX acquired
    /// @return amountY amount of tokenY payed
    function swapX2YDesireY(
        address recipient,
        uint128 desireY,
        int24 lowPt,
        bytes calldata data
    ) external returns (uint256 amountX, uint256 amountY) {
        // todo we will consider -amount of desired y later
        require(desireY > 0, "AP");
        require(lowPt >= leftMostPt, "LO");
        amountX = 0;
        amountY = 0;
        State memory st = state;
        SwapCache memory cache;
        cache.currFeeScaleX_128 = feeScaleX_128;
        cache.currFeeScaleY_128 = feeScaleY_128;
        cache.finished = false;
        cache._sqrtRate_96 = sqrtRate_96;
        cache.pointDelta = pointDelta;
        cache.currentOrderOrEndpt = getOrderOrEndptValue(st.currentPoint, cache.pointDelta);
        cache.startPoint = st.currentPoint;
        cache.startLiquidity = st.liquidity;
        cache.timestamp = uint32(block.number);
        while (lowPt <= st.currentPoint && !cache.finished) {
            // clear limit order first
            if (cache.currentOrderOrEndpt & 2 > 0) {
                LimitOrder.Data storage od = limitOrderData[st.currentPoint];
                uint256 currY = od.sellingY;
                (uint256 costX, uint256 acquireY) = SwapMathX2YDesire.x2YAtPrice(
                    desireY, st.sqrtPrice_96, currY
                );
                if (acquireY >= desireY) {
                    cache.finished = true;
                }
                desireY = (desireY <= acquireY) ? 0 : desireY - uint128(acquireY);
                amountX += costX;
                amountY += acquireY;
                currY -= acquireY;
                od.sellingY = currY;
                od.earnX += costX;
                od.accEarnX += costX;
                if (od.sellingX == 0 && currY == 0) {
                    int24 newVal = cache.currentOrderOrEndpt & 1;
                    setOrderOrEndptValue(st.currentPoint, cache.pointDelta, newVal);
                    if (newVal == 0) {
                        pointBitmap.setZero(st.currentPoint, cache.pointDelta);
                    }
                }
            }
            if (cache.finished) {
                break;
            }
            int24 searchStart = st.currentPoint - 1;
            // second, clear the liquid if the currentPoint is an endpoint
            if (cache.currentOrderOrEndpt & 1 > 0) {
                if (st.liquidity > 0) {
                    SwapMathX2YDesire.RangeRetState memory retState = SwapMathX2YDesire.x2YRange(
                        st,
                        st.currentPoint,
                        cache._sqrtRate_96,
                        desireY
                    );
                    cache.finished = retState.finished;
                    
                    uint256 feeAmount = MulDivMath.mulDivCeil(retState.costX, fee, 1e6);
                    uint256 chargedFeeAmount = feeAmount * feeChargePercent / 100;
                    totalFeeXCharged += chargedFeeAmount;

                    cache.currFeeScaleX_128 = cache.currFeeScaleX_128 + MulDivMath.mulDivFloor(feeAmount - chargedFeeAmount, TwoPower.Pow128, st.liquidity);
                    amountX += (retState.costX + feeAmount);
                    amountY += retState.acquireY;
                    desireY = (desireY <= retState.acquireY) ? 0 : desireY - uint128(retState.acquireY);
                    st.currentPoint = retState.finalPt;
                    st.sqrtPrice_96 = retState.sqrtFinalPrice_96;
                    st.allX = retState.finalAllX;
                    st.currX = retState.finalCurrX;
                    st.currY = retState.finalCurrY;
                }
                if (!cache.finished) {
                    Point.Data storage pointdata = points[st.currentPoint];
                    pointdata.passEndpoint(cache.currFeeScaleX_128, cache.currFeeScaleY_128);
                    st.liquidity = liquidityAddDelta(st.liquidity, - pointdata.liquidDelta);
                    st.currentPoint = st.currentPoint - 1;
                    st.sqrtPrice_96 = LogPowMath.getSqrtPrice(st.currentPoint);
                    st.allX = false;
                    st.currX = 0;
                    st.currY = MulDivMath.mulDivFloor(st.liquidity, st.sqrtPrice_96, TwoPower.Pow96);
                }
            }
            if (cache.finished || st.currentPoint < lowPt) {
                break;
            }
            int24 nextPt = pointBitmap.nearestLeftOneOrBoundary(searchStart, cache.pointDelta);
            if (nextPt < lowPt) {
                nextPt = lowPt;
            }
            int24 nextVal = getOrderOrEndptValue(nextPt, cache.pointDelta);
            // in [st.currentPoint, nextPt)
            if (st.liquidity == 0) {

                // no liquidity in the range [nextPt, st.currentPoint]
                st.currentPoint = nextPt;
                st.sqrtPrice_96 = LogPowMath.getSqrtPrice(st.currentPoint);
                st.allX = true;
                cache.currentOrderOrEndpt = nextVal;
            } else {
                // amount > 0
                // if (desireY > 0) {
                    SwapMathX2YDesire.RangeRetState memory retState = SwapMathX2YDesire.x2YRange(
                        st, nextPt, cache._sqrtRate_96, desireY
                    );
                    cache.finished = retState.finished;
                    
                    uint256 feeAmount = MulDivMath.mulDivCeil(retState.costX, fee, 1e6);
                    uint256 chargedFeeAmount = feeAmount * feeChargePercent / 100;
                    totalFeeXCharged += chargedFeeAmount;

                    amountY += retState.acquireY;
                    amountX += (retState.costX + feeAmount);
                    desireY = (desireY <= retState.acquireY) ? 0 : desireY - uint128(retState.acquireY);
                    
                    cache.currFeeScaleX_128 = cache.currFeeScaleX_128 + MulDivMath.mulDivFloor(feeAmount - chargedFeeAmount, TwoPower.Pow128, st.liquidity);

                    st.currentPoint = retState.finalPt;
                    st.sqrtPrice_96 = retState.sqrtFinalPrice_96;
                    st.allX = retState.finalAllX;
                    st.currX = retState.finalCurrX;
                    st.currY = retState.finalCurrY;
                // } else {
                //     cache.finished = true;
                // }
                if (st.currentPoint == nextPt) {
                    cache.currentOrderOrEndpt = nextVal;
                } else {
                    // not necessary, because finished must be true
                    cache.currentOrderOrEndpt = 0;
                }
            }
            if (st.currentPoint <= lowPt) {
                break;
            }
        }
        if (cache.startPoint != st.currentPoint) {
            (st.observationCurrentIndex, st.observationQueueLen) = observations.append(
                st.observationCurrentIndex,
                cache.timestamp,
                cache.startPoint,
                cache.startLiquidity,
                st.observationQueueLen,
                st.observationNextQueueLen
            );
        }

        // write back fee scale, no fee of y
        feeScaleX_128 = cache.currFeeScaleX_128;
        // write back state
        state = st;
        // transfer y to trader
        if (amountY > 0) {
            TokenTransfer.transferToken(tokenY, recipient, amountY);
            // trader pay x
            require(amountX > 0, "PP");
            uint256 bx = balanceX();
            IiZiSwapCallback(msg.sender).swapX2YCallback(amountX, amountY, data);
            require(balanceX() >= bx + amountX, "XE");
        }
    }
}