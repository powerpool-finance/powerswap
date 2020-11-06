
pragma solidity 0.6.12;

import "../balancer-core/BPool.sol";

contract PiDynamicBPool is BPool {

    /// @notice The event emitted when a dynamic weight set to token
    event SetDynamicWeight(
        address indexed token,
        uint fromDenorm,
        uint targetDenorm,
        uint fromTimestamp,
        uint targetTimestamp
    );

    /// @notice The event emitted when weight per second bounds set
    event SetWeightPerSecondBounds(uint minWeightPerSecond, uint maxWeightPerSecond);

    struct DynamicWeight {
        uint fromTimestamp;
        uint targetTimestamp;
        uint targetDenorm;
    }

    /// @notice Mapping for storing dynamic weights settings. fromDenorm stored in _records mapping as denorm variable
    mapping(address => DynamicWeight) private _dynamicWeights;

    /// @notice Min weight per second limit
    uint256 private _minWeightPerSecond;
    /// @notice Max weight per second limit
    uint256 private _maxWeightPerSecond;

    constructor(string memory name, string memory symbol, uint minWeightPerSecond, uint maxWeightPerSecond)
        public
        BPool(name, symbol)
    {
        _minWeightPerSecond = minWeightPerSecond;
        _maxWeightPerSecond = maxWeightPerSecond;
    }

    /*** Controller Interface ***/

    /**
    * @notice Set weight per second bounds by controller
    * @param minWeightPerSecond Min weight per second
    * @param maxWeightPerSecond Max weight per second
    */
    function setWeightPerSecondBounds(uint minWeightPerSecond, uint maxWeightPerSecond)
        public
        _logs_
        _lock_
    {
        _checkController();
        _minWeightPerSecond = minWeightPerSecond;
        _maxWeightPerSecond = maxWeightPerSecond;

        emit SetWeightPerSecondBounds(minWeightPerSecond, maxWeightPerSecond);
    }

    /**
    * @notice Set dynamic weight for token by controller
    * @param token Token for change settings
    * @param targetDenorm Target weight. fromDenorm will be fetch by current value of _getDenormWeight
    * @param fromTimestamp From timestamp of dynamic weight
    * @param targetTimestamp Target timestamp of dynamic weight
    */
    function setDynamicWeight(
        address token,
        uint targetDenorm,
        uint fromTimestamp,
        uint targetTimestamp
    )
        public
        _logs_
        _lock_
    {
        _checkController();
        _checkBound(token);

        require(fromTimestamp > block.timestamp, "CANT_SET_PAST_TIMESTAMP");
        require(targetTimestamp >= fromTimestamp, "TIMESTAMP_NEGATIVE_DELTA");
        require(targetDenorm >= MIN_WEIGHT && targetDenorm <= MAX_WEIGHT, "TARGET_WEIGHT_BOUNDS");

        uint256 fromDenorm = _getDenormWeight(token);
        uint256 weightPerSecond = _getWeightPerSecond(fromDenorm, targetDenorm, fromTimestamp, targetTimestamp);
        require(weightPerSecond <= _maxWeightPerSecond, "MAX_WEIGHT_PER_SECOND");
        require(weightPerSecond >= _minWeightPerSecond, "MIN_WEIGHT_PER_SECOND");

        _records[token].denorm = fromDenorm;

        _dynamicWeights[token] = DynamicWeight({
            fromTimestamp: fromTimestamp,
            targetTimestamp: targetTimestamp,
            targetDenorm: targetDenorm
        });

        uint256 denormSum = 0;
        uint256 len = _tokens.length;
        for (uint256 i = 0; i < len; i++) {
            denormSum = badd(denormSum, _dynamicWeights[_tokens[i]].targetDenorm);
        }

        require(denormSum <= MAX_TOTAL_WEIGHT, "MAX_TARGET_TOTAL_WEIGHT");

        emit SetDynamicWeight(token, _records[token].denorm, targetDenorm, fromTimestamp, targetTimestamp);
    }

    /**
    * @notice Bind and setDynamicWeight at the same time
    * @param token Token for bind
    * @param balance Initial balance
    * @param targetDenorm Target weight
    * @param fromTimestamp From timestamp of dynamic weight
    * @param targetTimestamp Target timestamp of dynamic weight
    */
    function bind(address token, uint balance, uint targetDenorm, uint fromTimestamp, uint targetTimestamp)
        external
        _logs_
        // _lock_  Bind does not lock because it jumps to `rebind` and `setDynamicWeight`, which does
    {
        super.bind(token, balance, MIN_WEIGHT);

        setDynamicWeight(token, targetDenorm, fromTimestamp, targetTimestamp);
    }

    /**
    * @notice Override parent unbind function
    * @param token Token for unbind
    */
    function unbind(address token) public override {
        _totalWeight = _getTotalWeight(); // for compatibility with original BPool unbind
        super.unbind(token);

        _dynamicWeights[token] = DynamicWeight(0, 0, 0);
    }

    /**
    * @notice Override parent bind function and disable.
    */
    function bind(address token, uint balance, uint denorm) public override {
        require(false, "DISABLED"); // Only new bind function is allowed
    }

    /**
    * @notice Override parent rebind function. Allowed only for calling from bind function
    * @param token Token for rebind
    * @param balance Balance for rebind
    * @param denorm Weight for rebind
    */
    function rebind(address token, uint balance, uint denorm) public override {
        require(denorm == MIN_WEIGHT && _dynamicWeights[token].fromTimestamp == 0, "ONLY_NEW_TOKENS_ALLOWED");
        super.rebind(token, balance, denorm);
    }

    /*** View Functions ***/

    function getDynamicWeightSettings(address token) external view returns (
        uint fromTimestamp,
        uint targetTimestamp,
        uint fromDenorm,
        uint targetDenorm
    ) {
        DynamicWeight storage dw = _dynamicWeights[token];
        return (dw.fromTimestamp, dw.targetTimestamp, _records[token].denorm, dw.targetDenorm);
    }

    function getWeightPerSecondBounds() external view returns(uint minWeightPerSecond, uint maxWeightPerSecond) {
        return (_minWeightPerSecond, _maxWeightPerSecond);
    }

    /*** Internal Functions ***/

    function _getDenormWeight(address token)
        internal view override
        returns (uint)
    {
        DynamicWeight storage dw = _dynamicWeights[token];
        if (dw.fromTimestamp == 0 || dw.targetDenorm == _records[token].denorm || block.timestamp <= dw.fromTimestamp) {
            return _records[token].denorm;
        }
        if (block.timestamp >= dw.targetTimestamp) {
            return dw.targetDenorm;
        }

        uint256 weightPerSecond = _getWeightPerSecond(
            _records[token].denorm,
            dw.targetDenorm,
            dw.fromTimestamp,
            dw.targetTimestamp
        );
        uint256 deltaCurrentTime = bsub(block.timestamp, dw.fromTimestamp);
        if (dw.targetDenorm > _records[token].denorm) {
            return badd(_records[token].denorm, deltaCurrentTime * weightPerSecond);
        } else {
            return bsub(_records[token].denorm, deltaCurrentTime * weightPerSecond);
        }
    }

    function _getWeightPerSecond(
        uint256 fromDenorm,
        uint256 targetDenorm,
        uint256 fromTimestamp,
        uint256 targetTimestamp
    ) internal view returns (uint) {
        uint256 delta = targetDenorm > fromDenorm ? bsub(targetDenorm, fromDenorm) : bsub(fromDenorm, targetDenorm);
        return delta / bsub(targetTimestamp, fromTimestamp);
    }

    function _getTotalWeight()
        internal view override
        returns (uint)
    {
        uint256 sum = 0;
        uint256 len = _tokens.length;
        for (uint256 i = 0; i < len; i++) {
            sum = badd(sum, _getDenormWeight(_tokens[i]));
        }
        return sum;
    }
}