// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IProverVault.sol";
import "../interfaces/IStakingController.sol";

/**
 * @title ProverVault
 * @notice ERC4626 vault for individual prover staking with controller integration
 */
contract ProverVault is ERC4626, ReentrancyGuard, IProverVault {
    using SafeERC20 for IERC20;
    // =========================================================================
    // IMMUTABLE STORAGE
    // =========================================================================

    address public immutable override prover;
    address public immutable override controller;

    // =========================================================================
    // STORAGE
    // =========================================================================

    // Note: Lock state is maintained by the controller, not the vault
    // The vault queries the controller for all lock-related information

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    constructor(IERC20 asset_, string memory name_, string memory symbol_, address prover_, address controller_)
        ERC20(name_, symbol_)
        ERC4626(asset_)
    {
        prover = prover_;
        controller = controller_;
    }

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    modifier onlyController() {
        if (msg.sender != controller) revert VaultOnlyController();
        _;
    }

    // =========================================================================
    // ERC4626 OVERRIDES (GATED)
    // =========================================================================

    /**
     * @notice Maximum assets withdrawable by owner (locked shares excluded)
     * @param owner The account whose shares to check for withdrawal limits
     */
    function maxWithdraw(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        return IStakingController(controller).maxWithdraw(prover, owner);
    }

    /**
     * @notice Maximum shares redeemable by owner (locked shares excluded)
     * @param owner The account whose shares to check for redemption limits
     */
    function maxRedeem(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        return IStakingController(controller).maxRedeem(prover, owner);
    }

    /**
     * @notice Maximum assets that can be deposited (surface controller limits to integrators)
     * @param receiver The address receiving shares
     */
    function maxDeposit(address receiver) public view override(ERC4626, IERC4626) returns (uint256) {
        // Query controller for deposit limits (pause, jail, etc.)
        return IStakingController(controller).maxDeposit(prover, receiver);
    }

    /**
     * @notice Maximum shares that can be minted (surface controller limits to integrators)
     * @param receiver The address receiving shares
     */
    function maxMint(address receiver) public view override(ERC4626, IERC4626) returns (uint256) {
        // Query controller for mint limits (pause, jail, etc.)
        return IStakingController(controller).maxMint(prover, receiver);
    }

    /**
     * @notice Deposit assets and receive shares (controller only)
     */
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IERC4626)
        onlyController
        nonReentrant
        returns (uint256 shares)
    {
        shares = super.deposit(assets, receiver);
    }

    /**
     * @notice Mint shares by providing assets (controller only)
     * @dev Currently not used by controller
     */
    function mint(uint256 shares, address receiver)
        public
        override(ERC4626, IERC4626)
        onlyController
        nonReentrant
        returns (uint256 assets)
    {
        assets = super.mint(shares, receiver);
    }

    /**
     * @notice Withdraw assets by burning shares (controller only)
     * @dev Currently not used by controller
     */
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        onlyController
        nonReentrant
        returns (uint256 shares)
    {
        shares = super.withdraw(assets, receiver, owner);
    }

    /**
     * @notice Redeem shares for assets (controller only)
     */
    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        onlyController
        nonReentrant
        returns (uint256 assets)
    {
        assets = super.redeem(shares, receiver, owner);
    }

    // =========================================================================
    // SHARE TRANSFER OVERRIDES
    // =========================================================================

    /**
     * @notice Override _update to prevent transfer of locked shares (owner-based enforcement)
     * @dev Critical: Locks apply to the share OWNER, not the caller (for ERC4626 allowance support)
     */
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            // This is a transfer (not mint/burn)

            // 1. Check transferable (unlocked) shares = balance - pending unstakes
            //    We intentionally DO NOT use controller.maxRedeem (which only includes matured unstake requests)
            //    because active staked shares should remain transferable except for the portion pending unstake.
            uint256 transferable = getTransferableShares(from);
            if (value > transferable) revert VaultSharesLocked();

            // 2. Additional controller policy checks (pause, jail, min self stake, etc.)
            IStakingController(controller).beforeShareTransfer(prover, from, value);
        } else if (from != address(0) && to == address(0)) {
            // This is a burn operation (redeem/withdraw)
            // Allow burning only up to matured (ready) unstake shares
            // Using controller.maxRedeem ensures we only burn shares whose delay elapsed
            uint256 redeemable = IStakingController(controller).maxRedeem(prover, from);
            if (value > redeemable) revert VaultSharesLocked();
        }

        super._update(from, to, value);

        // Notify controller for post-transfer accounting (covers transfer, mint, burn symmetry)
        // Mint: from == address(0); Burn: to == address(0); Both handled uniformly
        IStakingController(controller).onShareTransfer(prover, from, to, value);
    }

    // =========================================================================
    // CONTROLLER FUNCTIONS
    // =========================================================================

    /**
     * @notice Slash vault assets (controller only)
     */
    function controllerSlash(uint256 assets, address to) external override onlyController {
        // Transfer slashed assets to designated recipient
        IERC20(asset()).safeTransfer(to, assets);

        // Emit event for transparency
        emit ControllerSlash(assets, to);
    }

    // =========================================================================
    // VIEW FUNCTIONS
    // =========================================================================

    /**
     * @notice Get the transferable (unlocked) shares for an owner
     * @dev All shares are transferable since unstaking is handled by separate contract
     */
    function getTransferableShares(address owner) public view override returns (uint256) {
        // All vault shares are transferable since unstaking is handled separately
        return balanceOf(owner);
    }
}
