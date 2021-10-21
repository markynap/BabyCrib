//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./IDistributor.sol";
import "./SafeMath.sol";
import "./Address.sol";
import "./IUniswapV2Router02.sol";
import "./ReentrantGuard.sol";
import "./IBabyCrib.sol";

// Developed by MoonMark (DeFi Mark)

/** Distributes BABY Tokens To BabyCrib Token Holders Distributed By Weight */
contract Distributor is IDistributor, ReentrancyGuard {
    
    using SafeMath for uint256;
    using Address for address;
    
    // BabyCrib Contract
    address public _token;
    
    // Share of BabyCrib
    struct Share {
        uint256 amount;
        uint256 totalExcluded;
    }
    
    // Main Contract Address
    address public main;

    // Pancakeswap Router
    IUniswapV2Router02 _router;
    
    // shareholder fields
    address[] shareholders;
    mapping (address => uint256) shareholderIndexes;
    mapping (address => uint256) shareholderClaims;
    mapping (address => Share) public shares;
    
    // shares math and fields
    uint256 public totalShares;
    uint256 public totalDividends;
    uint256 public dividendsPerShare;
    uint256 constant dividendsPerShareAccuracyFactor = 10 ** 18;
    
    // blocks until next distribution
    uint256 public minPeriod = 14400;
    // auto claim every hour if able
    uint256 public constant minAutoPeriod = 1200;
    // 1 Baby minimum
    uint256 public minDistribution = 1 * 10**18;
    // current index in shareholder array 
    uint256 currentIndex;
    
    // minimum bnb to deposit into tokens
    uint256 public minimumToDeposit = 2 * 10**18;
    
    // owner of token contract - used to pair BabyCrib Token
    address _tokenOwner;
    
    // BNB -> Main
    address[] path;
    
    // modifiers
    modifier onlyToken() {
        require(msg.sender == _token); _;
    }
    
    modifier onlyTokenOwner() {
        require(msg.sender == _tokenOwner, 'Invalid Entry'); _;
    }

    constructor () {
        // Baby Swap For Main
        main = 0x53E562b9B7E5E94b81f10e96Ee70Ad06df3D2657;
        // Distributor master 
        _tokenOwner = msg.sender;
        // Router
        _router = IUniswapV2Router02(0x325E343f1dE602396E256B67eFd1F61C3A6B38Bd);
        // BNB -> Main
        path = new address[](2);
        path[0] = _router.WETH();
        path[1] = main;
    }
    
    ///////////////////////////////////////////////
    //////////      Only Token Owner    ///////////
    ///////////////////////////////////////////////
    
    function pairToken(address token) external onlyTokenOwner {
        require(_token == address(0) && token != address(0), 'Token Already Paired');
        _token = token;
        totalShares = IBabyCrib(_token).getIncludedTotalSupply();
        emit TokenPaired(token);
    }
    
    function transferTokenOwnership(address newOwner) external onlyTokenOwner {
        _tokenOwner = newOwner;
        emit TransferedTokenOwnership(newOwner);
    }
    
    /** New Main Address */
    function setMainTokenAddress(address newMainToken) external onlyTokenOwner {
        require(main != newMainToken && newMainToken != address(0), 'Invalid Input');
        uint256 bal = IERC20(main).balanceOf(address(this));
        if (bal > 0) {
            IERC20(main).transfer(_tokenOwner, bal);
        }
        main = newMainToken;
        emit SwappedMainTokenAddress(newMainToken);
    }
    
    /** Upgrades To New Distributor */
    function upgradeDistributor(address newDistributor) external onlyTokenOwner {
        require(newDistributor != address(this) && newDistributor != address(0), 'Invalid Input');
        uint256 bal = IERC20(main).balanceOf(address(this));
        if (bal > 0) {
            IERC20(main).transfer(_tokenOwner, bal);
        }
        emit UpgradeDistributor(newDistributor);
        selfdestruct(payable(_tokenOwner));
    }
    
    /** Sets Distibution Criteria */
    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution, uint256 minimumBNBToPurchaseToken) external onlyTokenOwner {
        minPeriod = _minPeriod;
        minDistribution = _minDistribution;
        minimumToDeposit = minimumBNBToPurchaseToken;
        emit UpdateDistributorCriteria(_minPeriod, _minDistribution, minimumBNBToPurchaseToken);
    }
    
    ///////////////////////////////////////////////
    //////////    Only Token Contract   ///////////
    ///////////////////////////////////////////////
    
    /** Sets Share For User */
    function setShare(address shareholder, uint256 amount) external override onlyToken {
        if(shares[shareholder].amount > 0){
            distributeMainDividend(shareholder);
        }

        if(amount > 0 && shares[shareholder].amount == 0){
            addShareholder(shareholder);
        }else if(amount == 0 && shares[shareholder].amount > 0){
            removeShareholder(shareholder);
        }

        totalShares = IBabyCrib(_token).getIncludedTotalSupply();
        shares[shareholder].amount = amount;
        shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
    }
    
    ///////////////////////////////////////////////
    //////////      Public Functions    ///////////
    ///////////////////////////////////////////////
    
    function claimDividendForUser(address shareholder) external nonReentrant {
        _claimDividend(shareholder);
    }
    
    function claimDividend() external nonReentrant {
        _claimDividend(msg.sender);
    }
    
    function process(uint256 gas) external override {
        uint256 shareholderCount = shareholders.length;

        if(shareholderCount == 0) { return; }

        uint256 gasUsed = 0;
        uint256 gasLeft = gasleft();

        uint256 iterations = 0;
        
        while(gasUsed < gas && iterations < shareholderCount) {
            if(currentIndex >= shareholderCount){
                currentIndex = 0;
            }
            
            if(shouldDistributeMain(shareholders[currentIndex])){
                distributeMainDividend(shareholders[currentIndex]);
            }
            
            gasUsed = gasUsed.add(gasLeft.sub(gasleft()));
            gasLeft = gasleft();
            currentIndex++;
            iterations++;
        }
    }


    ///////////////////////////////////////////////
    //////////    Internal Functions    ///////////
    ///////////////////////////////////////////////


    function addShareholder(address shareholder) internal {
        shareholderIndexes[shareholder] = shareholders.length;
        shareholders.push(shareholder);
        emit AddedShareholder(shareholder);
    }

    function removeShareholder(address shareholder) internal { 
        shareholders[shareholderIndexes[shareholder]] = shareholders[shareholders.length-1];
        shareholderIndexes[shareholders[shareholders.length-1]] = shareholderIndexes[shareholder]; 
        shareholders.pop();
        delete shareholderIndexes[shareholder];
        emit RemovedShareholder(shareholder);
    }

    function distributeMainDividend(address shareholder) internal nonReentrant {
        if(shares[shareholder].amount == 0){ return; }
        
        uint256 amount = getUnpaidMainEarnings(shareholder);
        if(amount > 0){
            
            shareholderClaims[shareholder] = block.number;
            uint256 bal = IERC20(_token).balanceOf(shareholder);
            if (bal > shares[shareholder].amount) {
                shares[shareholder].amount = bal;
            }
            bool s = IERC20(main).transfer(shareholder, amount);
            if (s) {
                shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
            }
        }
    }
    
    function buyToken(uint256 amount) private returns (uint256){

        // balance before
        uint256 balBefore = IERC20(main).balanceOf(address(this));
        
        // Swap 
        _router.swapExactETHForTokens{value:amount}(
            0,
            path,
            address(this),
            block.timestamp.add(30)
        );
        
        return IERC20(main).balanceOf(address(this)).sub(balBefore);
    }

    
    function _claimDividend(address shareholder) private {
        require(shareholderClaims[shareholder] + minAutoPeriod < block.number, 'Timeout');
        require(shares[shareholder].amount > 0, 'Zero Balance');
        uint256 amount = getUnpaidMainEarnings(shareholder);
        require(amount > 0, 'Zero Amount Owed');
        // update shareholder data
        shareholderClaims[shareholder] = block.number;
        shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
        bool s = IERC20(main).transfer(shareholder, amount);
        require(s, 'Failure On Token Transfer');
        // adjust shareholder amount
        uint256 bal = IERC20(_token).balanceOf(shareholder);
        if (bal > shares[shareholder].amount) {
            shares[shareholder].amount = bal;
        }
    }
    
    ///////////////////////////////////////////////
    //////////      Read Functions      ///////////
    ///////////////////////////////////////////////
    
    function shouldDistributeMain(address shareholder) internal view returns (bool) {
        return shareholderClaims[shareholder] + minPeriod < block.number
        && getUnpaidMainEarnings(shareholder) >= minDistribution;
    }
    
    function getShareholders() external view override returns (address[] memory) {
        return shareholders;
    }
    
    function getShareForHolder(address holder) public view override returns(uint256) {
        return shares[holder].amount == 0 ? 0 : IERC20(_token).balanceOf(holder);
    }

    function getUnpaidMainEarnings(address shareholder) public view returns (uint256) {
        uint256 amount = getShareForHolder(shareholder);
        if(amount == 0){ return 0; }

        uint256 shareholderTotalDividends = getCumulativeDividends(amount);
        uint256 shareholderTotalExcluded = shares[shareholder].totalExcluded;

        if(shareholderTotalDividends <= shareholderTotalExcluded){ return 0; }

        return shareholderTotalDividends.sub(shareholderTotalExcluded);
    }

    function getCumulativeDividends(uint256 share) internal view returns (uint256) {
        return share.mul(dividendsPerShare).div(dividendsPerShareAccuracyFactor);
    }
    
    function getNumShareholdersForDistributor(address distributor) external view returns(uint256) {
        return IDistributor(distributor).getShareholders().length;
    }
    
    function getNumShareholders() external view returns(uint256) {
        return shareholders.length;
    }

    // EVENTS 
    event TokenPaired(address pairedToken);
    event SwappedMainTokenAddress(address newMain);
    event UpgradeDistributor(address newDistributor);
    event AddedShareholder(address shareholder);
    event RemovedShareholder(address shareholder);
    event TransferedTokenOwnership(address newOwner);
    event UpdateDistributorCriteria(uint256 minPeriod, uint256 minDistribution, uint256 minimumBNBToPurchaseToken);

    receive() external payable {
        // update main dividends
        if (address(this).balance >= minimumToDeposit) {
            uint256 received = buyToken(address(this).balance);
            require(received > 0, 'Zero Received From Purchase');
            totalDividends = totalDividends.add(received);
            dividendsPerShare = dividendsPerShare.add(dividendsPerShareAccuracyFactor.mul(received).div(totalShares));
        }
    }

}
