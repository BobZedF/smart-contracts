pragma solidity 0.8.9;

interface IEscrowState {
  
}
interface IEscrow {
    struct Deposit {
        uint amount;
        bool isERC4626;
        address asset; // eip4626 asset else the erc20 token itself
        uint8 assetDecimals;
    }

    event AddCollateral(address indexed token, uint indexed amount);

    event RemoveCollateral(address indexed token, uint indexed amount);

    event EnableCollateral(address indexed token);
    
    event Liquidate(address indexed token, uint indexed amount);

    error InvalidCollateral();

    error CallerAccessDenied();

    error UnderCollateralized();

    error NotLiquidatable();

    // State var etters. 

    function line() external returns(address);

    function oracle() external returns(address);

    function borrower() external returns(address);

    function minimumCollateralRatio() external returns(uint256);

    // Functions 

    function isLiquidatable() external returns(bool);

    function updateLine(address line_) external returns(bool);

    function getCollateralRatio() external returns(uint);

    function getCollateralValue() external returns(uint);

    function enableCollateral(address token) external returns(bool);

    function addCollateral(uint amount, address token) external payable returns(uint);

    function releaseCollateral(uint amount, address token, address to) external returns(uint);
    
    function liquidate(uint amount, address token, address to) external returns(bool);
}
