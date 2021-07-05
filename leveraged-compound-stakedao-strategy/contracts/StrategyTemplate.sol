pragma solidity ^0.5.16;
pragma experimental ABIEncoderV2;

// yarn add @openzeppelin/contracts@2.5.1
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./interfaces/compound/ICErc20.sol";
import "./interfaces/compound/IComptroller.sol";
import "./interfaces/uniswap/IUniswapRouterV2.sol";
import "./interfaces/tellor/IUsingTellor.sol";

interface IController {
    function withdraw(address, uint256) external;

    function balanceOf(address) external view returns (uint256);

    function earn(address, uint256) external;

    function want(address) external view returns (address);

    function rewards() external view returns (address);

    function vaults(address) external view returns (address);

    function strategies(address) external view returns (address);
}

contract StrategyIronUsdc {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    //wbtc
    address public constant want =
        address(0xd3A691C852CDB01E281545A27064741F0B7f6825);
    address public constant weth = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    ICErc20 public cErc20 = ICErc20(0xa1fAA15655B0e7b6B6470ED3d096390e6aD93Abb);
    IERC20 public reward = IERC20(0x61460874a7196d6a22D1eE4922473664b3E95270);
    IComptroller public constant comptroller =
        IComptroller(0x5eAe89DC1C671724A672ff0630122ee834098657);
    IUniswapRouterV2 public constant dex =
        IUniswapRouterV2(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    IUsingTellor public constant tellor =
        IUsingTellor(0x20374E579832859f180536A69093A126Db1c8aE9);

    uint256 public performanceFee = 1500;
    uint256 public withdrawalFee = 50;
    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public constant WBTC_BORROW_APY_ID = 100;
    uint256 public constant WBTC_BORROW_COMP_APY_ID = 101;

    address public governance;
    address public controller;
    address public strategist;

    uint256 public leveragePercent;
    uint256 public earned;

    event Harvested(uint256 wantEarned, uint256 lifetimeEarned);

    modifier onlyGovernance() {
        require(msg.sender == governance, "!governance");
        _;
    }

    modifier onlyController() {
        require(msg.sender == controller, "!controller");
        _;
    }

    constructor(address _controller) public {
        governance = msg.sender;
        strategist = msg.sender;
        controller = _controller;

        IERC20(want).safeApprove(address(cErc20), uint256(-1));
        reward.safeApprove(address(dex), uint256(-1));
    }

    function getName() external pure returns (string memory) {
        return "StrategyLeverageComp";
    }

    function setStrategist(address _strategist) external {
        require(
            msg.sender == governance || msg.sender == strategist,
            "!authorized"
        );
        strategist = _strategist;
    }

    function setWithdrawalFee(uint256 _withdrawalFee) external onlyGovernance {
        withdrawalFee = _withdrawalFee;
    }

    function setPerformanceFee(uint256 _performanceFee)
        external
        onlyGovernance
    {
        performanceFee = _performanceFee;
    }

    function submitValue(uint256 _requestId, uint256 _value)
        external
        onlyGovernance
    {
        tellor.submitValue(_requestId, _value);
    }

    function setLeveragePercent(uint256 _leveragePercent)
        external
        onlyGovernance
    {
        leveragePercent = _leveragePercent;
        _borrow();
    }

    function deposit() public {
        cErc20.mint(balanceOfWant());
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

        uint256 borrowApy = _getCurrentValue(WBTC_BORROW_APY_ID);
        uint256 borrowCompApy = _getCurrentValue(WBTC_BORROW_COMP_APY_ID);

        // not borrow if comp apy cannot cover borrow apy
        if (borrowCompApy < borrowApy) {
            return;
        }

        uint256 toBorrow = canBorrowAmount.sub(borrowBalance);
        cErc20.borrow(toBorrow);
        cErc20.mint(toBorrow);
    }

    function _getCurrentValue(uint256 _requestId)
        internal
        view
        returns (uint256 value)
    {
        uint256 count = tellor.getNewValueCountbyRequestId(_requestId);
        uint256 timestamp = tellor.getTimestampbyRequestIDandIndex(
            _requestId,
            count - 1
        );
        return tellor.retrieveData(_requestId, timestamp);
    }

    function withdraw(IERC20 _asset)
        external
        onlyController
        returns (uint256 balance)
    {
        balance = _asset.balanceOf(address(this));
        _asset.safeTransfer(controller, balance);
    }

    function withdraw(uint256 _amount) external onlyController {
        uint256 _balance = IERC20(want).balanceOf(address(this));

        if (_balance < _amount) {
            _withdrawSome(_amount.sub(_balance));
        }

        uint256 _fee = _amount.mul(withdrawalFee).div(FEE_DENOMINATOR);
        IERC20(want).safeTransfer(IController(controller).rewards(), _fee);
        address _vault = IController(controller).vaults(address(want));
        require(_vault != address(0), "!vault");
        IERC20(want).safeTransfer(_vault, _amount.sub(_fee));
    }

    function _withdrawSome(uint256 _amount) internal {
        _repay(_amount.mul(leveragePercent).div(100));

        _amount = Math.min(_amount, cErc20.balanceOfUnderlying(address(this)));
        cErc20.redeemUnderlying(_amount);
    }

    function _repay(uint256 _amount) internal {
        _amount = Math.min(_amount, cErc20.borrowBalanceCurrent(address(this)));
        cErc20.redeemUnderlying(_amount);
        cErc20.repayBorrow(_amount);
    }

    // Withdraw all funds, normally used when migrating strategies
    function withdrawAll() external onlyController returns (uint256 balance) {
        _withdrawAll();

        balance = IERC20(want).balanceOf(address(this));

        address _vault = IController(controller).vaults(address(want));
        require(_vault != address(0), "!vault"); // additional protection so we don't burn the funds
        IERC20(want).safeTransfer(_vault, balance);
    }

    function _withdrawAll() internal {
        _withdrawSome(cErc20.balanceOfUnderlying(address(this)));
    }

    function harvest() public {
        comptroller.claimComp(address(this));

        address[] memory paths = new address[](3);
        paths[0] = address(reward);
        paths[1] = weth;
        paths[2] = want;

        dex.swapExactTokensForTokens(
            reward.balanceOf(address(this)),
            uint256(0),
            paths,
            address(this),
            now
        );
    }

    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    function balanceOfPool() public view returns (uint256) {
        return cErc20.balanceOf(address(this));
    }

    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    function setGovernance(address _governance) external onlyGovernance {
        governance = _governance;
    }

    function setController(address _controller) external onlyGovernance {
        controller = _controller;
    }
}
