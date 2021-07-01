// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

// Import interfaces for many popular DeFi projects, or add your own!
import "./interfaces/IIdleToken.sol";
import {IUniswapV2Router02} from "./interfaces/Uniswap.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    IIdleToken public daiIdle;
    IERC20 public dai;
    IERC20 public idle;
    IUniswapV2Router02 public uniRouter;

    address public weth;

    constructor(
        address _vault,
        address _weth,
        address _daiIdle,
        address _uniRouter
    ) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;
        weth = _weth;
        daiIdle = IIdleToken(_daiIdle);
        uniRouter = IUniswapV2Router02(_uniRouter);

        dai = IERC20(daiIdle.token());
        idle = IERC20(daiIdle.IDLE());

        dai.safeApprove(_daiIdle, uint256(-1));
        dai.safeApprove(_uniRouter, uint256(-1));
        idle.safeApprove(_uniRouter, uint256(-1));
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "StrategyIdleLUSD";
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfDai() public view returns (uint256) {
        return dai.balanceOf(address(this));
    }

    function balanceOfIdle() public view returns (uint256) {
        return idle.balanceOf(address(this));
    }

    function balanceOfDaiIdle() public view returns (uint256) {
        return IERC20(address(daiIdle)).balanceOf(address(this));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // TODO: Build a more accurate estimate using the value of all positions in terms of `want`
        return
            balanceOfWant() +
            balanceOfDai() +
            IERC20(address(daiIdle)).balanceOf(address(this));
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        daiIdle.redeemIdleToken(balanceOfDaiIdle());
        _swapIdle();

        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 assets = estimatedTotalAssets();

        if (debt > assets) {
            _loss = debt - assets;
        } else {
            _debtPayment = _debtOutstanding;
            _profit = assets - debt;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }

        uint256 wantBalance = balanceOfWant();
        // do not invest if we have more debt than want
        if (_debtOutstanding > wantBalance) {
            return;
        }

        // Swap the rest of the want
        uint256 wantAvailable = wantBalance.sub(_debtOutstanding);

        daiIdle.mintIdleToken(balanceOfDai(), false, address(0));
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 wantBalance = balanceOfWant();
        if (wantBalance < _amountNeeded) {
            _withdrawSome(_amountNeeded.sub(wantBalance));
        }

        wantBalance = balanceOfWant();
        if (_amountNeeded > wantBalance) {
            _liquidatedAmount = wantBalance;
            _loss = _amountNeeded.sub(wantBalance);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        // TODO: Liquidate all positions and return the amount freed.
        _withdrawSome(uint256(-1));
        return want.balanceOf(address(this));
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function prepareMigration(address _newStrategy) internal override {
        dai.transfer(_newStrategy, dai.balanceOf(address(this)));
        idle.transfer(_newStrategy, idle.balanceOf(address(this)));
        IERC20(address(daiIdle)).transfer(
            _newStrategy,
            IERC20(address(daiIdle)).balanceOf(address(this))
        );
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {
        address[] memory protected = new address[](3);
        protected[0] = address(daiIdle);
        protected[2] = address(dai);
        protected[1] = address(idle);
        return protected;
    }

    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        // TODO create an accurate price oracle
        return _amtInWei;
    }

    function _withdrawSome(uint256 _amount) internal returns (uint256) {
        uint256 balanceOfWantBefore = balanceOfWant();
        daiIdle.redeemIdleToken(_amount);
        return balanceOfWant().sub(balanceOfWantBefore);
    }

    function _swapIdle() internal {
        address[] memory path = new address[](3);
        path[0] = address(idle);
        path[1] = address(weth);
        path[2] = address(dai);

        uniRouter.swapExactTokensForTokens(
            balanceOfIdle(),
            uint256(0),
            path,
            address(this),
            now
        );
    }
}
