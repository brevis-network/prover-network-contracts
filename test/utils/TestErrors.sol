// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Helper library exposing custom error selectors for vm.expectRevert
library TestErrors {
    error MinSelfStakeZero();
    error InvalidCommission();
    error MinSelfStakeNotMet();
    error ZeroAmount();
    error ProverNotRegistered();
    error InvalidProverState();
    error InsufficientStake();
    error TooManyPendingUnstakes();
    error SelfStakeUnderflow();
    error NoStake();
    error NoPendingUnstakes();
    error NoReadyUnstakes();
    error SlashTooHigh();
    error ScaleTooLow();
    error NoMinStakeChange();
    error NoPendingMinStakeUpdate();
    error MinStakeDelay();
    error InvalidArg();
    error TreasuryInsufficient();
    error ActiveStakesRemain();
    error CommissionRemain();
    error InvalidScale();
    error NoRewards();
    // ProverRewards specific errors
    error RewardsInvalidCommission();
    error RewardsProverNotRegistered();
    error RewardsZeroAmount();
}
