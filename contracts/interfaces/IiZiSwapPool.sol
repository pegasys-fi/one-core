pragma solidity ^0.8.4;

interface IiZiSwapPool {

    /// @notice Returns the information about a liquidity by the liquidity's key
    /// @param key The liquidity's key is a hash of a preimage composed by the miner(owner), pointLeft and pointRight
    /// @return liquidity The amount of liquidity,
    /// Returns lastFeeScaleX_128 fee growth of tokenX inside the range as of the last mint/burn/collect,
    /// Returns lastFeeScaleY_128 fee growth of tokenY inside the range as of the last mint/burn/collect,
    /// Returns remainFeeX the computed amount of tokenX miner can collect as of the last mint/burn/collect,
    /// Returns remainFeeY the computed amount of tokenY miner can collect as of the last mint/burn/collect
    function liquidities(bytes32 key)
        external
        view
        returns (
            uint128 liquidity,
            uint256 lastFeeScaleX_128,
            uint256 lastFeeScaleY_128,
            uint256 remainFeeX,
            uint256 remainFeeY
        );
    
    /// @notice return the information about a limit order (sell tokenY and earn tokenX)
    /// @param key the limit order's key is a hash of a preimage composed by the seller, point
    /// @return lastAccEarn total amount of tokenX earned by all users at this point as of the last add/dec/collect
    /// Returns sellingRemain amount of tokenY not selled in this limit order
    /// Returns sellingDec amount of tokenY decreased by seller from this limit order
    /// Returns earn amount of tokenX earned in this limit order not assigned
    /// Returns earnAssign assigned amount of tokenX earned in this limit order
    function userEarnX(bytes32 key)
        external
        view
        returns (
            uint256 lastAccEarn,
            uint256 sellingRemain,
            uint256 sellingDec,
            uint256 earn,
            uint256 earnAssign
        );
    
    /// @notice return the information about a limit order (sell tokenX and earn tokenY)
    /// @param key the limit order's key is a hash of a preimage composed by the seller, point
    /// @return lastAccEarn total amount of tokenY earned by all users at this point as of the last add/dec/collect
    /// Returns sellingRemain amount of tokenX not selled in this limit order
    /// Returns sellingDec amount of tokenX decreased by seller from this limit order
    /// Returns earn amount of tokenY earned in this limit order not assigned
    /// Returns earnAssign assigned amount of tokenY earned in this limit order
    function userEarnY(bytes32 key)
        external
        view
        returns (
            uint256 lastAccEarn,
            uint256 sellingRemain,
            uint256 sellingDec,
            uint256 earn,
            uint256 earnAssign
        );
    
    /// @notice mark a given amount of tokenY in a limitorder(sellx and earn y) as assigned
    /// @param point point (log Price) of seller's limit order,be sure to be times of pointDelta
    /// @param assignY max amount of tokenY to mark assigned
    /// @return actualAssignY actual amount of tokenY marked
    function assignLimOrderEarnY(
        int24 point,
        uint256 assignY
    ) external returns(uint256 actualAssignY);
    
    /// @notice mark a given amount of tokenX in a limitorder(selly and earn x) as assigned
    /// @param point point (log Price) of seller's limit order,be sure to be times of pointDelta
    /// @param assignX max amount of tokenX to mark assigned
    /// @return actualAssignX actual amount of tokenX marked
    function assignLimOrderEarnX(
        int24 point,
        uint256 assignX
    ) external returns(uint256 actualAssignX);

    /// @notice decrease limitorder of selling X
    /// @param point point of seller's limit order, be sure to be times of pointDelta
    /// @param deltaX max amount of tokenX seller wants to decrease
    /// @return actualDeltaX actual amount of tokenX decreased
    function decLimOrderWithX(
        int24 point,
        uint128 deltaX
    ) external returns (uint128 actualDeltaX);
    
    /// @notice decrease limitorder of selling Y
    /// @param point point of seller's limit order, be sure to be times of pointDelta
    /// @param deltaY max amount of tokenY seller wants to decrease
    /// @return actualDeltaY actual amount of tokenY decreased
    function decLimOrderWithY(
        int24 point,
        uint128 deltaY
    ) external returns (uint128 actualDeltaY);
    
    /// @notice add a limit order (selling x) in the pool
    /// @param recipient owner of the limit order
    /// @param point point of the order, be sure to be times of pointDelta
    /// @param amountX amount of tokenX to sell
    /// @param data Any data that should be passed through to the callback
    /// @return orderX actual added amount of tokenX
    /// Returns acquireY amount of tokenY acquired if there is a limit order to sell y before adding
    function addLimOrderWithX(
        address recipient,
        int24 point,
        uint128 amountX,
        bytes calldata data
    ) external returns (uint128 orderX, uint256 acquireY);

    /// @notice add a limit order (selling y) in the pool
    /// @param recipient owner of the limit order
    /// @param point point of the order, be sure to be times of pointDelta
    /// @param amountY amount of tokenY to sell
    /// @param data Any data that should be passed through to the callback
    /// @return orderY actual added amount of tokenY
    /// Returns acquireX amount of tokenX acquired if there exists a limit order to sell x before adding
    function addLimOrderWithY(
        address recipient,
        int24 point,
        uint128 amountY,
        bytes calldata data
    ) external returns (uint128 orderY, uint256 acquireX);

    /// @notice collect earned or decreased token from limit order
    /// @param recipient address to benefit
    /// @param point point of limit order, be sure to be times of pointDelta
    /// @param collectDec max amount of decreased selling token to collect
    /// @param collectEarn max amount of earned token to collect
    /// @param isEarnY direction of this limit order, true for sell y, false for sell x
    /// @return actualCollectDec actual amount of decresed selling token collected
    /// Returns actualCollectEarn actual amount of earned token collected
    function collectLimOrder(
        address recipient, int24 point, uint256 collectDec, uint256 collectEarn, bool isEarnY
    ) external returns(uint256 actualCollectDec, uint256 actualCollectEarn);

    /// @notice add liquidity to the pool
    /// @param recipient Newly created liquidity will belong to this address
    /// @param leftPt left endpoint of the liquidity, be sure to be times of pointDelta
    /// @param rightPt right endpoint of the liquidity, be sure to be times of pointDelta
    /// @param liquidDelta amount of liquidity to add
    /// @param data Any data that should be passed through to the callback
    /// @return amountX The amount of tokenX that was paid for the liquidity. Matches the value in the callback
    /// @return amountY The amount of tokenY that was paid for the liquidity. Matches the value in the callback
    function mint(
        address recipient,
        int24 leftPt,
        int24 rightPt,
        uint128 liquidDelta,
        bytes calldata data
    ) external returns (uint128 amountX, uint128 amountY);

    /// @notice decrease a given amount of liquidity from msg.sender's liquidities
    /// @param leftPt left endpoint of the liquidity
    /// @param rightPt right endpoint of the liquidity
    /// @param liquidDelta amount of liquidity to burn
    /// @return amountX The amount of tokenX should be refund after burn
    /// @return amountY The amount of tokenY should be refund after burn
    function burn(
        int24 leftPt,
        int24 rightPt,
        uint128 liquidDelta
    ) external returns (uint256 amountX, uint256 amountY);

    /// @notice Collects tokens (fee or refunded after burn) from a liquidity
    /// @param recipient The address which should receive the collected tokens
    /// @param leftPt left endpoint of the liquidity
    /// @param rightPt right endpoint of the liquidity
    /// @param amountXLim max amount of tokenX the owner wants to collect
    /// @param amountYLim max amount of tokenY the owner wants to collect
    /// @return actualAmountX The amount tokenX collected
    /// @return actualAmountY The amount tokenY collected
    function collect(
        address recipient,
        int24 leftPt,
        int24 rightPt,
        uint256 amountXLim,
        uint256 amountYLim
    ) external returns (uint256 actualAmountX, uint256 actualAmountY);

    /// @notice Swap tokenY for tokenX
    /// @param recipient The address to receive tokenY
    /// @param amount The max amount of tokenX user willing to pay
    /// @param highPt the highest point(price) of x/y during swap
    /// @param data Any data to be passed through to the callback
    /// @return amountX amount of tokenX payed
    /// @return amountY amount of tokenY acquired
    function swapY2X(
        address recipient,
        uint128 amount,
        int24 highPt,
        bytes calldata data
    ) external returns (uint256 amountX, uint256 amountY);
    
    function swapY2XDesireX(
        address recipient,
        uint128 desireX,
        int24 highPt,
        bytes calldata data
    ) external returns (uint256 amountX, uint256 amountY);
    
    
    function swapX2Y(
        address recipient,
        uint128 amount,
        int24 lowPt,
        bytes calldata data
    ) external returns (uint256 amountX, uint256 amountY);
    
    
    function swapX2YDesireY(
        address recipient,
        uint128 desireY,
        int24 highPt,
        bytes calldata data
    ) external returns (uint256 amountX, uint256 amountY);
    
    function state()
        external view
        returns(
            uint160 sqrtPrice_96,
            int24 currentPoint,
            uint256 currX,
            uint256 currY,
            uint128 liquidity,
            bool allX,
            uint16 observationCurrentIndex,
            uint16 observationQueueLen,
            uint16 observationNextQueueLen,
            bool locked
        );
    function sqrtRate_96() external view returns (uint160);
    function limitOrderData(int24 point)
        external view
        returns(
            uint256 sellingX,
            uint256 accEarnX,
            uint256 sellingY,
            uint256 accEarnY,
            uint256 earnX,
            uint256 earnY
        );
    function statusVal(int24) external returns(int24 val);
    function observations(uint256 index)
        external
        view
        returns (
            uint32 timestamp,
            int56 pointCumulative,
            uint160 secondsPerLiquidityCumulative_128,
            bool init
        );
    function points(int24 point)
        external
        view
        returns (
            uint128 liquidAcc,
            int128 liquidDelta,
            uint256 feeScaleXBeyond_128,
            uint256 feeScaleYBeyond_128,
            bool isEndpt
        );
    function pointBitmap(int16 wordPosition) external view returns (uint256);

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory pointCumulatives, uint160[] memory secondsPerLiquidityCumulative_128s);
}