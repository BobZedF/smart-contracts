pragma solidity ^0.8.9;

import "../lib/forge-std/src/Script.sol";
import {CreditLib } from "../contracts/utils/CreditLib.sol";
import {CreditListLib } from "../contracts/utils/CreditListLib.sol";
import {LoanLib } from "../contracts/utils/LoanLib.sol";
import {SpigotedLoanLib } from "../contracts/utils/SpigotedLoanLib.sol";
import {RevenueToken} from "../contracts/mock/RevenueToken.sol";
import {SimpleOracle} from "../contracts/mock/SimpleOracle.sol";
import {SecuredLoan} from "../contracts/modules/credit/SecuredLoan.sol";
import {Spigot} from  "../contracts/modules/spigot/Spigot.sol";
import {Escrow} from "../contracts/modules/escrow/Escrow.sol";


contract MyScript is Script {
    Escrow escrow;
    RevenueToken supportedToken1;
    RevenueToken supportedToken2;
    RevenueToken unsupportedToken;
    SimpleOracle oracle;
    SecuredLoan loan;
    uint mintAmount = 100 ether;
    uint MAX_INT = 115792089237316195423570985008687907853269984665640564039457584007913129639935;
    uint minCollateralRatio = 1 ether; // 100%
    uint128 drawnRate = 100;
    uint128 facilityRate = 1;

    address borrower;
    address arbiter;
    address lender;

    function setUp() external {
        
        vm.startBroadcast();

        borrower = address(this);
        lender = address(this);
        arbiter = address(this);
        supportedToken1 = new RevenueToken();
        supportedToken2 = new RevenueToken();
        unsupportedToken = new RevenueToken();

        Spigot spigot = new Spigot(address(this), borrower, borrower);
        oracle = new SimpleOracle(address(supportedToken1), address(supportedToken2));
        escrow = new Escrow(minCollateralRatio, address(oracle),address(this), borrower);

        loan = new SecuredLoan(
            address(oracle),
            arbiter,
            borrower,
            address(0),
            address(spigot),
            address(escrow),
            150 days,
            0
        );
        
        escrow.updateLoan(address(loan));
        spigot.updateOwner(address(loan));
        loan.init();

        escrow.enableCollateral( address(supportedToken1));
        escrow.enableCollateral( address(supportedToken2));
        _mintAndApprove();
        escrow.addCollateral(1 ether, address(supportedToken2));

        vm.stopBroadcast();
    }

     function _mintAndApprove() internal {
        supportedToken1.mint(borrower, mintAmount);
        supportedToken1.approve(address(escrow), MAX_INT);
        supportedToken1.approve(address(loan), MAX_INT);

        supportedToken2.mint(borrower, mintAmount);
        supportedToken2.approve(address(escrow), MAX_INT);
        supportedToken2.approve(address(loan), MAX_INT);

        unsupportedToken.mint(borrower, mintAmount);
        unsupportedToken.approve(address(escrow), MAX_INT);
        unsupportedToken.approve(address(loan), MAX_INT);
    }     
}
