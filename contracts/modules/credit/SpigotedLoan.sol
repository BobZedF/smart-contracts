pragma solidity ^0.8.9;

import {LineOfCredit} from "./LineOfCredit.sol";
import {LoanLib} from "../../utils/LoanLib.sol";
import {MutualConsent} from "../../utils/MutualConsent.sol";
import {Spigot} from "../spigot/Spigot.sol";
import {ISpigotedLoan} from "../../interfaces/ISpigotedLoan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SpigotedLoan is ISpigotedLoan, LineOfCredit {
    Spigot public immutable spigot;

    // 0x exchange to trade spigot revenue for credit tokens for
    address public immutable swapTarget;

    // amount of revenue to take from spigot if loan is healthy
    uint8 public immutable defaultRevenueSplit;

    // max revenue to take from spigot if loan is in distress
    uint8 constant MAX_SPLIT = 100;

    // credit tokens we bought from revenue but didn't use to repay loan
    // needed because Revolver might have same token held in contract as being bought/sold
    mapping(address => uint256) private unusedTokens;

    /**
     * @notice - LineofCredit contract with additional functionality for integrating with Spigot and borrower revenue streams to repay loans
     * @param oracle_ - price oracle to use for getting all token values
     * @param arbiter_ - neutral party with some special priviliges on behalf of borrower and lender
     * @param borrower_ - the debitor for all credit positions in this contract
     * @param swapTarget_ - 0x protocol exchange address to send calldata for trades to
     * @param ttl_ - the debitor for all credit positions in this contract
     * @param defaultRevenueSplit_ - the debitor for all credit positions in this contract
     */
    constructor(
        address oracle_,
        address arbiter_,
        address borrower_,
        address swapTarget_,
        uint256 ttl_,
        uint8 defaultRevenueSplit_
    ) LineOfCredit(oracle_, arbiter_, borrower_, ttl_) {
        spigot = new Spigot(address(this), borrower, borrower);

        defaultRevenueSplit = defaultRevenueSplit_;

        swapTarget = swapTarget_;
    }

    function unused(address token) external view returns (uint256) {
        return unusedTokens[token];
    }

    /**
     * @notice changes the revenue split between borrower treasury and lan repayment based on loan health
     * @dev    - callable `arbiter` + `borrower`
     * @param revenueContract - spigot to update
     */
    function updateOwnerSplit(address revenueContract) external returns (bool) {
        (, uint8 split, , bytes4 transferFunc) = spigot.getSetting(
            revenueContract
        );

        require(transferFunc != bytes4(0), "SpgtLoan: no spigot");

        if (
            loanStatus == LoanLib.STATUS.ACTIVE && split != defaultRevenueSplit
        ) {
            // if loan is healthy set split to default take rate
            spigot.updateOwnerSplit(revenueContract, defaultRevenueSplit);
        } else if (
            loanStatus == LoanLib.STATUS.LIQUIDATABLE && split != MAX_SPLIT
        ) {
            // if loan is in distress take all revenue to repay loan
            spigot.updateOwnerSplit(revenueContract, MAX_SPLIT);
        }

        return true;
    }

    /**

   * @notice - Claims revenue tokens from Spigot attached to borrowers revenue generating tokens
               and sells them via 0x protocol to repay credits
   * @dev    - callable `arbiter` + `borrower`
               bc they are most incentivized to get best price on assets being sold.
   * @notice see _repay() for more details
   * @param claimToken - The revenue token escrowed by Spigot to claim and use to repay credit
   * @param zeroExTradeData - data generated by 0x API to trade `claimToken` against their exchange contract
  */
    function claimAndRepay(address claimToken, bytes calldata zeroExTradeData)
        external
        whileBorrowing
        returns (bool)
    {
        bytes32 id = ids[0];
        require(msg.sender == borrower || msg.sender == arbiter);
        _accrueInterest(id);

        address targetToken = credits[id].token;

        uint256 tokensBought = _claimAndTrade(
            claimToken,
            targetToken,
            zeroExTradeData
        );

        uint256 available = tokensBought + unusedTokens[targetToken];
        uint256 creditAmount = credits[id].interestAccrued + credits[id].principal;

        // cap payment to credit value
        if (available > creditAmount) available = creditAmount;

        if (available > tokensBought) {
            // using bought + unused to repay loan
            unusedTokens[targetToken] -= available - tokensBought;
        } else {
            //  high revenue and bought more than we need
            unusedTokens[targetToken] += tokensBought - available;
        }

        _repay(id, available);

        emit RevenuePayment(claimToken, tokensBought);

        return true;
    }

    /**
     * @notice allows tokens in escrow to be sold immediately but used to pay down credit later
     * @dev ensures first token in repayment queue is being bought
     * @dev    - callable `arbiter` + `borrower`
     * @param claimToken - the token escrowed in spigot to sell in trade
     * @param zeroExTradeData - 0x API data to use in trade to sell `claimToken` for `credits[ids[0]]`
     * returns - amount of credit tokens bought
     */
    function claimAndTrade(address claimToken, bytes calldata zeroExTradeData)
        external
        whileBorrowing
        returns (uint256 tokensBought)
    {
        require(msg.sender == borrower || msg.sender == arbiter);

        address targetToken = credits[ids[0]].token;
        uint256 tokensBought = _claimAndTrade(
            claimToken,
            targetToken,
            zeroExTradeData
        );

        // add bought tokens to unused balance
        unusedTokens[targetToken] += tokensBought;
    }

    function _claimAndTrade(
        address claimToken,
        address targetToken,
        bytes calldata zeroExTradeData
    ) internal returns (uint256 tokensBought) {
        uint256 existingClaimTokens = IERC20(claimToken).balanceOf(
            address(this)
        );
        uint256 existingTargetTokens = IERC20(targetToken).balanceOf(
            address(this)
        );

        uint256 tokensClaimed = spigot.claimEscrow(claimToken);

        if (claimToken == address(0)) {
            // if claiming/trading eth send as msg.value to dex
            (bool success, ) = swapTarget.call{value: tokensClaimed}(
                zeroExTradeData
            );
            require(success, "SpigotCnsm: trade failed");
        } else {
            IERC20(claimToken).approve(
                swapTarget,
                existingClaimTokens + tokensClaimed
            );
            (bool success, ) = swapTarget.call(zeroExTradeData);
            require(success, "SpigotCnsm: trade failed");
        }

        uint256 targetTokens = IERC20(targetToken).balanceOf(address(this));

        // ideally we could use oracle to calculate # of tokens to receive
        // but claimToken might not have oracle. targetToken must have oracle

        // underflow revert ensures we have more tokens than we started with
        tokensBought = targetTokens - existingTargetTokens;

        emit TradeSpigotRevenue(
            claimToken,
            tokensClaimed,
            targetToken,
            tokensBought
        );

        // update unused if we didnt sell all claimed tokens in trade
        // also underflow revert protection here
        unusedTokens[claimToken] +=
            IERC20(claimToken).balanceOf(address(this)) -
            existingClaimTokens;
    }

    //  SPIGOT OWNER FUNCTIONS

    /**
     * @notice - allow Loan to add new revenue streams to reapy credit
     * @dev    - see Spigot.addSpigot()
     * @dev    - callable `arbiter` + `borrower`
     */
    function addSpigot(
        address revenueContract,
        Spigot.Setting calldata setting
    ) external mutualConsent(arbiter, borrower) returns (bool) {
        return spigot.addSpigot(revenueContract, setting);
    }

    /**
     * @notice - allow borrower to call functions on their protocol to maintain it and keep earning revenue
     * @dev    - see Spigot.updateWhitelistedFunction()
     * @dev    - callable `arbiter`
     */
    function updateWhitelist(bytes4 func, bool allowed)
        external
        returns (bool)
    {
        require(msg.sender == arbiter);
        return spigot.updateWhitelistedFunction(func, allowed);
    }

    /**

   * @notice -  transfers revenue streams to borrower if repaid or arbiter if liquidatable
             -  doesnt transfer out if loan is unpaid and/or healthy
   * @dev    - callable by anyone 
  */
    function releaseSpigot() external returns (bool) {
        if (loanStatus == LoanLib.STATUS.REPAID) {
            require(
                spigot.updateOwner(borrower),
                "SpigotCnsmr: cant release spigot"
            );
            return true;
        }

        if (loanStatus == LoanLib.STATUS.LIQUIDATABLE) {
            require(
                spigot.updateOwner(arbiter),
                "SpigotCnsmr: cant release spigot"
            );
            return true;
        }

        return false;
    }

    /**

   * @notice - sends unused tokens to borrower if repaid or arbiter if liquidatable
             -  doesnt send tokens out if loan is unpaid but healthy
   * @dev    - callable by anyone 
   * @param token - token to take out
  */
    function sweep(address token) external returns (uint256) {
        if (loanStatus == LoanLib.STATUS.REPAID) {
            return _sweep(borrower, token);
        }
        if (loanStatus == LoanLib.STATUS.INSOLVENT) {
            return _sweep(arbiter, token);
        }

        return 0;
    }

    function _sweep(address to, address token) internal returns (uint256 x) {
        x = unusedTokens[token];
        if (token == address(0)) {
            payable(to).transfer(x);
        } else {
            require(IERC20(token).transfer(to, x));
        }
        delete unusedTokens[token];
    }

    // allow trading in ETH
    receive() external payable {}
}
