// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../src/staking/helpers/StakingHelper.sol";
import "../../src/staking/controller/StakingController.sol";
import "../../src/staking/vault/VaultFactory.sol";
import "../../src/token/WrappedNativeToken.sol";
import "../mocks/MockERC20.sol";

contract MockBrevisProof {
    struct ProofData {
        bytes32 vkHash;
        bytes32 appCommitHash;
    }

    mapping(bytes32 => ProofData) public proofs;

    function submitProof(uint64, bytes calldata proof)
        external
        returns (bytes32 proofId, bytes32 appCommitHash, bytes32 appVkHash)
    {
        proofId = keccak256(abi.encode(block.timestamp, msg.sender, proof));
        appCommitHash = bytes32(uint256(1));
        appVkHash = bytes32(uint256(2));
        proofs[proofId] = ProofData({vkHash: appVkHash, appCommitHash: appCommitHash});
    }

    function validateRequest(bytes32 proofId, bytes32 expectedAppCommitHash) external view returns (bool) {
        return proofs[proofId].appCommitHash == expectedAppCommitHash;
    }
}

contract StakingHelperTest is Test {
    StakingController public controller;
    WrappedNativeToken public wrappedToken;
    StakingHelper public helper;
    VaultFactory public vaultFactory;
    MockBrevisProof public brevisProof;

    address public prover = address(0x1);
    address public staker = address(0x2);
    address public feeCollector = address(0x3);

    function setUp() public {
        // Deploy wrapped token
        wrappedToken = new WrappedNativeToken("Wrapped Native", "WNATIVE");

        // Deploy brevisProof mock
        brevisProof = new MockBrevisProof();

        // Deploy vault factory
        vaultFactory = new VaultFactory();

        // Deploy controller
        controller = new StakingController(
            address(wrappedToken),
            address(vaultFactory),
            7 days, // unstake delay
            1e18, // min self stake
            5000 // max slash bps
        );

        // Initialize vault factory with controller
        vaultFactory.init(address(controller));

        // Deploy helper
        helper = new StakingHelper(address(controller), payable(address(wrappedToken)));

        // Give test accounts some native tokens
        vm.deal(prover, 100 ether);
        vm.deal(staker, 100 ether);

        // Wrap tokens for prover to meet minimum self-stake
        vm.startPrank(prover);
        wrappedToken.deposit{value: 10 ether}();
        wrappedToken.approve(address(controller), 10 ether);

        // Initialize prover
        controller.initializeProver(1000);
        vm.stopPrank();
    }

    function testStakeNative() public {
        uint256 stakeAmount = 10 ether;

        vm.prank(staker);
        uint256 shares = helper.stakeNative{value: stakeAmount}(prover);

        assertGt(shares, 0, "Should receive shares");
        assertEq(staker.balance, 90 ether, "Staker should have 90 ETH left");

        // Check staker has shares in the vault
        (, address vault,,,,,,) = controller.getProverInfo(prover);
        assertEq(IERC20(vault).balanceOf(staker), shares, "Staker should have shares in vault");
    }

    function testCompleteUnstakeNative() public {
        // First stake
        uint256 stakeAmount = 10 ether;
        vm.prank(staker);
        uint256 shares = helper.stakeNative{value: stakeAmount}(prover);

        // Get vault address and approve controller to spend shares
        (, address vault,,,,,,) = controller.getProverInfo(prover);
        vm.prank(staker);
        IERC20(vault).approve(address(controller), shares);

        // Request unstake
        vm.prank(staker);
        controller.requestUnstake(prover, stakeAmount);

        // Fast forward past unstake delay
        skip(controller.unstakeDelay() + 1);

        // Complete unstake and receive native tokens
        uint256 balanceBefore = staker.balance;
        uint256 helperBalanceBefore = address(helper).balance;
        vm.prank(staker);
        uint256 amount = helper.completeUnstakeNative(prover);

        assertEq(amount, stakeAmount, "Should receive full stake amount");
        assertEq(address(helper).balance, helperBalanceBefore, "Helper should not hold any ETH");
        assertEq(staker.balance, balanceBefore + stakeAmount, "Should receive native tokens");
    }

    function testReceiveAutoStake() public {
        uint256 stakeAmount = 5 ether;

        // Send native tokens directly to helper with prover as sender
        vm.prank(prover);
        (bool success,) = address(helper).call{value: stakeAmount}("");
        assertTrue(success, "Transfer should succeed");

        // Check prover has shares (self-stake)
        (, address vault,,,,,,) = controller.getProverInfo(prover);
        assertGt(IERC20(vault).balanceOf(prover), 0, "Prover should have shares");
    }
}
