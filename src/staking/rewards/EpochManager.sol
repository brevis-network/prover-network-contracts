// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@security/access/AccessControl.sol";

abstract contract EpochManager is AccessControl {
    // f6c9577ec051004416f650ed5cde59ebe31c63663b16e28b9da8cda95777240c
    bytes32 public constant EPOCH_UPDATER_ROLE = keccak256("EPOCH_UPDATER_ROLE");

    uint64 public startTimestamp;

    struct EpochConfig {
        uint32 fromEpoch; // The epoch from which this configuration is effective
        uint64 fromTime; // The timestamp from which this configuration is effective
        uint64 epochLength; // Length of each epoch in seconds
        uint256 maxEpochReward; // Maximum reward distributed per epoch
    }

    // Array of epoch configurations sorted by `fromTime` in ascending order.
    //
    // To determine the active epoch configuration at a given time, select the most recent
    // EpochConfig with `fromTime <= current time`.
    //
    // The EpochUpdater can schedule future epoch changes by appending new entries.
    // The contract ensures `fromEpoch` and `fromTime` values are consistent and non-conflicting.
    //
    // Example:
    //   [EpochConfig(e1, t1, len1, r1), EpochConfig(e2, t2, len2, r2), EpochConfig(e3, t3, len3, r3)]
    //   - Configuration (len1, r1) is active from t1 to just before t2
    //   - Configuration (len2, r2) is active from t2 to just before t3
    //   - Configuration (len3, r3) becomes active at t3 and after
    EpochConfig[] public epochConfigs;

    event EpochConfigSet(uint32 fromEpoch, uint64 fromTime, uint64 epochLength, uint256 maxEpochReward);
    event EpochConfigPopped(uint32 fromEpoch, uint64 fromTime, uint64 epochLength, uint256 maxEpochReward);

    error EpochManagerNotInitialized();
    error EpochManagerAlreadyInitialized();
    error EpochManagerInvalidEpochNumber();
    error EpochManagerInvalidInitParams();
    error EpochManagerInvalidFromEpoch(uint32 providedEpoch);
    error EpochManagerInvalidEpochLength(uint64 providedLength);
    error EpochManagerInvalidMaxReward(uint256 providedReward);
    error EpochManagerInvalidFromTime(uint64 providedTime, uint64 lastConfiguredTime);
    error EpochManagerNoConfigs();
    error EpochManagerFirstConfigMustStartAtOne();
    error EpochManagerFromEpochNotIncreasing(uint32 lastFromEpoch, uint32 newFromEpoch);

    // ========================== Getters =========================

    function getCurrentEpochInfo()
        public
        view
        returns (uint32 currentEpoch, uint64 epochLength, uint256 maxEpochReward)
    {
        return getEpochInfoByTimestamp(uint64(block.timestamp));
    }

    function getEpochInfoByTimestamp(uint64 timestamp)
        public
        view
        returns (uint32 currentEpoch, uint64 epochLength, uint256 maxEpochReward)
    {
        if (epochConfigs.length == 0) {
            revert EpochManagerNoConfigs();
        }
        for (uint256 i = epochConfigs.length; i > 0; i--) {
            EpochConfig storage config = epochConfigs[i - 1];
            if (timestamp >= config.fromTime) {
                uint64 elapsed = timestamp - config.fromTime;
                uint64 epochsDelta = elapsed / config.epochLength;
                currentEpoch = config.fromEpoch + uint32(epochsDelta);
                return (currentEpoch, config.epochLength, config.maxEpochReward);
            }
        }
        revert EpochManagerInvalidEpochNumber();
    }

    function getEpochInfoByEpochNumber(uint32 epoch)
        public
        view
        returns (uint64 epochStartTime, uint64 epochLength, uint256 maxEpochReward)
    {
        if (epoch == 0) revert EpochManagerInvalidEpochNumber();
        if (epochConfigs.length == 0) {
            revert EpochManagerNoConfigs();
        }
        for (uint256 i = epochConfigs.length; i > 0; i--) {
            EpochConfig storage config = epochConfigs[i - 1];
            if (epoch >= config.fromEpoch) {
                uint32 epochsDelta = epoch - config.fromEpoch;
                epochStartTime = config.fromTime + uint64(epochsDelta) * config.epochLength;
                return (epochStartTime, config.epochLength, config.maxEpochReward);
            }
        }
        revert EpochManagerInvalidEpochNumber();
    }

    function getEpochConfigs() public view returns (EpochConfig[] memory) {
        return epochConfigs;
    }

    function getEpochConfigNumber() public view returns (uint256) {
        return epochConfigs.length;
    }

    // ========================== Setters ==========================

    function initEpoch(uint64 _startTimestamp, uint64 _epochLength, uint256 _maxEpochReward)
        external
        onlyRole(EPOCH_UPDATER_ROLE)
    {
        _initEpoch(_startTimestamp, _epochLength, _maxEpochReward);
    }

    function setEpochConfig(uint32 fromEpoch, uint64 epochLength, uint256 maxEpochReward)
        external
        onlyRole(EPOCH_UPDATER_ROLE)
    {
        _setEpochConfig(fromEpoch, epochLength, maxEpochReward);
    }

    // Set epoch config by specifying a target time. The function calculates the corresponding
    // epoch number and ensures the config starts at the beginning of that epoch boundary.
    function setEpochConfigByTime(uint64 fromTime, uint64 epochLength, uint256 maxEpochReward)
        external
        onlyRole(EPOCH_UPDATER_ROLE)
    {
        if (epochConfigs.length == 0) revert EpochManagerNotInitialized();

        // find the fromEpoch based on fromTime
        EpochConfig storage last = epochConfigs[epochConfigs.length - 1];
        if (fromTime <= last.fromTime) revert EpochManagerInvalidFromTime(fromTime, last.fromTime);
        uint64 epochsDelta = (fromTime - last.fromTime) / last.epochLength;
        uint32 fromEpoch = last.fromEpoch + uint32(epochsDelta);

        _setEpochConfig(fromEpoch, epochLength, maxEpochReward);
    }

    function popEpochConfig() external onlyRole(EPOCH_UPDATER_ROLE) {
        if (epochConfigs.length == 0) revert EpochManagerNoConfigs();
        EpochConfig memory lastConfig = epochConfigs[epochConfigs.length - 1];
        epochConfigs.pop();
        emit EpochConfigPopped(
            lastConfig.fromEpoch, lastConfig.fromTime, lastConfig.epochLength, lastConfig.maxEpochReward
        );
    }

    // Pop all future epoch configs that have not yet started based on the current time.
    // This is useful to overwrite future epoch configurations.
    function popFutureEpochConfigs() external onlyRole(EPOCH_UPDATER_ROLE) {
        if (epochConfigs.length == 0) revert EpochManagerNoConfigs();
        uint64 currentTime = uint64(block.timestamp);
        while (epochConfigs.length > 0 && epochConfigs[epochConfigs.length - 1].fromTime > currentTime) {
            EpochConfig memory lastConfig = epochConfigs[epochConfigs.length - 1];
            epochConfigs.pop();
            emit EpochConfigPopped(
                lastConfig.fromEpoch, lastConfig.fromTime, lastConfig.epochLength, lastConfig.maxEpochReward
            );
        }
    }

    // ========================== Internal Functions ==========================

    function _initEpoch(uint64 _startTimestamp, uint64 _epochLength, uint256 _maxEpochReward) internal {
        if (startTimestamp != 0) revert EpochManagerAlreadyInitialized();
        if (_startTimestamp == 0 || _epochLength == 0 || _maxEpochReward == 0) revert EpochManagerInvalidInitParams();
        startTimestamp = _startTimestamp;
        _setEpochConfig(1, _epochLength, _maxEpochReward);
    }

    function _setEpochConfig(uint32 fromEpoch, uint64 epochLength, uint256 maxEpochReward) internal {
        if (fromEpoch == 0) revert EpochManagerInvalidFromEpoch(fromEpoch);
        if (epochLength == 0) revert EpochManagerInvalidEpochLength(epochLength);
        if (maxEpochReward == 0) revert EpochManagerInvalidMaxReward(maxEpochReward);

        uint64 fromTime = _computeFromTime(fromEpoch);
        epochConfigs.push(
            EpochConfig({
                fromEpoch: fromEpoch,
                fromTime: fromTime,
                epochLength: epochLength,
                maxEpochReward: maxEpochReward
            })
        );
        emit EpochConfigSet(fromEpoch, fromTime, epochLength, maxEpochReward);
    }

    function _computeFromTime(uint32 fromEpoch) internal view returns (uint64) {
        uint256 len = epochConfigs.length;
        if (len == 0) {
            // If no configs, use startTimestamp as the base
            if (fromEpoch != 1) revert EpochManagerFirstConfigMustStartAtOne();
            return startTimestamp;
        }
        EpochConfig storage last = epochConfigs[len - 1];
        if (fromEpoch <= last.fromEpoch) revert EpochManagerFromEpochNotIncreasing(last.fromEpoch, fromEpoch);
        uint32 epochsDelta = fromEpoch - last.fromEpoch;
        return last.fromTime + uint64(epochsDelta) * last.epochLength;
    }
}
