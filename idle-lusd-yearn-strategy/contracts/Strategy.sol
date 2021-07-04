// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";

// Import interfaces for many popular DeFi projects, or add your own!
import "../interfaces/IIdleToken.sol";
import "../interfaces/IUmbrella.sol";
import "../interfaces/IChainlink.sol";
import "../interfaces/IDMM.sol";
import {IUniswapV2Router02} from "../interfaces/Uniswap.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    IIdleToken public daiIdle;
    IERC20 public dai;
    IERC20 public idle;
    IDMMExchangeRouter public dmmRouter;
    IUniswapV2Router02 public uniRouter;
    IChain public umbrella;
    AggregatorV3Interface public daiFeed;
    AggregatorV3Interface public ethFeed;

    address public weth;
    bool public useDmm;
    bool public useUmb;
    address[] public lusdDaiPools;
    address[] public lusdDaiPath;

    constructor(
        address _vault,
        address _lusd,
        address _weth,
        address _daiIdle,
        address _dmmRouter,
        address _uniRouter,
        address _umbrella,
        address _daiFeed,
        address _ethFeed
    ) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;
        require(address(want) == _lusd, "want needs to be lusd");

        weth = _weth;
        daiIdle = IIdleToken(_daiIdle);
        dmmRouter = IDMMExchangeRouter(_dmmRouter);
        uniRouter = IUniswapV2Router02(_uniRouter);
        umbrella = IChain(_umbrella);
        daiFeed = AggregatorV3Interface(_daiFeed);
        ethFeed = AggregatorV3Interface(_ethFeed);

        dai = IERC20(daiIdle.token());
        idle = IERC20(daiIdle.IDLE());

        want.safeApprove(_dmmRouter, uint256(-1));
        want.safeApprove(_uniRouter, uint256(-1));
        dai.safeApprove(_dmmRouter, uint256(-1));
        dai.safeApprove(_uniRouter, uint256(-1));
        idle.safeApprove(_uniRouter, uint256(-1));
        dai.safeApprove(_daiIdle, uint256(-1));

        useDmm = false;
        useUmb = false;
    }

    function setUseDmm(bool _useDmm) external onlyAuthorized {
        useDmm = _useDmm;
    }

    function setUseUmb(bool _useUmb) external onlyAuthorized {
        useUmb = _useUmb;
    }

    function setDmmPoolPath(
        address[] calldata _lusdDaiPools,
        address[] calldata _lusdDaiPath
    ) external onlyAuthorized {
        require(_lusdDaiPools.length + 1 == _lusdDaiPath.length);
        require(_lusdDaiPath[0] == address(want));
        require(_lusdDaiPath[_lusdDaiPath.length] == address(dai));

        delete lusdDaiPools;
        delete lusdDaiPath;

        for (uint256 i = 0; i < _lusdDaiPools.length; i++) {
            lusdDaiPools.push(_lusdDaiPools[i]);
            lusdDaiPath.push(_lusdDaiPath[i]);
        }

        lusdDaiPath.push(_lusdDaiPath[_lusdDaiPath.length - 1]);
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
        uint256 daiIdleValue =
            IERC20(address(daiIdle))
                .balanceOf(address(this))
                .mul(daiIdle.tokenPriceWithFee(address(this)))
                .div(_getDaiPrice());

        return balanceOfWant() + balanceOfDai() + daiIdleValue;
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
        daiIdle.redeemIdleToken(0);
        _swapIdleToDai();

        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 assets = estimatedTotalAssets();

        if (debt <= assets) {
            _debtPayment = _debtOutstanding;
            _profit = assets - debt;

            uint256 amountToFree = _profit.add(_debtPayment);

            if (balanceOfWant() < amountToFree) {
                _withdrawSome(amountToFree);

                uint256 wantBalance = balanceOfWant();
                if (wantBalance < amountToFree) {
                    if (_profit > wantBalance) {
                        _profit = wantBalance;
                        _debtPayment = 0;
                    } else {
                        _debtPayment = Math.min(
                            wantBalance.sub(_profit),
                            _debtPayment
                        );
                    }
                }
            }
        } else {
            _loss = debt - assets;
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
        _swapLusdToDai(wantAvailable);

        if (balanceOfDai() > 0) {
            daiIdle.mintIdleToken(balanceOfDai(), false, address(0));
        }
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
        if (useUmb) {
            (uint256 price, ) =
                umbrella.getCurrentValue(
                    0x000000000000000000000000000000000000000000000000004554482d555344
                );
            return price.mul(_amtInWei);
        }

        (, int256 price, , , ) = ethFeed.latestRoundData();
        return uint256(price).mul(10000000000).mul(_amtInWei);
    }

    function _getDaiPrice() internal view returns (uint256) {
        if (useUmb) {
            (uint256 price, ) =
                umbrella.getCurrentValue(
                    0x000000000000000000000000000000000000000000000000004441492d555344
                );
            return price;
        }

        (, int256 price, , , ) = daiFeed.latestRoundData();
        return uint256(price).mul(10000000000);
    }

    function _withdrawSome(uint256 _amount) internal returns (uint256) {
        uint256 balanceOfWantBefore = balanceOfWant();
        daiIdle.redeemIdleToken(
            _amount.mul(_getDaiPrice()).div(
                daiIdle.tokenPriceWithFee(address(this))
            )
        );

        _swapDaiToLusd(_amount);
        return balanceOfWant().sub(balanceOfWantBefore);
    }

    function _swapLusdToDai(uint256 _amount) internal {
        if (_amount == 0) {
            return;
        }

        if (useDmm) {
            address[] memory pools = new address[](lusdDaiPools.length);
            for (uint256 i = 0; i < lusdDaiPools.length; i++) {
                pools[i] = lusdDaiPools[i];
            }

            IERC20[] memory path = new IERC20[](lusdDaiPath.length);
            for (uint256 i = 0; i < lusdDaiPath.length; i++) {
                path[i] = IERC20(lusdDaiPath[i]);
            }

            dmmRouter.swapExactTokensForTokens(
                _amount,
                uint256(0),
                pools,
                path,
                address(this),
                now
            );
            return;
        }

        address[] memory path = new address[](2);
        path[0] = address(want);
        path[1] = address(dai);

        uniRouter.swapExactTokensForTokens(
            _amount,
            uint256(0),
            path,
            address(this),
            now
        );
    }

    function _swapDaiToLusd(uint256 _amount) internal {
        if (_amount == 0) {
            return;
        }

        if (useDmm) {
            address[] memory pools = new address[](lusdDaiPools.length);
            for (uint256 i = 0; i < lusdDaiPools.length; i++) {
                pools[i] = lusdDaiPools[lusdDaiPools.length - 1 - i];
            }

            IERC20[] memory path = new IERC20[](lusdDaiPath.length);
            for (uint256 i = 0; i < lusdDaiPath.length; i++) {
                path[i] = IERC20(lusdDaiPath[lusdDaiPath.length - 1 - i]);
            }

            dmmRouter.swapTokensForExactTokens(
                _amount,
                uint256(0),
                pools,
                path,
                address(this),
                now
            );
            return;
        }

        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = address(want);

        uniRouter.swapTokensForExactTokens(
            _amount,
            uint256(0),
            path,
            address(this),
            now
        );
    }

    function _swapIdleToDai() internal {
        if (balanceOfIdle() == 0) {
            return;
        }

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
