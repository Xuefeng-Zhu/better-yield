// SPDX-License-Identifier: MIT

pragma solidity ^0.6.11;
pragma experimental ABIEncoderV2;

import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/math/MathUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";

import "../interfaces/badger/IController.sol";
import "../interfaces/compound/ICErc20.sol";
import "../interfaces/compound/IComptroller.sol";
import "../interfaces/uniswap/IUniswapRouterV2.sol";

import {BaseStrategy} from "../deps/BaseStrategy.sol";

contract MyStrategy is BaseStrategy {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;
    using SafeMathUpgradeable for uint256;

    // address public want // Inherited from BaseStrategy, the token the strategy wants, swaps into and tries to grow
    ICErc20 public cErc20; // Token we provide liquidity with
    IERC20Upgradeable public reward; // Token we farm and swap to want / cErc20
    uint256 public leveragePercent;

    address public constant WETH = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    IComptroller public constant COMPTROLLER =
        IComptroller(0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B);
    IUniswapRouterV2 public constant DEX =
        IUniswapRouterV2(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    function initialize(
        address _governance,
        address _strategist,
        address _controller,
        address _keeper,
        address _guardian,
        address[3] memory _wantConfig,
        uint256[3] memory _feeConfig
    ) public initializer {
        __BaseStrategy_init(
            _governance,
            _strategist,
            _controller,
            _keeper,
            _guardian
        );

        /// @dev Add config here
        want = _wantConfig[0];
        cErc20 = ICErc20(_wantConfig[1]);
        reward = IERC20Upgradeable(_wantConfig[2]);

        performanceFeeGovernance = _feeConfig[0];
        performanceFeeStrategist = _feeConfig[1];
        withdrawalFee = _feeConfig[2];

        leveragePercent = 50;

        /// @dev do one off approvals here
        IERC20Upgradeable(want).safeApprove(cErc20, type(uint256).max);

        reward.safeApprove(address(DEX), type(uint256).max);

        address[] memory cTokens = new address[](1);
        cTokens[0] = address(cErc20);
        COMPTROLLER.enterMarkets(cTokens);
    }

    /// ===== View Functions =====

    // @dev Specify the name of the strategy
    function getName() external pure override returns (string memory) {
        return "LeveragedCompoundWBTCStrategy";
    }

    // @dev Specify the version of the Strategy, for upgrades
    function version() external pure returns (string memory) {
        return "1.0";
    }

    /// @dev Balance of want currently held in strategy positions
    function balanceOfPool() public view override returns (uint256) {
        return IERC20Upgradeable(cErc20).balanceOf(address(this));
    }

    /// @dev Returns true if this strategy requires tending
    function isTendable() public view override returns (bool) {
        return balanceOfWant() > 0;
    }

    // @dev These are the tokens that cannot be moved except by the vault
    function getProtectedTokens()
        public
        view
        override
        returns (address[] memory)
    {
        address[] memory protectedTokens = new address[](3);
        protectedTokens[0] = want;
        protectedTokens[1] = address(cErc20);
        protectedTokens[2] = address(reward);
        return protectedTokens;
    }

    /// ===== Permissioned Actions: Governance =====
    /// @notice Delete if you don't need!
    function setKeepReward(uint256 _setKeepReward) external {
        _onlyGovernance();
    }

    /// ===== Internal Core Implementations =====

    /// @dev security check to avoid moving tokens that would cause a rugpull, edit based on strat
    function _onlyNotProtectedTokens(address _asset) internal override {
        address[] memory protectedTokens = getProtectedTokens();

        for (uint256 x = 0; x < protectedTokens.length; x++) {
            require(
                address(protectedTokens[x]) != _asset,
                "Asset is protected"
            );
        }
    }

    /// @dev invest the amount of want
    /// @notice When this function is called, the controller has already sent want to this
    /// @notice Just get the current balance and then invest accordingly
    function _deposit(uint256 _amount) internal override {
        ICErc20(cErc20).mint(_amount);
        _borrow();
    }

    function _borrow() internal {
        uint256 borrowBalance = cErc20.borrowBalanceCurrent(address(this));
        uint256 baseCollateral = cErc20.balanceOfUnderlying(address(this)).sub(
            borrowBalance
        );
        uint256 canBorrowAmount = baseCollateral.mul(leveragePercent).div(100);

        if (borrowBalance > canBorrowAmount) {
            _repay(borrowBalance.sub(canBorrowAmount));
            return;
        }

        uint256 toBorrow = canBorrowAmount.sub(borrowBalance);
        cErc20.borrow(toBorrow);
        cErc20.mint(toBorrow);
    }

    /// @dev utility function to withdraw everything for migration
    function _withdrawAll() internal override {
        _withdrawSome(cErc20.balanceOfUnderlying(address(this)));
    }

    /// @dev withdraw the specified amount of want, liquidate from cErc20 to want, paying off any necessary debt for the conversion
    function _withdrawSome(uint256 _amount)
        internal
        override
        returns (uint256)
    {
        _repay(_amount.mul(leveragePercent).div(100));

        _amount = MathUpgradeable.min(
            _amount,
            cErc20.balanceOfUnderlying(address(this))
        );
        cErc20.redeemUnderlying(_amount);

        return _amount;
    }

    function _repay(uint256 _amount) internal {
        _amount = MathUpgradeable.min(
            _amount,
            cErc20.borrowBalanceCurrent(address(this))
        );
        cErc20.redeemUnderlying(_amount);
        cErc20.repayBorrow(_amount);
    }

    /// @dev Harvest from strategy mechanics, realizing increase in underlying position
    function harvest() external whenNotPaused returns (uint256 harvested) {
        _onlyAuthorizedActors();

        uint256 _before = IERC20Upgradeable(want).balanceOf(address(this));

        COMPTROLLER.claimComp(address(this));
        if (reward.balanceOf(address(this)) == 0) {
            return 0;
        }

        _swapComp();

        uint256 earned = IERC20Upgradeable(want).balanceOf(address(this)).sub(
            _before
        );

        /// @notice Keep this in so you get paid!
        (
            uint256 governancePerformanceFee,
            uint256 strategistPerformanceFee
        ) = _processPerformanceFees(earned);

        /// @dev Harvest event that every strategy MUST have, see BaseStrategy
        emit Harvest(earned, block.number);

        return earned;
    }

    function _swapComp() internal {
        address[] memory paths = new address[](3);
        paths[0] = address(reward);
        paths[1] = WETH;
        paths[2] = want;

        DEX.swapExactTokensForTokens(
            reward.balanceOf(address(this)),
            uint256(0),
            paths,
            address(this),
            now
        );
    }

    // Alternative Harvest with Price received from harvester, used to avoid exessive front-running
    function harvest(uint256 price)
        external
        whenNotPaused
        returns (uint256 harvested)
    {}

    /// @dev Rebalance, Compound or Pay off debt here
    function tend() external whenNotPaused {
        _onlyAuthorizedActors();
        _deposit(balanceOfWant());
    }

    /// ===== Internal Helper Functions =====

    /// @dev used to manage the governance and strategist fee, make sure to use it to get paid!
    function _processPerformanceFees(uint256 _amount)
        internal
        returns (
            uint256 governancePerformanceFee,
            uint256 strategistPerformanceFee
        )
    {
        governancePerformanceFee = _processFee(
            want,
            _amount,
            performanceFeeGovernance,
            IController(controller).rewards()
        );

        strategistPerformanceFee = _processFee(
            want,
            _amount,
            performanceFeeStrategist,
            strategist
        );
    }
}
