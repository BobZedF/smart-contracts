
pragma solidity ^0.8.9;

import { CreditLoan } from "./CreditLoan.sol";
import { LoanLib } from "../../utils/LoanLib.sol";
import { MutualUpgrade } from "../../utils/MutualUpgrade.sol";
import { SpigotController } from "../spigot/Spigot.sol";
import { ISpigotedLoan } from "../../interfaces/ISpigotedLoan.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SpigotedLoan is ISpigotedLoan, CreditLoan {

  SpigotController immutable public spigot;

  // 0x exchange to trade spigot revenue for debt tokens for
  address immutable public swapTarget;

  // amount of revenue to take from spigot if loan is healthy
  uint8 immutable public defaultRevenueSplit;

  // max revenue to take from spigot if loan is in distress
  uint8 constant MAX_SPLIT =  100;

  // debt tokens we bought from revenue but didn't use to repay loan
  // needed because Revolver might have same token held in contract as being bought/sold
  mapping(address => uint256) public unusedTokens;


  /**
   * @dev - BaseLoan contract with additional functionality for integrating with Spigot and borrower revenue streams to repay loans
   * @param oracle_ - price oracle to use for getting all token values
   * @param arbiter_ - neutral party with some special priviliges on behalf of borrower and lender
   * @param borrower_ - the debitor for all debt positions in this contract
   * @param swapTarget_ - the debitor for all debt positions in this contract
   * @param ttl_ - the debitor for all debt positions in this contract
   * @param defaultRevenueSplit_ - the debitor for all debt positions in this contract
  */
  constructor(
    address oracle_,
    address arbiter_,
    address borrower_,
    address swapTarget_,
    uint256 ttl_,
    uint8 defaultRevenueSplit_
  )
    CreditLoan(oracle_, arbiter_, borrower_, ttl_)
  {
    // empty arrays to init spigot
    address[] memory revContracts;
    SpigotController.SpigotSettings[] memory settings;
    bytes4[] memory whitelistedFuncs;
    
    spigot = new SpigotController(
      address(this),
      borrower,
      borrower,
      revContracts,
      settings,
      whitelistedFuncs
    );
    
    defaultRevenueSplit = defaultRevenueSplit_;

    swapTarget = swapTarget_;
  }

  function updateOwnerSplit(address revenueContract) external {
    ( , uint8 split, , bytes4 transferFunc) = spigot.getSetting(revenueContract);
    
    require(transferFunc != bytes4(0), "SpgtLoan: no spigot");

    if(loanStatus == LoanLib.STATUS.ACTIVE && split != defaultRevenueSplit) {
      // if loan is healthy set split to default take rate
      spigot.updateOwnerSplit(revenueContract, defaultRevenueSplit);
    } else if (
      loanStatus == LoanLib.STATUS.LIQUIDATABLE &&
      split != MAX_SPLIT
    ) {
      // if loan is in distress take all revenue to repay loan
      spigot.updateOwnerSplit(revenueContract, MAX_SPLIT);
    }
  }

 /**
   * @dev - Claims revenue tokens from Spigot attached to borrowers revenue generating tokens
            and sells them via 0x protocol to repay debts
            Only callable by borrower for security pasing arbitrary data in contract call
            and they are most incentivized to get best price on assets being sold.
   * @notice see _repay() for more details
   * @param claimToken - The revenue token escrowed by Spigot to claim and use to repay debt
   * @param zeroExTradeData - data generated by 0x API to trade `claimToken` against their exchange contract
  */
  function claimAndRepay(
    address claimToken,
    bytes calldata zeroExTradeData
  )
    external
    returns(bool)
  {
    bytes32 id = positionIds[0];
    require(msg.sender == borrower || msg.sender == arbiter);
    _accrueInterest(id);

    address targetToken = debts[id].token;

    uint256 tokensBought = _claimAndTrade(
      claimToken,
      targetToken,
      zeroExTradeData
    );

    uint256 available = tokensBought + unusedTokens[targetToken];
    uint256 debtAmount = debts[id].interestAccrued + debts[id].principal;

    // cap payment to debt value
    if(available > debtAmount) available = debtAmount;

    if(available > tokensBought) {
      // using bought + unused to repay loan
      unusedTokens[targetToken] -= available - tokensBought;
    } else {
      //  high revenue and bought more than we need
      unusedTokens[targetToken] += tokensBought - available;  
    }

    _repay(id, tokensBought);

    emit RevenuePayment(claimToken, tokensBought);

    return true;
  }

  /**
    * @notice allow Loan to add new revenue streams to reapy debt
    * @dev see SpigotController.addSpigot()
  */
  function addSpigot(
    address revenueContract,
    SpigotController.SpigotSettings calldata setting
  )
    mutualUpgrade(arbiter, borrower)
    external
    returns(bool)
  {
    return spigot.addSpigot(revenueContract, setting);
  }

  function claimAndTrade(
    address claimToken,
    bytes calldata zeroExTradeData
  )
    external
    returns(uint256 tokensBought)
  {
    require(msg.sender == borrower || msg.sender == arbiter);

    address targetToken = debts[positionIds[0]].token;
    uint256 tokensBought = _claimAndTrade(claimToken, targetToken, zeroExTradeData);
    
    // add bought tokens to unused balance
    unusedTokens[targetToken] += tokensBought;
  }


  function _claimAndTrade(
    address claimToken, 
    address targetToken, 
    bytes calldata zeroExTradeData
  )
    internal
    returns(uint256 tokensBought)
  {
    uint256 existingClaimTokens = IERC20(claimToken).balanceOf(address(this));
    uint256 existingTargetTokens = IERC20(targetToken).balanceOf(address(this));

    uint256 tokensClaimed = spigot.claimEscrow(claimToken);


    if(claimToken == address(0)) {
      // if claiming/trading eth send as msg.value to dex
      (bool success, ) = swapTarget.call{value: tokensClaimed}(zeroExTradeData);
      require(success, 'SpigotCnsm: trade failed');
    } else {
      IERC20(claimToken).approve(swapTarget, existingClaimTokens + tokensClaimed);
      (bool success, ) = swapTarget.call(zeroExTradeData);
      require(success, 'SpigotCnsm: trade failed');
    }

    uint256 targetTokens = IERC20(targetToken).balanceOf(address(this));

    // ideally we could use oracle to calculate # of tokens to receive
    // but claimToken might not have oracle. targetToken must have oracle

    // underflow revert ensures we have more tokens than we started with
    tokensBought= targetTokens - existingTargetTokens;

    emit TradeSpigotRevenue(
      claimToken,
      tokensClaimed,
      targetToken,
      tokensBought
    );

    // update unused if we didnt sell all claimed tokens in trade
    // also underflow revert protection here
    unusedTokens[claimToken] += IERC20(claimToken).balanceOf(address(this)) - existingClaimTokens;
  }

  function releaseSpigot() external returns(bool) {
    if(loanStatus == LoanLib.STATUS.REPAID) {
      require(spigot.updateOwner(borrower), "SpigotCnsmr: cant release spigot");
    }

    if(loanStatus == LoanLib.STATUS.LIQUIDATABLE) {
      require(spigot.updateOwner(arbiter), "SpigotCnsmr: cant release spigot");
    }
    return true;
  }

  function sweep(address token) external returns(uint256) {
    if(loanStatus == LoanLib.STATUS.REPAID) {
      bool success = IERC20(token).transfer(borrower, unusedTokens[token]);
      require(success);
    }
    if(loanStatus == LoanLib.STATUS.INSOLVENT) {
      bool success = IERC20(token).transfer(arbiter, unusedTokens[token]);
      require(success);
    }
  }
}
