// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy} from "@yearnvaults/contracts/BaseStrategy.sol";

import "@openzeppelin/contracts/math/Math.sol";

import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./WadRayMath.sol";
import "./libraries/AaveLenderBorrowerLib.sol";

import "./interfaces/ISwap.sol";
import "./interfaces/IVault.sol";
import "./interfaces/aave/IAToken.sol";
import "./interfaces/IOptionalERC20.sol";
import "./interfaces/aave/IStakedAave.sol";
import "./interfaces/aave/IPriceOracle.sol";
import "./interfaces/aave/ILendingPool.sol";
import "./interfaces/aave/IVariableDebtToken.sol";
import "./interfaces/aave/IProtocolDataProvider.sol";
import "./interfaces/aave/IAaveIncentivesController.sol";
import "./interfaces/aave/IReserveInterestRateStrategy.sol";
import "./interfaces/curve/IStableSwapExchange.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    using WadRayMath for uint256;

    // max interest rate we can afford to pay for borrowing investment token
    // amount in Ray (1e27 = 100%)
    uint256 public acceptableCostsRay = WadRayMath.RAY;

    // max amount to borrow. used to manually limit amount (for yVault to keep APY)
    uint256 public maxTotalBorrowIT;

    bool public isWantIncentivised;
    bool public isInvestmentTokenIncentivised;

    // Aave's referral code
    uint16 internal referral;

    // NOTE: LTV = Loan-To-Value = debt/collateral

    // Target LTV: ratio up to which which we will borrow
    uint16 public targetLTVMultiplier = 6_000;

    // Warning LTV: ratio at which we will repay
    uint16 public warningLTVMultiplier = 8_000; // 80% of liquidation LTV

    // support
    uint16 internal constant MAX_BPS = 10_000; // 100%
    uint16 internal constant MAX_MULTIPLIER = 9_000; // 90%

    IAToken internal aToken;
    IVariableDebtToken internal variableDebtToken;
    IVault public yVault;
    IERC20 internal investmentToken;

    // Use Dai as intermediate token
    IERC20 public intermediateToken =
        IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    // sUSD v2 Curve Pool
    IStableSwapExchange internal constant curvePool =
        IStableSwapExchange(0xA5407eAE9Ba41422680e2e00537571bcC53efBfD);

    // sUSD index
    int128 wantCurveIndex = 3;

    // Dai index
    int128 intermediateCurveIndex = 0;

    // Sanity check to avoid getting rekt swapping capital
    uint256 public minExpectedSwapPercentage = 9900;

    IStakedAave internal constant stkAave =
        IStakedAave(0x4da27a545c0c5B758a6BA100e3a049001de870f5);

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant AAVE = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;

    // SushiSwap router
    ISwap internal constant router =
        ISwap(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);

    uint256 internal minThreshold;
    string internal strategyName;

    event RepayDebt(uint256 repayAmount, uint256 previousDebtBalance);

    constructor(
        address _vault,
        address _yVault,
        string memory _strategyName
    ) public BaseStrategy(_vault) {
        yVault = IVault(_yVault);
        investmentToken = IERC20(IVault(_yVault).token());

        // aToken is the intermediate and not want (e.g: Dai instead of sUSD)
        (address _aToken, , ) =
            _protocolDataProvider().getReserveTokensAddresses(
                address(intermediateToken)
            );
        aToken = IAToken(_aToken);
        (, , address _variableDebtToken) =
            _protocolDataProvider().getReserveTokensAddresses(
                address(investmentToken)
            );

        variableDebtToken = IVariableDebtToken(_variableDebtToken);
        minThreshold = (10**(yVault.decimals())).div(100); // 0.01 minThreshold
        strategyName = _strategyName;

        // Set health check to health.ychad.eth
        healthCheck = 0xDDCea799fF1699e98EDF118e0629A974Df7DF012;
    }

    // ----------------- PUBLIC VIEW FUNCTIONS -----------------

    function name() external view override returns (string memory) {
        return strategyName;
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // not taking into account aave rewards (they are staked and not accesible)
        // this assumes want and intermediate token have same number of decimals
        return
            balanceOfWant() // balance of want
                .add(balanceOfAToken()) // asset suplied as collateral
                .add(balanceOfIntermediateToken()) // assume units are comparable (1 dai = 1 susd)
            // current value of assets deposited in vault
                .sub(
                _fromETH(
                    _toETH(balanceOfDebt(), address(investmentToken)),
                    address(want)
                )
            ); // liabilities
    }

    // ----------------- SETTERS -----------------
    function setMinExpectedSwapPercentage(uint256 _minExpectedSwapPercentage)
        external
        onlyEmergencyAuthorized
    {
        minExpectedSwapPercentage = _minExpectedSwapPercentage;
    }

    // we put all together to save contract bytecode (!)
    function setStrategyParams(
        uint16 _targetLTVMultiplier,
        uint16 _warningLTVMultiplier,
        uint256 _acceptableCostsRay,
        uint16 _aaveReferral,
        uint256 _maxTotalBorrowIT,
        bool _isWantIncentivised,
        bool _isInvestmentTokenIncentivised
    ) external onlyEmergencyAuthorized {
        require(
            _warningLTVMultiplier <= MAX_MULTIPLIER &&
                _targetLTVMultiplier <= _warningLTVMultiplier
        );
        targetLTVMultiplier = _targetLTVMultiplier;
        warningLTVMultiplier = _warningLTVMultiplier;
        acceptableCostsRay = _acceptableCostsRay;
        maxTotalBorrowIT = _maxTotalBorrowIT;
        referral = _aaveReferral;
        isWantIncentivised = _isWantIncentivised;
        isInvestmentTokenIncentivised = _isInvestmentTokenIncentivised;
    }

    // ----------------- MAIN STRATEGY FUNCTIONS -----------------
    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;

        // claim rewards from Aave's Liquidity Mining Program
        _claimRewards();

        uint256 totalAssetsAfterProfit = estimatedTotalAssets();

        _profit = totalAssetsAfterProfit > totalDebt
            ? totalAssetsAfterProfit.sub(totalDebt)
            : 0;

        uint256 _amountFreed;
        (_amountFreed, _loss) = liquidatePosition(
            _debtOutstanding.add(_profit)
        );
        _debtPayment = Math.min(_debtOutstanding, _amountFreed);

        if (_loss > _profit) {
            _loss = _loss.sub(_profit);
            _profit = 0;
        } else {
            _profit = _profit.sub(_loss);
            _loss = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 wantBalance = balanceOfWant();

        if (wantBalance > _debtOutstanding) {
            uint256 amountToDeposit = wantBalance.sub(_debtOutstanding);
            convertAndDepositToAave(amountToDeposit);
        }

        // NOTE: debt + collateral calcs are done in ETH
        (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            ,

        ) = _getAaveUserAccountData();

        // if there is no want deposited into aave, don't do nothing
        // this means no debt is borrowed from aave too
        if (totalCollateralETH == 0) {
            return;
        }

        uint256 currentLTV = totalDebtETH.mul(MAX_BPS).div(totalCollateralETH);
        uint256 targetLTV = _getTargetLTV(currentLiquidationThreshold); // 60% under liquidation Threshold
        uint256 warningLTV = _getWarningLTV(currentLiquidationThreshold); // 80% under liquidation Threshold

        // decide in which range we are and act accordingly:
        // SUBOPTIMAL(borrow) (e.g. from 0 to 60% liqLTV)
        // HEALTHY(do nothing) (e.g. from 60% to 80% liqLTV)
        // UNHEALTHY(repay) (e.g. from 80% to 100% liqLTV)

        // we use our target cost of capital to calculate how much debt we can take on / how much debt we need to repay
        // in order to bring costs back to an acceptable range
        // currentProtocolDebt => total amount of debt taken by all Aave's borrowers
        // maxProtocolDebt => amount of total debt at which the cost of capital is equal to our acceptable costs
        // if the current protocol debt is higher than the max protocol debt, we will repay debt
        (
            uint256 currentProtocolDebt,
            uint256 maxProtocolDebt,
            uint256 targetUtilisationRay
        ) =
            AaveLenderBorrowerLib.calcMaxDebt(
                address(investmentToken),
                acceptableCostsRay
            );

        if (targetLTV > currentLTV && currentProtocolDebt < maxProtocolDebt) {
            // SUBOPTIMAL RATIO: our current Loan-to-Value is lower than what we want
            // AND costs are lower than our max acceptable costs

            // we need to take on more debt
            uint256 targetDebtETH =
                totalCollateralETH.mul(targetLTV).div(MAX_BPS);

            uint256 amountToBorrowETH = targetDebtETH.sub(totalDebtETH); // safe bc we checked ratios
            amountToBorrowETH = Math.min(
                availableBorrowsETH,
                amountToBorrowETH
            );

            // cap the amount of debt we are taking according to our acceptable costs
            // if with the new loan we are increasing our cost of capital over what is healthy
            if (currentProtocolDebt.add(amountToBorrowETH) > maxProtocolDebt) {
                // Can't underflow because it's checked in the previous if condition
                amountToBorrowETH = maxProtocolDebt.sub(currentProtocolDebt);
            }

            uint256 maxTotalBorrowETH =
                _toETH(maxTotalBorrowIT, address(investmentToken));
            if (totalDebtETH.add(amountToBorrowETH) > maxTotalBorrowETH) {
                amountToBorrowETH = maxTotalBorrowETH > totalDebtETH
                    ? maxTotalBorrowETH.sub(totalDebtETH)
                    : 0;
            }

            // convert to InvestmentToken and borrow
            uint256 amountToBorrowIT =
                _fromETH(amountToBorrowETH, address(investmentToken));
            borrowFromAave(amountToBorrowIT);
        }

        // Remaining amount is in investment token
    }

    function liquidateAllPositions()
        internal
        override
        returns (uint256 _amountFreed)
    {
        (_amountFreed, ) = liquidatePosition(estimatedTotalAssets());
    }

    // Should free funds before this is called unless you want to report a loss
    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 totalAssets = balanceOfWant();
        if (_amountNeeded > totalAssets) {
            _liquidatedAmount = totalAssets;
            _loss = _amountNeeded.sub(totalAssets);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function prepareMigration(address _newStrategy) internal override {
        // nothing to do since debt cannot be migrated
    }

    function tendTrigger(uint256 callCost) public view override returns (bool) {
        // we adjust position if:
        // 1. LTV ratios are not in the HEALTHY range (either we take on more debt or repay debt)
        // 2. costs are not acceptable and we need to repay debt
        (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            ,
            uint256 currentLiquidationThreshold,
            ,

        ) = _getAaveUserAccountData();

        // Nothing to rebalance if we do not have collateral locked
        if (totalCollateralETH == 0) {
            return false;
        }

        uint256 targetLTV = _getTargetLTV(currentLiquidationThreshold);
        uint256 warningLTV = _getWarningLTV(currentLiquidationThreshold);

        return
            AaveLenderBorrowerLib.shouldRebalance(
                address(investmentToken),
                acceptableCostsRay,
                targetLTV,
                warningLTV,
                totalCollateralETH,
                totalDebtETH
            );
    }

    // ----------------- INTERNAL FUNCTIONS SUPPORT -----------------

    function repayInvestmentTokenDebt(uint256 amount)
        public
        onlyEmergencyAuthorized
    {
        if (amount == 0) {
            return;
        }

        // we cannot pay more than loose balance
        amount = Math.min(amount, balanceOfInvestmentToken());
        // we cannot pay more than we owe
        amount = Math.min(amount, balanceOfDebt());

        _checkAllowance(
            address(_lendingPool()),
            address(investmentToken),
            amount
        );

        if (amount > 0) {
            _lendingPool().repay(
                address(investmentToken),
                amount,
                uint256(2),
                address(this)
            );
        }
    }

    function _claimRewards() internal {
        if (isInvestmentTokenIncentivised || isWantIncentivised) {
            // redeem AAVE from stkAave
            uint256 stkAaveBalance =
                IERC20(address(stkAave)).balanceOf(address(this));

            if (stkAaveBalance > 0 && _checkCooldown()) {
                // claim AAVE rewards
                stkAave.claimRewards(address(this), type(uint256).max);
                stkAave.redeem(address(this), stkAaveBalance);
            }

            // sell AAVE for want
            // a minimum balance of 0.01 AAVE is required
            uint256 aaveBalance = IERC20(AAVE).balanceOf(address(this));
            if (aaveBalance > 1e15) {
                sellAForB(aaveBalance, address(AAVE), address(want));
            }

            // claim rewards
            // only add to assets those assets that are incentivised
            address[] memory assets;
            if (isInvestmentTokenIncentivised && isWantIncentivised) {
                assets = new address[](2);
                assets[0] = address(aToken);
                assets[1] = address(variableDebtToken);
            } else if (isInvestmentTokenIncentivised) {
                assets = new address[](1);
                assets[0] = address(variableDebtToken);
            } else if (isWantIncentivised) {
                assets = new address[](1);
                assets[0] = address(aToken);
            }

            _incentivesController().claimRewards(
                assets,
                type(uint256).max,
                address(this)
            );

            // request start of cooldown period
            uint256 cooldownStartTimestamp =
                IStakedAave(stkAave).stakersCooldowns(address(this));
            uint256 COOLDOWN_SECONDS = IStakedAave(stkAave).COOLDOWN_SECONDS();
            uint256 UNSTAKE_WINDOW = IStakedAave(stkAave).UNSTAKE_WINDOW();
            if (
                IERC20(address(stkAave)).balanceOf(address(this)) > 0 &&
                (cooldownStartTimestamp == 0 ||
                    block.timestamp >
                    cooldownStartTimestamp.add(COOLDOWN_SECONDS).add(
                        UNSTAKE_WINDOW
                    ))
            ) {
                stkAave.cooldown();
            }
        }
    }

    function borrowFromAave(uint256 amountToBorrowIT)
        public
        onlyEmergencyAuthorized
    {
        if (amountToBorrowIT > 0) {
            _lendingPool().borrow(
                address(investmentToken),
                amountToBorrowIT,
                2,
                referral,
                address(this)
            );
        }
    }

    function withdrawFromAave(uint256 amount)
        public
        onlyEmergencyAuthorized
        returns (uint256)
    {
        uint256 balanceUnderlying = balanceOfAToken();
        if (amount > balanceUnderlying) {
            amount = balanceUnderlying;
        }

        uint256 maxWithdrawal =
            Math.min(
                _maxWithdrawal(),
                intermediateToken.balanceOf(address(aToken))
            );

        uint256 toWithdraw = Math.min(amount, maxWithdrawal);
        if (toWithdraw == 0) {
            return 0;
        }

        _checkAllowance(address(_lendingPool()), address(aToken), toWithdraw);
        _lendingPool().withdraw(
            address(intermediateToken),
            toWithdraw,
            address(this)
        );

        return toWithdraw;
    }

    //withdraw an amount including any want balance
    function withdrawFromAaveAndConvert(uint256 amount)
        public
        onlyEmergencyAuthorized
    {
        uint256 toWithdraw = withdrawFromAave(amount);
        exchangeUnderlyingOnCurve(
            intermediateCurveIndex,
            wantCurveIndex,
            toWithdraw
        );
    }

    function exchangeUnderlyingOnCurve(
        int128 from,
        int128 to,
        uint256 amount
    ) public onlyEmergencyAuthorized {
        _checkAllowance(address(curvePool), address(want), amount);
        _checkAllowance(address(curvePool), address(intermediateToken), amount);

        curvePool.exchange_underlying(
            from,
            to,
            amount,
            amount.mul(minExpectedSwapPercentage).div(MAX_BPS)
        );
    }

    function _maxWithdrawal() internal view returns (uint256) {
        (uint256 totalCollateralETH, uint256 totalDebtETH, , , uint256 ltv, ) =
            _getAaveUserAccountData();
        uint256 minCollateralETH =
            ltv > 0 ? totalDebtETH.mul(MAX_BPS).div(ltv) : totalCollateralETH;
        if (minCollateralETH > totalCollateralETH) {
            return 0;
        }
        return
            _fromETH(
                totalCollateralETH.sub(minCollateralETH),
                address(intermediateToken)
            );
    }

    function _calculateAmountToRepay(uint256 amount)
        internal
        view
        returns (uint256)
    {
        if (amount == 0) {
            return 0;
        }
        // we check if the collateral that we are withdrawing leaves us in a risky range, we then take action
        (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            ,
            uint256 currentLiquidationThreshold,
            ,

        ) = _getAaveUserAccountData();
        uint256 warningLTV = _getWarningLTV(currentLiquidationThreshold);
        uint256 targetLTV = _getTargetLTV(currentLiquidationThreshold);
        uint256 amountETH = _toETH(amount, address(intermediateToken));
        return
            AaveLenderBorrowerLib.calculateAmountToRepay(
                amountETH,
                totalCollateralETH,
                totalDebtETH,
                warningLTV,
                targetLTV,
                address(investmentToken),
                minThreshold
            );
    }

    function depositIntermediateTokenToAave(uint256 amount)
        public
        onlyEmergencyAuthorized
    {
        if (amount == 0) {
            return;
        }

        ILendingPool lp = _lendingPool();
        _checkAllowance(address(lp), address(intermediateToken), amount);
        lp.deposit(address(intermediateToken), amount, address(this), referral);
    }

    function convertAndDepositToAave(uint256 amount)
        public
        onlyEmergencyAuthorized
    {
        if (amount == 0) {
            return;
        }

        exchangeUnderlyingOnCurve(
            wantCurveIndex,
            intermediateCurveIndex,
            amount
        );

        depositIntermediateTokenToAave(balanceOfIntermediateToken());
    }

    function _checkCooldown() internal view returns (bool) {
        return
            AaveLenderBorrowerLib.checkCooldown(
                isWantIncentivised,
                isInvestmentTokenIncentivised,
                address(stkAave)
            );
    }

    function _checkAllowance(
        address _contract,
        address _token,
        uint256 _amount
    ) internal {
        if (IERC20(_token).allowance(address(this), _contract) < _amount) {
            IERC20(_token).safeApprove(_contract, 0);
            IERC20(_token).safeApprove(_contract, type(uint256).max);
        }
    }

    // ----------------- INTERNAL CALCS -----------------
    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfInvestmentToken() public view returns (uint256) {
        return investmentToken.balanceOf(address(this));
    }

    function balanceOfIntermediateToken() public view returns (uint256) {
        return intermediateToken.balanceOf(address(this));
    }

    function balanceOfAToken() public view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    function balanceOfDebt() public view returns (uint256) {
        return variableDebtToken.balanceOf(address(this));
    }

    function _getAaveUserAccountData()
        internal
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        return _lendingPool().getUserAccountData(address(this));
    }

    function _getTargetLTV(uint256 liquidationThreshold)
        internal
        view
        returns (uint256)
    {
        return
            liquidationThreshold.mul(uint256(targetLTVMultiplier)).div(MAX_BPS);
    }

    function _getWarningLTV(uint256 liquidationThreshold)
        internal
        view
        returns (uint256)
    {
        return
            liquidationThreshold.mul(uint256(warningLTVMultiplier)).div(
                MAX_BPS
            );
    }

    // ----------------- TOKEN CONVERSIONS -----------------
    function getTokenOutPath(address _token_in, address _token_out)
        internal
        pure
        returns (address[] memory _path)
    {
        bool is_weth =
            _token_in == address(WETH) || _token_out == address(WETH);
        _path = new address[](is_weth ? 2 : 3);
        _path[0] = _token_in;

        if (is_weth) {
            _path[1] = _token_out;
        } else {
            _path[1] = address(WETH);
            _path[2] = _token_out;
        }
    }

    function sellAForB(
        uint256 _amount,
        address tokenA,
        address tokenB
    ) public onlyEmergencyAuthorized {
        if (_amount == 0 || tokenA == tokenB) {
            return;
        }

        _checkAllowance(address(router), tokenA, _amount);
        router.swapExactTokensForTokens(
            _amount,
            0,
            getTokenOutPath(tokenA, tokenB),
            address(this),
            now
        );
    }

    function _toETH(uint256 _amount, address asset)
        internal
        view
        returns (uint256)
    {
        if (
            _amount == 0 ||
            _amount == type(uint256).max ||
            address(asset) == address(WETH) // 1:1 change
        ) {
            return _amount;
        }
        return AaveLenderBorrowerLib.toETH(_amount, asset);
    }

    function _fromETH(uint256 _amount, address asset)
        internal
        view
        returns (uint256)
    {
        if (
            _amount == 0 ||
            _amount == type(uint256).max ||
            address(asset) == address(WETH) // 1:1 change
        ) {
            return _amount;
        }
        return AaveLenderBorrowerLib.fromETH(_amount, asset);
    }

    // ----------------- INTERNAL SUPPORT GETTERS -----------------

    function _lendingPool() internal view returns (ILendingPool lendingPool) {
        return AaveLenderBorrowerLib.lendingPool();
    }

    function _protocolDataProvider()
        internal
        view
        returns (IProtocolDataProvider protocolDataProvider)
    {
        return AaveLenderBorrowerLib.protocolDataProvider;
    }

    function _priceOracle() internal view returns (IPriceOracle) {
        return AaveLenderBorrowerLib.priceOracle();
    }

    function _incentivesController()
        internal
        view
        returns (IAaveIncentivesController)
    {
        return
            AaveLenderBorrowerLib.incentivesController(
                aToken,
                variableDebtToken,
                isWantIncentivised,
                isInvestmentTokenIncentivised
            );
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    // Not using profitFactor/harvestTrigger so this is irrelevant
    function ethToWant(uint256 _amtInWei)
        public
        view
        override
        returns (uint256)
    {}
}
