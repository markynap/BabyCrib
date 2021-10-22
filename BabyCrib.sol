// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./SafeMath.sol";
import "./Address.sol";
import "./IUniswapV2Factory.sol";
import "./IUniswapV2Router02.sol";
import "./IDistributor.sol";
import "./IBabyCrib.sol";


/**
 * @dev The official BabyCribToken smart contract
 * 
 * developed by MoonMark (DeFi Mark)
 */
contract BabyCrib is IBabyCrib {
    
    using SafeMath for uint256;
    using Address for address;
    
    // General Info
    string private constant _name = "BabyCrib";
    string private constant _symbol = "CRIB";
    uint8  private constant _decimals = 9;
    
    // Liquidity Settings
    IUniswapV2Router02 public _router; // DEX Router
    address public _pair;     // LP Address
    
    // lock swapping 
    bool currentlySwapping;
    modifier lockSwapping {
        currentlySwapping = true;
        _;
        currentlySwapping = false;
    }
    
    // Addresses
    address public constant _burnWallet = 0x000000000000000000000000000000000000dEaD;
    address public _marketing = 0xE0A243eb9169256936C505a162478f5988A6fb85;
    
    // BabySwap Router
    address private _dexRouter = 0x325E343f1dE602396E256B67eFd1F61C3A6B38Bd;
    address[] path;

    // Balances
    mapping (address => uint256) private _rOwned;
    mapping (address => uint256) private _tOwned;
    mapping (address => mapping (address => uint256)) private _allowances;

    // Exclusions
    mapping (address => bool) private _isExcludedFromFees;
    mapping (address => bool) private _isExcluded; // both self and external reflections
    mapping (address => bool) private _isTxLimitExempt;
    mapping (address => bool) public isLiquidityPool;
    address[] private _excluded;

    // Supply
    uint256 private constant MAX = ~uint256(0);
    uint256 private _tTotal = 1 * 10**9 * (10 ** _decimals);
    uint256 private _rTotal = (MAX - (MAX % _tTotal));
    uint256 private _totalReflections;    // Total reflections
    
    // Sell Fee Breakdown
    uint256 public _burnFee = 3;          // 10% Burned
    uint256 public _reflectFee = 7;       // 23% Reflected
    uint256 public _reflectbabyFee = 20;  // 67% Baby Reflections

    // Token Tax Settings
    uint256 public _sellFee = 30;         // 30% sell tax 
    uint256 public _buyFee = 5;           // 5% buy tax
    uint256 public _transferFee = 5;      // 5% transfer tax
    uint256 public _marketingFee = 2;     // 2% Marketing Fee

    // Token Limits
    uint256 public _maxTxAmount        = _tTotal.div(100);  // 10 million
    uint256 public _tokenSwapThreshold = _tTotal.div(200);  // 5 million
    
    // gas for distributor
    IDistributor _distributor;
    uint256 _distributorGas = 500000;
    
    // Ownership
    address public _owner;
    modifier onlyOwner() {
        require(msg.sender == _owner); _;
    }
    
    // initalize BabyCrib
    constructor (address distributor) {
        
        // Initalize Router
        _router = IUniswapV2Router02(_dexRouter);
        
        // Create Liquidity Pair
        _pair = IUniswapV2Factory(_router.factory())
            .createPair(address(this), _router.WETH());

        // Set Distributor
        _distributor = IDistributor(distributor);

        // dividend + reward exclusions
        _excludeFromReward(address(this));
        _excludeFromReward(_burnWallet);
        _excludeFromReward(_pair);
        
        // fee exclusions 
        _isExcludedFromFees[address(this)] = true;
        _isExcludedFromFees[_burnWallet] = true;
        _isExcludedFromFees[msg.sender] = true;
        
        // tx limit exclusions
        _isTxLimitExempt[msg.sender] = true;
        _isTxLimitExempt[address(this)] = true;
        
        // liquidity pools
        isLiquidityPool[_pair] = true;
        
        // ownership
        _owner = msg.sender;
        _rOwned[msg.sender] = _rTotal;
        
        // Token -> BNB
        path = new address[](2);
        path[0] = address(this);
        path[1] = _router.WETH();

        // Transfer
        emit Transfer(address(0), msg.sender, _tTotal);
    }
    

    ////////////////////////////////////////////
    ////////      OWNER FUNCTIONS      /////////
    ////////////////////////////////////////////
    
    /**
     * @notice Transfers Ownership To New Account
     */
    function transferOwnership(address newOwner) external onlyOwner {
        _owner = newOwner;  
        emit TransferOwnership(newOwner);
    }
    
    /**
     * @notice Withdraws BNB from the contract
     */
    function withdrawBNB(uint256 amount) external onlyOwner {
        (bool s,) = payable(msg.sender).call{value: amount}("");
        require(s, 'Failure on BNB Withdraw');
        emit OwnerWithdraw(_router.WETH(), amount);
    }
    
    /**
     * @notice Withdraws non-CRIB tokens that are stuck as to not interfere with the liquidity
     */
    function withdrawForeignToken(address token) external onlyOwner {
        require(token != address(this), "Cannot Withdraw BabyCrib Tokens");
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).transfer(msg.sender, bal);
        }
        emit OwnerWithdraw(token, bal);
    }
    
    /**
     * @notice Allows the contract to change the router, in the instance when PancakeSwap upgrades making the contract future proof
     */
    function setRouterAddress(address router) external onlyOwner {
        require(router != address(0));
        _router = IUniswapV2Router02(router);
        emit UpdatedRouterAddress(router);
    }
    
    function setPairAddress(address newPair) external onlyOwner {
        require(newPair != address(0));
        _pair = newPair;
        isLiquidityPool[newPair] = true;
        emit UpdatedPairAddress(newPair);
    }
    
    function setIsLiquidityPool(address pool, bool isPool) external onlyOwner {
        isLiquidityPool[pool] = isPool;
        emit SetIsLiquidityPool(pool, isPool);
    }
    
     /**
     * @notice Excludes an address from receiving reflections
     */
    function excludeFromRewards(address account) external onlyOwner {
        require(account != address(this) && account != _pair);
        
        _excludeFromReward(account);
        _distributor.setShare(account, 0);
        emit ExcludeFromRewards(account);
    }
    
    function setFeeExemption(address account, bool feeExempt) external onlyOwner {
        _isExcludedFromFees[account] = feeExempt;
        emit SetFeeExemption(account, feeExempt);
    }
    
    function setTxLimitExempt(address account, bool isExempt) external onlyOwner {
        _isTxLimitExempt[account] = isExempt;
        emit SetTxLimitFeeExemption(account, isExempt);
    }

    function setMaxTxAmount(uint256 maxTxAmount) external onlyOwner {
        _maxTxAmount = maxTxAmount;
        emit SetMaxTxAmount(maxTxAmount);
    }
    
    function upgradeDistributor(address newDistributor) external onlyOwner {
        require(newDistributor != address(0));
        _distributor = IDistributor(newDistributor);
        emit UpgradedDistributor(newDistributor); 
    }
    
    function setTokenSwapThreshold(uint256 tokenSwapThreshold) external onlyOwner {
        _tokenSwapThreshold = tokenSwapThreshold;
        emit SetTokenSwapThreshold(tokenSwapThreshold);
    }
    
    function setMarketingAddress(address marketingAddress) external onlyOwner {
        _marketing = marketingAddress;
        emit SetMarketingAddress(marketingAddress);
    }
    
    /** Sets Various Fees */
    function setFees(uint256 burnFee, uint256 reflectFee, uint256 reflectbabyFee, uint256 marketingFee, uint256 buyFee, uint256 transferFee) external onlyOwner {
        _burnFee = burnFee;
        _reflectFee = reflectFee;
        _reflectbabyFee = reflectbabyFee;
        _marketingFee = marketingFee;
        _sellFee = burnFee.add(_reflectFee).add(_reflectbabyFee);
        _buyFee = buyFee;
        _transferFee = transferFee;
        require(_sellFee < 50);
        require(buyFee < 50);
        require(transferFee < 50);
        require(marketingFee < 5);
        emit SetFees(burnFee, reflectFee, reflectbabyFee, marketingFee, buyFee, transferFee);
    }
    
    /**
     * @notice Includes an address back into the reflection system
     */
    function includeInReward(address account) external onlyOwner {
        require(_isExcluded[account], "Account is already excluded");
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_excluded[i] == account) {
                // updating _rOwned to make sure the balances stay the same
                if (_tOwned[account] > 0)
                {
                    uint256 newrOwned = _tOwned[account].mul(_getRate());
                    _rTotal = _rTotal.sub(_rOwned[account]-newrOwned);
                    _totalReflections = _totalReflections.add(_rOwned[account]-newrOwned);
                    _rOwned[account] = newrOwned;
                }
                else
                {
                    _rOwned[account] = 0;
                }

                _tOwned[account] = 0;
                _excluded[i] = _excluded[_excluded.length - 1];
                _isExcluded[account] = false;
                _excluded.pop();
                break;
            }
        }
        _distributor.setShare(account, balanceOf(account));
        emit IncludeInRewards(account);
    }
    
    function setDistributorGas(uint256 gas) external onlyOwner {
        require(gas < 10000000);
        _distributorGas = gas;
        emit SetDistributorGas(gas);
    }
    
    
    ////////////////////////////////////////////
    ////////      IERC20 FUNCTIONS     /////////
    ////////////////////////////////////////////
    

    function name() external pure override returns (string memory) {
        return _name;
    }

    function symbol() external pure override returns (string memory) {
        return _symbol;
    }

    function decimals() external pure override returns (uint8) {
        return _decimals;
    }

    function totalSupply() external view override returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (_isExcluded[account]) return _tOwned[account];
        return tokenFromReflection(_rOwned[account]);
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        return _transfer(msg.sender, recipient, amount);
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        _allowances[sender][msg.sender] = _allowances[sender][msg.sender].sub(amount, "Insufficient Allowance");
        return _transfer(sender, recipient, amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
    
    
    ////////////////////////////////////////////
    ////////       READ FUNCTIONS      /////////
    ////////////////////////////////////////////
    
    
    function getTotalReflections() external view returns (uint256) {
        return _totalReflections;
    }
    
    function isExcludedFromFee(address account) external view returns(bool) {
        return _isExcludedFromFees[account];
    }
    
    function isExcludedFromRewards(address account) external view override returns(bool) {
        return _isExcluded[account];
    }
    
    function isTxLimitExempt(address account) external view returns(bool) {
        return _isTxLimitExempt[account];
    }
    
    function getDistributorAddress() external view returns (address) {
        return address(_distributor);
    }
 
    
    /**
     * @notice Converts a reflection value to a token value
     */
    function tokenFromReflection(uint256 rAmount) public view returns(uint256) {
        uint256 currentRate =  _getRate();
        return rAmount.div(currentRate);
    }

    /**
     * @notice Calculates transfer reflection values
     */
    function _getRValues(uint256 tAmount, uint256 tFee, uint256 currentRate) private pure returns (uint256, uint256, uint256) {
        uint256 rAmount = tAmount.mul(currentRate);
        uint256 rFee = tFee.mul(currentRate);
        uint256 rTransferAmount = rAmount.sub(rFee);
        return (rAmount, rTransferAmount, rFee);
    }

    /**
     * @notice Calculates the rate of reflections to tokens
     */
    function _getRate() private view returns(uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply.div(tSupply);
    }
    
    /**
     * @notice Gets the current supply values
     */
    function _getCurrentSupply() private view returns(uint256, uint256) {
        uint256 rSupply = _rTotal;
        uint256 tSupply = _tTotal;      
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_rOwned[_excluded[i]] > rSupply || _tOwned[_excluded[i]] > tSupply) return (_rTotal, _tTotal);
            rSupply = rSupply.sub(_rOwned[_excluded[i]]);
            tSupply = tSupply.sub(_tOwned[_excluded[i]]);
        }
        if (rSupply < _rTotal.div(_tTotal)) return (_rTotal, _tTotal);
        return (rSupply, tSupply);
    }
    
    function getIncludedTotalSupply() external view override returns (uint256) {
        (, uint256 tSupply) = _getCurrentSupply();
        return tSupply;
    }
    
    
    ////////////////////////////////////////////
    ////////    INTERNAL FUNCTIONS     /////////
    ////////////////////////////////////////////


    /**
     * @notice Handles the before and after of a token transfer, such as taking fees and firing off a swap and liquify event
     */
    function _transfer(address from, address to, uint256 amount) private returns(bool){
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        
        // Check TX Amount Exemptions
        require(amount <= _maxTxAmount || _isTxLimitExempt[from], "TX Limit");
        
        if (currentlySwapping) { // tokens being sent to Router or marketing
            _tokenTransfer(from, to, amount, false);
            return true;
        }
        
        // Should fee be taken 
        bool takeFee = !(_isExcludedFromFees[from] || _isExcludedFromFees[to]);
        
        // Should Swap For BNB
        if (shouldSwapBack(from)) {
            // Fuel distributors
            swapBack(_tokenSwapThreshold);
            // transfer token
            _tokenTransfer(from, to, amount, takeFee);
        } else {
            // transfer token
            _tokenTransfer(from, to, amount, takeFee);
            // process dividends
            try _distributor.process(_distributorGas) {} catch {}
        }
        
        // update distributor values
        if (!_isExcluded[from]) {
            _distributor.setShare(from, balanceOf(from));
        }
        if (!_isExcluded[to]) {
            _distributor.setShare(to, balanceOf(to));
        }
        return true;
    }
    
    /** Should Contract Sell Down Tokens For BNB */
    function shouldSwapBack(address from) public view returns(bool) {
        return balanceOf(address(this)) >= _tokenSwapThreshold 
            && !currentlySwapping 
            && from != _pair;
    }
    
    function getFee(address sender, address recipient, bool takeFee) internal view returns (uint256) {
        if (!takeFee) return 0;
        return isLiquidityPool[recipient] ? _sellFee : isLiquidityPool[sender] ? _buyFee : _transferFee;
    }
    
    /**
     * @notice Handles the transfer of tokens
     */
    function _tokenTransfer(address sender, address recipient, uint256 tAmount, bool takeFee) private {
        // Calculate the values required to execute a transfer
        uint256 fee = getFee(sender, recipient, takeFee);
        // take fee out of transfer amount
        uint256 tFee = tAmount.mul(fee).div(100);
        // new transfer amount
        uint256 tTransferAmount = tAmount.sub(tFee);
        // get R Values
        (uint256 rAmount, uint256 rTransferAmount,) = _getRValues(tAmount, tFee, _getRate());
        
        // Take Tokens From Sender
		if (_isExcluded[sender]) {
		    _tOwned[sender] = _tOwned[sender].sub(tAmount);
		}
		_rOwned[sender] = _rOwned[sender].sub(rAmount);
		
		// Give Taxed Amount To Recipient
		if (_isExcluded[recipient]) {
            _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
		}
		_rOwned[recipient] = _rOwned[recipient].add(rTransferAmount); 
		
		// apply fees if applicable
		if (takeFee) {
		    
		    // burn and reflection allocation
		    uint256 burnPortion; uint256 reflectPortion; uint256 distributorPortion;
		
	        // handle fee logic
		    if (isLiquidityPool[recipient]) { // tokens are being sold
		    
                // burn tokens
	    	    burnPortion = tFee.mul(_burnFee).div(_sellFee);
                _burnTokens(sender,burnPortion);

                // Reflect tokens
	    	    reflectPortion = tFee.mul(_reflectFee).div(_sellFee);
    		    _reflectTokens(reflectPortion);
            
                // Store tokens in contract for distributor
                distributorPortion = tFee.sub(reflectPortion).sub(burnPortion);
                _takeTokens(sender, distributorPortion);
            
		    } else { // tokens are being bought or transferred

		        // burn 1/3 of tokens
		        burnPortion = tFee.div(3);
		        _burnTokens(sender, burnPortion);
		    
		        // reflect other 2/3
		        reflectPortion = tFee.sub(burnPortion);
		        _reflectTokens(reflectPortion);
		    
		    }
        
            // Emit Fee Distribution
            emit FeesDistributed(burnPortion, reflectPortion, distributorPortion);
		    
		}
		
        // Emit Transfer
        emit Transfer(sender, recipient, tTransferAmount);
    }
    
    /**
     * @notice Burns CRIB tokens straight to the burn address
     */
    function _burnTokens(address sender, uint256 tFee) private {
        _sendTokens(sender, _burnWallet, tFee);
    }
    
    /**
     * @notice The contract takes a portion of tokens from taxed transactions
     */
    function _takeTokens(address sender, uint256 tTakeAmount) private {
        _sendTokens(sender, address(this), tTakeAmount);
    }
    
    /**
     * @notice Allocates Tokens To Address
     */
    function _sendTokens(address sender, address receiver, uint256 tAmount) private {
        uint256 rAmount = tAmount.mul(_getRate());
        _rOwned[receiver] = _rOwned[receiver].add(rAmount);
        if(_isExcluded[receiver]) {
            _tOwned[receiver] = _tOwned[receiver].add(tAmount);
        }
        emit Transfer(sender, receiver, tAmount);
    }

    /**
     * @notice Increases the rate of how many reflections each token is worth
     */
    function _reflectTokens(uint256 tFee) private {
        uint256 rFee = tFee.mul(_getRate());
        _rTotal = _rTotal.sub(rFee);
        _totalReflections = _totalReflections.add(tFee);
    }
    
    /**
     * @notice Excludes an address from receiving reflections
     */
    function _excludeFromReward(address account) private {
        require(!_isExcluded[account], "Account is already excluded");
        if(_rOwned[account] > 0) {
            _tOwned[account] = tokenFromReflection(_rOwned[account]);
        }
        _isExcluded[account] = true;
        _excluded.push(account);
    }
    
    /**
     * @notice Generates BNB by selling tokens and pairs some of the received BNB with tokens to add and grow the liquidity pool
     */
    function swapBack(uint256 tokenAmount) private lockSwapping {
        
        // tokens for marketing
        uint256 marketingAmount = tokenAmount.mul(_marketingFee).div(10**2);
        
        // transfer from this to marketing, ignoring fees
        _tokenTransfer(address(this), _marketing, marketingAmount, false);
        
        // update distributor
        if (!_isExcluded[_marketing]) {
            _distributor.setShare(_marketing, balanceOf(_marketing));
        }
    
        // update token amount to swap
        uint256 swapAmount = tokenAmount.sub(marketingAmount);

        // Swap CRIB tokens for BNB
        swapTokensForBNB(swapAmount);

        // Send BNB received to the distributor
        if (address(this).balance > 0) {
            (bool success,) = payable(address(_distributor)).call{value: address(this).balance}("");
            require(success, 'Failure on Distributor Payment');
        }
        
        emit SwappedBack(tokenAmount);
    }

    /**
     * @notice Swap tokens for BNB storing the resulting BNB in the contract
     */
    function swapTokensForBNB(uint256 tokenAmount) private {
        
        // approve router for token amount
        _allowances[address(this)][address(_router)] = 2*tokenAmount;

        // Execute the swap
        _router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // Accept any amount of BNB
            path,
            address(this),
            block.timestamp.add(300)
        );
    }
    
    receive() external payable {}  // to receive bnb
    
    
    ////////////////////////////////////////////
    ////////          EVENTS           /////////
    ////////////////////////////////////////////
    
    event SwappedBack(uint256 swapAmount);
    event FeesDistributed(uint256 burnPortion, uint256 reflectPortion, uint256 distributorPortion);
    event TransferOwnership(address newOwner);
    event OwnerWithdraw(address token, uint256 amount);
    event UpdatedRouterAddress(address newRouter);
    event UpdatedPairAddress(address newPair);
    event SetIsLiquidityPool(address pool, bool isPool);
    event ExcludeFromRewards(address account);
    event SetFeeExemption(address account, bool feeExempt);
    event SetTxLimitFeeExemption(address account, bool txLimitExempt);
    event SetMaxTxAmount(uint256 newAmount);
    event UpgradedDistributor(address newDistributor); 
    event SetTokenSwapThreshold(uint256 tokenSwapThreshold);
    event SetMarketingAddress(address marketingAddress);
    event SetFees(uint256 burnFee, uint256 reflectFee, uint256 reflectbabyFee, uint256 marketingFee, uint256 buyFee, uint256 transferFee);
    event IncludeInRewards(address account);
    event SetDistributorGas(uint256 gas);
    
}
